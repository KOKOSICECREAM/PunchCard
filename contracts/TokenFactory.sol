// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./PunchCardToken.sol";
import "./VestingWallet.sol";
import "./TreasuryTimelock.sol";
import "./RewardEscrow.sol";
import "./LPLocker.sol";
import "./interfaces/IWindDownController.sol";

/// @title TokenFactory
/// @notice Deploys full PunchCard merchant suite in a single transaction.
/// @dev Deployer hot wallet executes after off-chain PunchCard review.
///      Multisig updates deployer if compromised.
///      Launch LP: 3% of supply split 60% USDC pool / 40% ETH pool.
///      Remaining 27% held as reserve in LPLocker — merchant deploys over time.
///      Both pools use Uniswap v3 full-range positions.
///      Dust from both mints returns to ownerWallet.
contract TokenFactory {

    // ── INTERFACES ────────────────────────────────────────────────────────────

    interface INonfungiblePositionManager {
        struct MintParams {
            address token0;
            address token1;
            uint24  fee;
            int24   tickLower;
            int24   tickUpper;
            uint256 amount0Desired;
            uint256 amount1Desired;
            uint256 amount0Min;
            uint256 amount1Min;
            address recipient;
            uint256 deadline;
        }

        function mint(MintParams calldata params)
            external
            payable
            returns (
                uint256 tokenId,
                uint128 liquidity,
                uint256 amount0,
                uint256 amount1
            );
    }

    interface IWETH {
        function deposit() external payable;
    }

    // ── NETWORK CONSTANTS ─────────────────────────────────────────────────────

    uint256 public constant TOTAL_SUPPLY    = 100_000_000 * 1e6;
    uint256 public constant REWARDS_ALLOC   =  45_000_000 * 1e6;
    uint256 public constant LP_ALLOC        =  30_000_000 * 1e6;
    uint256 public constant TEAM_ALLOC      =  15_000_000 * 1e6;
    uint256 public constant TREASURY_ALLOC  =  10_000_000 * 1e6;

    /// @notice Tokens deployed into pools at launch — 3% of total supply
    uint256 public constant LAUNCH_LP_ALLOC    = 3_000_000 * 1e6;

    /// @notice 60% of launch LP goes to USDC pool
    uint256 public constant LAUNCH_USDC_TOKENS = 1_800_000 * 1e6;

    /// @notice 40% of launch LP goes to ETH pool
    uint256 public constant LAUNCH_ETH_TOKENS  = 1_200_000 * 1e6;

    /// @notice Remaining 27% held as reserve in LPLocker
    uint256 public constant LP_RESERVE         = LP_ALLOC - LAUNCH_LP_ALLOC; // 27_000_000 * 1e6

    uint256 public constant DAILY_CAP         = 500_000 * 1e6;
    uint256 public constant CLIFF_DURATION    = 180 days;
    uint256 public constant VEST_DURATION     = 1080 days;
    uint256 public constant TIMELOCK_DURATION = 90 days;

    int24 private constant MIN_TICK = -887272;
    int24 private constant MAX_TICK =  887272;

    // ── IMMUTABLES ────────────────────────────────────────────────────────────

    address public immutable multisig;
    address public immutable windDownController;
    address public immutable positionManager;
    address public immutable USDC;
    address public immutable WETH;

    // ── STATE ─────────────────────────────────────────────────────────────────

    address public deployer;
    mapping(address => bytes32) public ipfsHashes;

    // ── EVENTS ────────────────────────────────────────────────────────────────

    event MerchantDeployed(
        address indexed merchantToken,
        address indexed ownerWallet,
        address teamWallet,
        address operator,
        address rewardEscrow,
        address vestingWallet,
        address treasuryTimelock,
        address lpLocker,
        bytes32 ipfsHash,
        uint256 timestamp
    );

    event DeployerUpdated(
        address indexed oldDeployer,
        address indexed newDeployer,
        uint256 timestamp
    );

    // ── CONSTRUCTOR ───────────────────────────────────────────────────────────

    constructor(
        address _multisig,
        address _deployer,
        address _windDownController,
        address _positionManager,
        address _usdc,
        address _weth
    ) {
        require(_multisig            != address(0), "Invalid multisig");
        require(_deployer            != address(0), "Invalid deployer");
        require(_windDownController  != address(0), "Invalid controller");
        require(_positionManager     != address(0), "Invalid position manager");
        require(_usdc                != address(0), "Invalid USDC");
        require(_weth                != address(0), "Invalid WETH");

        multisig            = _multisig;
        deployer            = _deployer;
        windDownController  = _windDownController;
        positionManager     = _positionManager;
        USDC                = _usdc;
        WETH                = _weth;
    }

    // ── MODIFIERS ─────────────────────────────────────────────────────────────

    modifier onlyDeployer() {
        require(msg.sender == deployer, "Not deployer");
        _;
    }

    modifier onlyMultisig() {
        require(msg.sender == multisig, "Not multisig");
        _;
    }

    // ── DEPLOYER MANAGEMENT ───────────────────────────────────────────────────

    function setDeployer(address newDeployer) external onlyMultisig {
        require(newDeployer != address(0), "Invalid deployer");
        address old = deployer;
        deployer = newDeployer;
        emit DeployerUpdated(old, newDeployer, block.timestamp);
    }

    // ── DEPLOY ────────────────────────────────────────────────────────────────

    struct DeployParams {
        string  name;
        string  symbol;
        bytes32 ipfsHash;
        address ownerWallet;
        address teamWallet;
        address operator;
        uint24  usdcFeeTier;     // fee tier for USDC pool
        uint24  ethFeeTier;      // fee tier for ETH pool
        uint256 usdcPairAmount;  // USDC to seed USDC pool at launch
        uint256 ethPairAmount;   // ETH to seed ETH pool at launch (msg.value)
        uint256 perTxFloor;
        uint256 perTxMax;
    }

    /// @notice Deploys full merchant suite with dual LP pools in one transaction
    /// @dev msg.value must equal ethPairAmount.
    ///      ownerWallet must approve factory for usdcPairAmount before calling.
    ///      Launch: 1.8M tokens + usdcPairAmount → USDC pool
    ///              1.2M tokens + ethPairAmount  → ETH pool (WETH wrapped)
    ///      Reserve: 27M tokens held in LPLocker for merchant-controlled release.
    function deploy(DeployParams calldata p)
        external
        payable
        onlyDeployer
    {
        // ── VALIDATION ────────────────────────────────────────────────────────

        require(bytes(p.name).length   > 0,           "Invalid name");
        require(bytes(p.symbol).length > 0,           "Invalid symbol");
        require(p.ipfsHash             != bytes32(0), "Invalid IPFS hash");
        require(p.ownerWallet          != address(0), "Invalid owner");
        require(p.teamWallet           != address(0), "Invalid team wallet");
        require(p.operator             != address(0), "Invalid operator");
        require(p.usdcPairAmount       > 0,           "Invalid USDC amount");
        require(p.ethPairAmount        > 0,           "Invalid ETH amount");
        require(msg.value             == p.ethPairAmount, "ETH amount mismatch");
        require(p.perTxFloor           > 0,           "Invalid floor");
        require(p.perTxFloor           <= DAILY_CAP,  "Floor above cap");
        require(p.perTxMax             >= p.perTxFloor,"Max below floor");
        require(p.perTxMax             <= DAILY_CAP,  "Max above cap");
        require(
            p.usdcFeeTier == 100 || p.usdcFeeTier == 500 ||
            p.usdcFeeTier == 3000 || p.usdcFeeTier == 10000,
            "Invalid USDC fee tier"
        );
        require(
            p.ethFeeTier == 100 || p.ethFeeTier == 500 ||
            p.ethFeeTier == 3000 || p.ethFeeTier == 10000,
            "Invalid ETH fee tier"
        );

        // ── STEP 0: Pull USDC and wrap ETH ───────────────────────────────────

        require(
            IERC20(USDC).transferFrom(p.ownerWallet, address(this), p.usdcPairAmount),
            "USDC transfer failed"
        );

        IWETH(WETH).deposit{value: p.ethPairAmount}();

        // ── STEP 1: Deploy PunchCardToken ─────────────────────────────────────

        PunchCardToken token = new PunchCardToken(
            p.name,
            p.symbol,
            TOTAL_SUPPLY,
            address(this),
            p.ipfsHash
        );
        address tokenAddr = address(token);

        // ── STEP 2: Deploy VestingWallet ──────────────────────────────────────

        VestingWallet vesting = new VestingWallet(
            tokenAddr,
            p.teamWallet,
            windDownController,
            CLIFF_DURATION,
            VEST_DURATION
        );

        // ── STEP 3: Deploy TreasuryTimelock ───────────────────────────────────

        TreasuryTimelock treasury = new TreasuryTimelock(
            tokenAddr,
            p.ownerWallet,
            windDownController,
            TIMELOCK_DURATION
        );

        // ── STEP 4: Deploy RewardEscrow ───────────────────────────────────────

        RewardEscrow escrow = new RewardEscrow(
            tokenAddr,
            p.operator,
            p.ownerWallet,
            windDownController,
            DAILY_CAP,
            p.perTxFloor,
            p.perTxMax
        );

        // ── STEP 5: Deploy LPLocker ───────────────────────────────────────────

        LPLocker locker = new LPLocker(
            tokenAddr,
            p.ownerWallet,
            windDownController,
            positionManager,
            address(this),
            USDC,
            WETH
        );

        // ── STEP 6: Distribute non-LP allocations ────────────────────────────

        token.transfer(address(vesting),  TEAM_ALLOC);
        token.transfer(address(treasury), TREASURY_ALLOC);
        token.transfer(address(escrow),   REWARDS_ALLOC);
        // Factory retains full LP_ALLOC (30M) for pool seeding + reserve transfer

        assert(token.balanceOf(address(this)) == LP_ALLOC);

        // ── STEP 7: Mint USDC pool position (60% of launch LP) ───────────────

        uint256 usdcTokenId;
        {
            bool tokenIsToken0Usdc = tokenAddr < USDC;
            (
                address token0Usdc,
                address token1Usdc,
                uint256 amt0DesiredUsdc,
                uint256 amt1DesiredUsdc
            ) = tokenIsToken0Usdc
                ? (tokenAddr, USDC, LAUNCH_USDC_TOKENS, p.usdcPairAmount)
                : (USDC, tokenAddr, p.usdcPairAmount, LAUNCH_USDC_TOKENS);

            token.approve(positionManager, LAUNCH_USDC_TOKENS);
            IERC20(USDC).approve(positionManager, p.usdcPairAmount);

            int24 tickSpacingUsdc = _tickSpacing(p.usdcFeeTier);
            int24 tickLowerUsdc   = (MIN_TICK / tickSpacingUsdc) * tickSpacingUsdc;
            int24 tickUpperUsdc   = (MAX_TICK / tickSpacingUsdc) * tickSpacingUsdc;

            (uint256 id,, uint256 used0, uint256 used1) =
                INonfungiblePositionManager(positionManager).mint(
                    INonfungiblePositionManager.MintParams({
                        token0:         token0Usdc,
                        token1:         token1Usdc,
                        fee:            p.usdcFeeTier,
                        tickLower:      tickLowerUsdc,
                        tickUpper:      tickUpperUsdc,
                        amount0Desired: amt0DesiredUsdc,
                        amount1Desired: amt1DesiredUsdc,
                        amount0Min:     0,
                        amount1Min:     0,
                        recipient:      address(locker),
                        deadline:       block.timestamp
                    })
                );

            usdcTokenId = id;

            // Return USDC pool dust to ownerWallet
            uint256 dust0 = amt0DesiredUsdc - used0;
            uint256 dust1 = amt1DesiredUsdc - used1;
            if (dust0 > 0) IERC20(token0Usdc).transfer(p.ownerWallet, dust0);
            if (dust1 > 0) IERC20(token1Usdc).transfer(p.ownerWallet, dust1);
        }

        // ── STEP 8: Mint ETH pool position (40% of launch LP) ────────────────

        uint256 ethTokenId;
        {
            bool tokenIsToken0Eth = tokenAddr < WETH;
            (
                address token0Eth,
                address token1Eth,
                uint256 amt0DesiredEth,
                uint256 amt1DesiredEth
            ) = tokenIsToken0Eth
                ? (tokenAddr, WETH, LAUNCH_ETH_TOKENS, p.ethPairAmount)
                : (WETH, tokenAddr, p.ethPairAmount, LAUNCH_ETH_TOKENS);

            token.approve(positionManager, LAUNCH_ETH_TOKENS);
            IERC20(WETH).approve(positionManager, p.ethPairAmount);

            int24 tickSpacingEth = _tickSpacing(p.ethFeeTier);
            int24 tickLowerEth   = (MIN_TICK / tickSpacingEth) * tickSpacingEth;
            int24 tickUpperEth   = (MAX_TICK / tickSpacingEth) * tickSpacingEth;

            (uint256 id,, uint256 used0, uint256 used1) =
                INonfungiblePositionManager(positionManager).mint(
                    INonfungiblePositionManager.MintParams({
                        token0:         token0Eth,
                        token1:         token1Eth,
                        fee:            p.ethFeeTier,
                        tickLower:      tickLowerEth,
                        tickUpper:      tickUpperEth,
                        amount0Desired: amt0DesiredEth,
                        amount1Desired: amt1DesiredEth,
                        amount0Min:     0,
                        amount1Min:     0,
                        recipient:      address(locker),
                        deadline:       block.timestamp
                    })
                );

            ethTokenId = id;

            // Return ETH pool dust to ownerWallet (as WETH)
            uint256 dust0 = amt0DesiredEth - used0;
            uint256 dust1 = amt1DesiredEth - used1;
            if (dust0 > 0) IERC20(token0Eth).transfer(p.ownerWallet, dust0);
            if (dust1 > 0) IERC20(token1Eth).transfer(p.ownerWallet, dust1);
        }

        // ── STEP 9: Transfer LP reserve to LPLocker ───────────────────────────
        // Remaining factory token balance = LP_RESERVE (27M tokens)
        // Transfer to locker — initializeLP records this as reserveTokens

        uint256 reserveBal = token.balanceOf(address(this));
        if (reserveBal > 0) {
            token.transfer(address(locker), reserveBal);
        }

        assert(token.balanceOf(address(this)) == 0);
        assert(IERC20(USDC).balanceOf(address(this)) == 0);

        // ── STEP 10: Initialize LPLocker with both positions ──────────────────

        locker.initializeLP(usdcTokenId, ethTokenId, p.usdcFeeTier, p.ethFeeTier);

        // ── STEP 11: Register suite ───────────────────────────────────────────

        IWindDownController(windDownController).register(
            tokenAddr,
            address(escrow),
            address(vesting),
            address(treasury),
            address(locker)
        );

        // ── STEP 12: Store metadata and emit ─────────────────────────────────

        ipfsHashes[tokenAddr] = p.ipfsHash;

        emit MerchantDeployed(
            tokenAddr,
            p.ownerWallet,
            p.teamWallet,
            p.operator,
            address(escrow),
            address(vesting),
            address(treasury),
            address(locker),
            p.ipfsHash,
            block.timestamp
        );
    }

    // ── INTERNAL ──────────────────────────────────────────────────────────────

    function _tickSpacing(uint24 fee) internal pure returns (int24) {
        if (fee == 100)   return 1;
        if (fee == 500)   return 10;
        if (fee == 3000)  return 60;
        if (fee == 10000) return 200;
        revert("Invalid fee tier");
    }
}
