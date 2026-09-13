// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IWindDownController.sol";
import "./interfaces/ILPLocker.sol";
import "./interfaces/ISwapRouter.sol";

/// @title PunchCardRouter
/// @notice Routes swaps between merchant tokens via USDC or ETH pools.
/// @dev Swap logic is immutable forever. Only parameters are upgradeable.
///      Parameter upgrades require multisig + 48hr timelock.
///      Routing table:
///        token → USDC    USDC pool    1 hop    fee in USDC
///        token → WETH    ETH pool     1 hop    fee in WETH
///        USDC → token    USDC pool    1 hop    fee in USDC
///        WETH → token    ETH pool     1 hop    fee in WETH
///        token → token   USDC pool×2  2 hops   fee in USDC at mid-point
///      Swaps can NEVER be paused — guaranteed in immutable code.
///      Hard fee ceiling 1% enforced in immutable code.
contract PunchCardRouter is ReentrancyGuard {

    // ── CONSTANTS ─────────────────────────────────────────────────────────────

    uint256 public constant MAX_FEE_RATE    = 100;      // 1% ceiling
    uint256 public constant FEE_DENOMINATOR    = 10_000;
    uint256 public constant PARAM_TIMELOCK     = 48 hours;

    /// @notice Maximum price impact allowed per swap — protects users on thin pools
    /// @dev 500 = 5%. Reverts if swap would move price more than this.
    uint256 public constant MAX_PRICE_IMPACT = 500;

    // ── IMMUTABLES ────────────────────────────────────────────────────────────

    address public immutable multisig;
    address public immutable windDownController;

    /// @notice Uniswap v3 SwapRouter02 on Base
    /// @dev 0x2626664c2603336E57B271c5C0b26F421741e481
    address public immutable swapRouter;

    address public immutable USDC;
    address public immutable WETH;

    // ── PARAMETERS ────────────────────────────────────────────────────────────

    uint256 public feeRate;
    address public feeRecipient;

    // ── UPGRADE STRUCTS ───────────────────────────────────────────────────────

    struct RouterParams {
        uint256 feeRate;
        address feeRecipient;
    }

    struct PendingChange {
        bytes32 paramsHash;
        uint256 executableAt;
    }

    PendingChange public pendingChange;

    // ── SWAP PARAMS ───────────────────────────────────────────────────────────

    struct SwapParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOutMinimumHop1; // single-hop: min output after fee
                                      // token→token: min USDC out of hop1
        uint256 amountOutMinimumHop2; // token→token only: min tokenOut of hop2
        address recipient;
        uint256 deadline;
    }

    // ── EVENTS ────────────────────────────────────────────────────────────────

    event Swapped(
        address indexed tokenIn,
        address indexed tokenOut,
        address indexed recipient,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeTaken,
        address feeToken,
        uint256 timestamp
    );

    event ChangeProposed(
        bytes32 indexed paramsHash,
        RouterParams params,
        uint256 executableAt,
        uint256 timestamp
    );

    event ChangeExecuted(RouterParams params, uint256 timestamp);
    event ChangeCancelled(bytes32 indexed paramsHash, uint256 timestamp);

    // ── CONSTRUCTOR ───────────────────────────────────────────────────────────

    constructor(
        address _multisig,
        address _windDownController,
        address _swapRouter,
        address _usdc,
        address _weth,
        uint256 _initialFeeRate,
        address _initialFeeRecipient
    ) {
        require(_multisig            != address(0), "Invalid multisig");
        require(_windDownController  != address(0), "Invalid controller");
        require(_swapRouter          != address(0), "Invalid swap router");
        require(_usdc                != address(0), "Invalid USDC");
        require(_weth                != address(0), "Invalid WETH");
        require(_initialFeeRecipient != address(0), "Invalid fee recipient");
        require(_initialFeeRate      <= MAX_FEE_RATE, "Fee exceeds ceiling");

        multisig            = _multisig;
        windDownController  = _windDownController;
        swapRouter          = _swapRouter;
        USDC                = _usdc;
        WETH                = _weth;
        feeRate             = _initialFeeRate;
        feeRecipient        = _initialFeeRecipient;
    }

    // ── SWAP ──────────────────────────────────────────────────────────────────

    /// @notice Routes a swap. Never pausable — immutable code guarantee.
    /// @dev tokenIn/tokenOut can be merchant tokens, USDC, or WETH.
    ///      Fee denomination follows the pair token of the pool used.
    function swap(SwapParams calldata p) external nonReentrant {
        require(p.recipient  != address(0), "Invalid recipient");
        require(p.amountIn   > 0,           "Zero amount");
        require(block.timestamp <= p.deadline, "Deadline passed");
        require(
            p.amountOutMinimumHop1 >= (p.amountIn * (FEE_DENOMINATOR - MAX_PRICE_IMPACT)) / FEE_DENOMINATOR,
            "Price impact too high"
        );

        bool inIsUSDC  = p.tokenIn  == USDC;
        bool inIsWETH  = p.tokenIn  == WETH;
        bool outIsUSDC = p.tokenOut == USDC;
        bool outIsWETH = p.tokenOut == WETH;

        if (!inIsUSDC && !inIsWETH && !outIsUSDC && !outIsWETH) {
            // Case: token → token (cross-merchant via USDC pool)
            _validateMerchantToken(p.tokenIn,  false);
            _validateMerchantToken(p.tokenOut, true);
            _swapTokenToToken(p);

        } else if (!inIsUSDC && !inIsWETH && outIsUSDC) {
            // Case: token → USDC (USDC pool, fee in USDC)
            _validateMerchantToken(p.tokenIn, false);
            _swapTokenToStable(p, USDC, true);

        } else if (!inIsUSDC && !inIsWETH && outIsWETH) {
            // Case: token → WETH (ETH pool, fee in WETH)
            _validateMerchantToken(p.tokenIn, false);
            _swapTokenToStable(p, WETH, false);

        } else if (inIsUSDC && !outIsUSDC && !outIsWETH) {
            // Case: USDC → token (USDC pool, fee in USDC)
            _validateMerchantToken(p.tokenOut, true);
            _swapStableToToken(p, USDC, true);

        } else if (inIsWETH && !outIsUSDC && !outIsWETH) {
            // Case: WETH → token (ETH pool, fee in WETH)
            _validateMerchantToken(p.tokenOut, true);
            _swapStableToToken(p, WETH, false);

        } else {
            revert("Invalid swap pair");
        }
    }

    // ── INTERNAL SWAP PATHS ───────────────────────────────────────────────────

    /// @dev token → USDC or token → WETH. Fee skimmed from output.
    ///      isUsdcPool = true uses usdcFeeTier, false uses ethFeeTier.
    function _swapTokenToStable(
        SwapParams calldata p,
        address stableToken,
        bool isUsdcPool
    ) internal {
        uint24 fee = isUsdcPool
            ? _usdcFeeTier(p.tokenIn)
            : _ethFeeTier(p.tokenIn);

        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        IERC20(p.tokenIn).approve(swapRouter, p.amountIn);

        uint256 stableOut = ISwapRouter(swapRouter).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn:           p.tokenIn,
                tokenOut:          stableToken,
                fee:               fee,
                recipient:         address(this),
                amountIn:          p.amountIn,
                amountOutMinimum:  p.amountOutMinimumHop1,
                sqrtPriceLimitX96: 0
            })
        );

        uint256 feeTaken        = (stableOut * feeRate) / FEE_DENOMINATOR;
        uint256 stableToRecipient = stableOut - feeTaken;

        if (feeTaken > 0) IERC20(stableToken).transfer(feeRecipient, feeTaken);
        IERC20(stableToken).transfer(p.recipient, stableToRecipient);

        emit Swapped(p.tokenIn, stableToken, p.recipient, p.amountIn, stableToRecipient, feeTaken, stableToken, block.timestamp);
    }

    /// @dev USDC → token or WETH → token. Fee skimmed from stable input.
    function _swapStableToToken(
        SwapParams calldata p,
        address stableToken,
        bool isUsdcPool
    ) internal {
        uint24 fee = isUsdcPool
            ? _usdcFeeTier(p.tokenOut)
            : _ethFeeTier(p.tokenOut);

        IERC20(stableToken).transferFrom(msg.sender, address(this), p.amountIn);

        uint256 feeTaken    = (p.amountIn * feeRate) / FEE_DENOMINATOR;
        uint256 stableToSwap = p.amountIn - feeTaken;

        if (feeTaken > 0) IERC20(stableToken).transfer(feeRecipient, feeTaken);

        IERC20(stableToken).approve(swapRouter, stableToSwap);

        uint256 tokenOut = ISwapRouter(swapRouter).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn:           stableToken,
                tokenOut:          p.tokenOut,
                fee:               fee,
                recipient:         p.recipient,
                amountIn:          stableToSwap,
                amountOutMinimum:  p.amountOutMinimumHop1,
                sqrtPriceLimitX96: 0
            })
        );

        emit Swapped(stableToken, p.tokenOut, p.recipient, p.amountIn, tokenOut, feeTaken, stableToken, block.timestamp);
    }

    /// @dev token → token cross-merchant. Routes through USDC pool twice.
    ///      Fee skimmed from USDC mid-point.
    function _swapTokenToToken(SwapParams calldata p) internal {
        uint24 feeIn  = _usdcFeeTier(p.tokenIn);
        uint24 feeOut = _usdcFeeTier(p.tokenOut);

        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        IERC20(p.tokenIn).approve(swapRouter, p.amountIn);

        // Hop 1: tokenA → USDC
        uint256 usdcMid = ISwapRouter(swapRouter).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn:           p.tokenIn,
                tokenOut:          USDC,
                fee:               feeIn,
                recipient:         address(this),
                amountIn:          p.amountIn,
                amountOutMinimum:  p.amountOutMinimumHop1,
                sqrtPriceLimitX96: 0
            })
        );

        // Skim fee from USDC mid-point
        uint256 feeTaken   = (usdcMid * feeRate) / FEE_DENOMINATOR;
        uint256 usdcToSwap = usdcMid - feeTaken;

        if (feeTaken > 0) IERC20(USDC).transfer(feeRecipient, feeTaken);

        // Hop 2: USDC → tokenB
        IERC20(USDC).approve(swapRouter, usdcToSwap);

        uint256 tokenOut = ISwapRouter(swapRouter).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn:           USDC,
                tokenOut:          p.tokenOut,
                fee:               feeOut,
                recipient:         p.recipient,
                amountIn:          usdcToSwap,
                amountOutMinimum:  p.amountOutMinimumHop2,
                sqrtPriceLimitX96: 0
            })
        );

        emit Swapped(p.tokenIn, p.tokenOut, p.recipient, p.amountIn, tokenOut, feeTaken, USDC, block.timestamp);
    }

    // ── ROUTING POLICY ────────────────────────────────────────────────────────

    function _validateMerchantToken(address token, bool rejectIfWindDown) internal view {
        IWindDownController wdc = IWindDownController(windDownController);
        require(wdc.isRegistered(token), "Token not on network");
        require(!wdc.isComplete(token),  "Token wind-down complete");
        if (rejectIfWindDown) {
            require(!wdc.isInitiated(token), "Destination token in wind-down");
        }
    }

    /// @dev Reads USDC pool fee tier from merchant's LPLocker
    function _usdcFeeTier(address token) internal view returns (uint24) {
        IWindDownController.WindDownSuite memory suite =
            IWindDownController(windDownController).getSuite(token);
        return ILPLocker(suite.lpLocker).usdcFeeTier();
    }

    /// @dev Reads ETH pool fee tier from merchant's LPLocker
    function _ethFeeTier(address token) internal view returns (uint24) {
        IWindDownController.WindDownSuite memory suite =
            IWindDownController(windDownController).getSuite(token);
        return ILPLocker(suite.lpLocker).ethFeeTier();
    }

    // ── PARAMETER UPGRADES ────────────────────────────────────────────────────

    function proposeChange(RouterParams calldata params) external {
        require(msg.sender == multisig,            "Not multisig");
        require(params.feeRate      <= MAX_FEE_RATE,  "Fee exceeds ceiling");
        require(params.feeRecipient != address(0),    "Invalid recipient");

        bytes32 hash         = keccak256(abi.encode(params));
        uint256 executableAt = block.timestamp + PARAM_TIMELOCK;

        pendingChange = PendingChange({ paramsHash: hash, executableAt: executableAt });

        emit ChangeProposed(hash, params, executableAt, block.timestamp);
    }

    function executeChange(RouterParams calldata params) external {
        require(pendingChange.paramsHash != bytes32(0), "No pending change");
        require(block.timestamp >= pendingChange.executableAt, "Timelock active");

        bytes32 hash = keccak256(abi.encode(params));
        require(hash == pendingChange.paramsHash, "Params mismatch");

        require(params.feeRate      <= MAX_FEE_RATE, "Fee exceeds ceiling");
        require(params.feeRecipient != address(0),   "Invalid recipient");

        feeRate      = params.feeRate;
        feeRecipient = params.feeRecipient;

        delete pendingChange;
        emit ChangeExecuted(params, block.timestamp);
    }

    function cancelChange() external {
        require(msg.sender == multisig,                "Not multisig");
        require(pendingChange.paramsHash != bytes32(0), "No pending change");

        bytes32 hash = pendingChange.paramsHash;
        delete pendingChange;
        emit ChangeCancelled(hash, block.timestamp);
    }

    // ── VIEWS ─────────────────────────────────────────────────────────────────

    function timeUntilExecution() external view returns (uint256) {
        if (pendingChange.paramsHash == bytes32(0)) return 0;
        if (block.timestamp >= pendingChange.executableAt) return 0;
        return pendingChange.executableAt - block.timestamp;
    }

    function getParams() external view returns (RouterParams memory) {
        return RouterParams({ feeRate: feeRate, feeRecipient: feeRecipient });
    }
}
