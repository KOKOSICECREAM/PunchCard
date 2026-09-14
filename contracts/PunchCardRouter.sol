// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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

    using SafeERC20 for IERC20;

    // ── CONSTANTS ─────────────────────────────────────────────────────────────

    uint256 public constant MAX_FEE_RATE    = 100;      // 1% ceiling
    uint256 public constant FEE_DENOMINATOR    = 10_000;
    uint256 public constant PARAM_TIMELOCK     = 48 hours;

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
        uint256 amountOutMinimumHop1; // token→stable: min received, AFTER the router fee
                                      // stable→token: min tokenOut (fee is taken from amountIn)
                                      // token→token:  min USDC at the hop-1 midpoint, pre-fee
        uint256 amountOutMinimumHop2; // token→token only: min tokenOut of hop2
        address midToken;             // token→token only: USDC or WETH — whichever the
                                      // caller quoted as the better route. Ignored on
                                      // single-hop swaps.
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
        // Slippage protection is amountOutMinimum*, enforced by Uniswap on the actual
        // output and by the post-fee check in _swapTokenToStable. Callers compute it from
        // a quote, which is the only way to know a fair price.
        //
        // A previous guard here compared amountOutMinimumHop1 against amountIn directly.
        // Those are denominated in different assets — merchant tokens are 6dp at ~$0.002,
        // USDC is 6dp at $1, WETH is 18dp — so as a raw integer comparison it blocked
        // token->token, token->USDC and WETH->token outright while being a no-op on the
        // other two paths. A real impact check needs a price reference, and a TWAP of a
        // $5k launch pool is too cheap to push to be worth trusting.

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

        IERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), p.amountIn);
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

        // Uniswap checked amountOutMinimum against the pre-fee amount, but the recipient
        // is paid post-fee. Without this they could receive up to feeRate less than the
        // minimum they asked for.
        require(stableToRecipient >= p.amountOutMinimumHop1, "Below minimum after fee");

        if (feeTaken > 0) IERC20(stableToken).safeTransfer(feeRecipient, feeTaken);
        IERC20(stableToken).safeTransfer(p.recipient, stableToRecipient);

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

        IERC20(stableToken).safeTransferFrom(msg.sender, address(this), p.amountIn);

        uint256 feeTaken    = (p.amountIn * feeRate) / FEE_DENOMINATOR;
        uint256 stableToSwap = p.amountIn - feeTaken;

        if (feeTaken > 0) IERC20(stableToken).safeTransfer(feeRecipient, feeTaken);

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
    /// @dev Routes through whichever pool the caller quoted as better. Both hops use the
    ///      same midpoint asset, so liquidity in either pool can serve network flow —
    ///      previously this was hardcoded to USDC, which left every merchant's ETH pool
    ///      unable to earn from cross-merchant swaps at all.
    ///
    ///      Best execution is the caller's job, not the contract's. Quoting both paths
    ///      on-chain would mean simulating two swaps per swap; Uniswap's own routers take
    ///      the same approach and let the interface quote off-chain. amountOutMinimumHop2
    ///      is what protects the caller if they route badly.
    function _swapTokenToToken(SwapParams calldata p) internal {
        bool viaUsdc = p.midToken == USDC;
        require(viaUsdc || p.midToken == WETH, "Invalid mid token");

        uint24 feeIn  = viaUsdc ? _usdcFeeTier(p.tokenIn)  : _ethFeeTier(p.tokenIn);
        uint24 feeOut = viaUsdc ? _usdcFeeTier(p.tokenOut) : _ethFeeTier(p.tokenOut);

        IERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), p.amountIn);
        IERC20(p.tokenIn).approve(swapRouter, p.amountIn);

        // Hop 1: tokenA → USDC
        uint256 midOut = ISwapRouter(swapRouter).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn:           p.tokenIn,
                tokenOut:          p.midToken,
                fee:               feeIn,
                recipient:         address(this),
                amountIn:          p.amountIn,
                amountOutMinimum:  p.amountOutMinimumHop1,
                sqrtPriceLimitX96: 0
            })
        );

        // Skim the fee from the midpoint, in whichever asset that is
        uint256 feeTaken  = (midOut * feeRate) / FEE_DENOMINATOR;
        uint256 midToSwap = midOut - feeTaken;

        if (feeTaken > 0) IERC20(p.midToken).safeTransfer(feeRecipient, feeTaken);

        // Hop 2: midToken → tokenB
        IERC20(p.midToken).approve(swapRouter, midToSwap);

        uint256 tokenOut = ISwapRouter(swapRouter).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn:           p.midToken,
                tokenOut:          p.tokenOut,
                fee:               feeOut,
                recipient:         p.recipient,
                amountIn:          midToSwap,
                amountOutMinimum:  p.amountOutMinimumHop2,
                sqrtPriceLimitX96: 0
            })
        );

        emit Swapped(p.tokenIn, p.tokenOut, p.recipient, p.amountIn, tokenOut, feeTaken, p.midToken, block.timestamp);
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
    /// @notice Both pools' fee tiers for a merchant token, so an interface can quote the
    ///         USDC and WETH routes off-chain and pass the better one as `midToken`.
    function getPoolFeeTiers(address token) external view returns (uint24 usdcFee, uint24 ethFee) {
        IWindDownController.WindDownSuite memory suite =
            IWindDownController(windDownController).getSuite(token);
        return (ILPLocker(suite.lpLocker).usdcFeeTier(), ILPLocker(suite.lpLocker).ethFeeTier());
    }

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
