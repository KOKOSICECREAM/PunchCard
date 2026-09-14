// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IWindDownController.sol";
import "./interfaces/ILPLocker.sol";
import "./deployers/ISuiteDeployer.sol";
import "./deployers/ILockerDeployer.sol";
import "./interfaces/INonfungiblePositionManager.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IEthUsdOracle.sol";
import "./libraries/LaunchPricing.sol";

/// @title TokenFactory
/// @notice Deploys full PunchCard merchant suite in a single transaction.
/// @dev Deployer hot wallet executes after off-chain PunchCard review.
///      Multisig updates deployer if compromised.
///      Launch LP: 3% of supply split 60% USDC pool / 40% ETH pool.
///      Remaining 27% held as reserve in LPLocker — merchant deploys over time.
///      Both pools use Uniswap v3 full-range positions.
///      Dust from both mints returns to ownerWallet.
contract TokenFactory {

    using SafeERC20 for IERC20;

    // ── NETWORK CONSTANTS ─────────────────────────────────────────────────────

    uint256 public constant TOTAL_SUPPLY    = 100_000_000 * 1e6;
    uint256 public constant REWARDS_ALLOC   =  45_000_000 * 1e6;
    uint256 public constant LP_ALLOC        =  30_000_000 * 1e6;
    uint256 public constant TEAM_ALLOC      =  15_000_000 * 1e6;
    uint256 public constant TREASURY_ALLOC  =  10_000_000 * 1e6;

    /// @notice Tokens deployed into pools at launch — 3% of total supply
    uint256 public constant LAUNCH_LP_ALLOC    = 3_000_000 * 1e6;

    /// @notice 60% of launch LP goes to USDC pool

    /// @notice 40% of launch LP goes to ETH pool

    /// @notice Remaining 27% held as reserve in LPLocker
    uint256 public constant LP_RESERVE         = LP_ALLOC - LAUNCH_LP_ALLOC; // 27_000_000 * 1e6

    // ── SEED MINIMUMS ────────────────────────────────────────────────────────
    // Floors, not fixed amounts — a merchant, an investor or PunchCard may seed more.
    // Because the amounts vary, the token side of each pool is DERIVED from the USD
    // value seeded (see LaunchPricing), so both pools always open at the same price.
    // Denominated in USD at 8dp to match the Chainlink feed.
    //
    // Constructor arguments rather than constants, so the SAME bytecode runs on a testnet
    // with faucet-sized seeds and on mainnet with real ones. Compiling a special low-
    // minimum build for testing would mean shipping bytecode nobody had exercised.
    //
    // This is PunchCard policy, not a merchant term — deploy() is onlyDeployer, so
    // PunchCard already gates every deployment. Nothing new is trusted here.
    uint256 public immutable MIN_USDC_SEED_USD;
    uint256 public immutable MIN_ETH_SEED_USD;

    /// @notice Reject an oracle answer older than this — a stale ETH price would
    ///         mis-split the pools and hand the first trader an arbitrage.
    uint256 public constant MAX_ORACLE_AGE = 1 hours;

    /// @notice Emission schedule length and the resulting per-day rate.
    /// @dev The escrow derives its own buffer and drawer ceilings from the allocation,
    ///      so there is no separate daily cap to keep in sync here. Mirrored for the
    ///      deploy-time bounds check below.
    uint256 public constant EMISSION_DAYS     = 1825;                       // 5 years
    uint256 public constant EMISSION_PER_DAY  = REWARDS_ALLOC / EMISSION_DAYS;
    uint256 public constant MAX_DRAWER_DAYS   = 14;
    uint256 public constant MAX_PER_TX        = EMISSION_PER_DAY * MAX_DRAWER_DAYS;
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

    /// @notice Chainlink ETH/USD feed — values the ETH seed so the pools can be split
    address public immutable ethUsdOracle;

    /// @notice Receives PunchCard's share of every merchant's LP trading fees.
    /// @dev Passed to each LPLocker at deploy. Immutable per merchant, so a merchant's
    ///      fee destination can never be changed after they launch.
    address public immutable punchcardFeeRecipient;

    /// @notice Construction helpers holding the suite contracts' creation bytecode.
    /// @dev The factory calls these instead of using `new` directly. All five suite
    ///      contracts together are 27,772 bytes of initcode, which no single contract can
    ///      carry under EIP-170 — hence two helpers rather than one.
    address public immutable suiteDeployer;
    address public immutable lockerDeployer;

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
        address _weth,
        address _ethUsdOracle,
        address _punchcardFeeRecipient,
        address _suiteDeployer,
        address _lockerDeployer,
        uint256 _minUsdcSeedUsd,
        uint256 _minEthSeedUsd
    ) {
        require(_multisig            != address(0), "Invalid multisig");
        require(_deployer            != address(0), "Invalid deployer");
        require(_windDownController  != address(0), "Invalid controller");
        require(_positionManager     != address(0), "Invalid position manager");
        require(_usdc                != address(0), "Invalid USDC");
        require(_weth                != address(0), "Invalid WETH");
        require(_ethUsdOracle        != address(0), "Invalid oracle");
        require(_punchcardFeeRecipient != address(0), "Invalid fee recipient");
        require(_suiteDeployer       != address(0), "Invalid suite deployer");
        require(_lockerDeployer      != address(0), "Invalid locker deployer");
        require(_minUsdcSeedUsd       > 0,          "Invalid USDC minimum");
        require(_minEthSeedUsd        > 0,          "Invalid ETH minimum");

        multisig            = _multisig;
        deployer            = _deployer;
        windDownController  = _windDownController;
        positionManager     = _positionManager;
        USDC                = _usdc;
        WETH                = _weth;
        ethUsdOracle        = _ethUsdOracle;
        punchcardFeeRecipient = _punchcardFeeRecipient;
        suiteDeployer       = _suiteDeployer;
        lockerDeployer      = _lockerDeployer;
        MIN_USDC_SEED_USD   = _minUsdcSeedUsd;
        MIN_ETH_SEED_USD    = _minEthSeedUsd;
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
        require(p.perTxFloor           <= MAX_PER_TX, "Floor above ceiling");
        require(p.perTxMax             >= p.perTxFloor,"Max below floor");
        require(p.perTxMax             <= MAX_PER_TX, "Max above ceiling");
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

        // safeTransferFrom reverts on failure, so no return value to check.
        IERC20(USDC).safeTransferFrom(p.ownerWallet, address(this), p.usdcPairAmount);

        IWETH(WETH).deposit{value: p.ethPairAmount}();

        // ── STEP 0b: Value the seed, enforce minimums, derive the token split ──
        // Seed amounts are floors, not fixed sizes. Whoever funds the pools — merchant,
        // investor or PunchCard — may put in more. The token side of each pool is
        // therefore derived from the USD value actually seeded, which is what keeps the
        // two pools opening at the same price. See LaunchPricing.

        uint256 usdcValueUsd;
        uint256 ethValueUsd;
        uint256 launchTokensUsdc;
        uint256 launchTokensEth;
        {
            uint256 ethUsdPrice = _ethUsdPrice();          // 8dp

            // USDC is 6dp and dollar-denominated; restate at the oracle's 8dp.
            usdcValueUsd = p.usdcPairAmount * 100;
            ethValueUsd  = (p.ethPairAmount * ethUsdPrice) / 1e18;

            require(usdcValueUsd >= MIN_USDC_SEED_USD, "USDC seed below minimum");
            require(ethValueUsd  >= MIN_ETH_SEED_USD,  "ETH seed below minimum");

            (launchTokensUsdc, launchTokensEth) = LaunchPricing.deriveTokenSplit(
                LAUNCH_LP_ALLOC, usdcValueUsd, ethValueUsd
            );
        }

        // ── STEPS 1-5: Deploy the suite via the construction helpers ─────────
        // Delegated rather than `new`-ed inline so this contract does not carry the
        // suite's creation bytecode. `token` is deliberately typed as IERC20: taking a
        // concrete MerchantToken type here would pull its bytecode straight back in.

        IERC20 token;
        address vesting;
        address treasury;
        address escrow;
        address locker;
        address tokenAddr;
        {
            ISuiteDeployer sd = ISuiteDeployer(suiteDeployer);

            // Entire supply is minted to this factory, which distributes it below.
            tokenAddr = sd.deployToken(p.name, p.symbol, TOTAL_SUPPLY, address(this), p.ipfsHash);
            token     = IERC20(tokenAddr);

            vesting  = sd.deployVesting(tokenAddr, p.teamWallet, windDownController, CLIFF_DURATION, VEST_DURATION);
            treasury = sd.deployTreasury(tokenAddr, p.ownerWallet, windDownController, TIMELOCK_DURATION);
            escrow   = sd.deployEscrow(tokenAddr, p.operator, p.ownerWallet, windDownController, REWARDS_ALLOC, p.perTxFloor, p.perTxMax);

            // `factory` is this contract, so initializeLP() below passes onlyFactory.
            locker = ILockerDeployer(lockerDeployer).deployLocker(
                tokenAddr, p.ownerWallet, windDownController, positionManager,
                address(this), USDC, WETH, punchcardFeeRecipient
            );
        }

        // ── STEP 6: Distribute non-LP allocations ────────────────────────────

        token.safeTransfer(vesting,  TEAM_ALLOC);
        token.safeTransfer(treasury, TREASURY_ALLOC);
        token.safeTransfer(escrow,   REWARDS_ALLOC);
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
                ? (tokenAddr, USDC, launchTokensUsdc, p.usdcPairAmount)
                : (USDC, tokenAddr, p.usdcPairAmount, launchTokensUsdc);

            token.approve(positionManager, launchTokensUsdc);
            IERC20(USDC).approve(positionManager, p.usdcPairAmount);

            // The merchant token was created moments ago in this same transaction, so its
            // pool cannot exist yet. mint() reverts against an uninitialised pool, and
            // sqrtPriceX96 is what actually sets the launch price.
            INonfungiblePositionManager(positionManager).createAndInitializePoolIfNecessary(
                token0Usdc,
                token1Usdc,
                p.usdcFeeTier,
                LaunchPricing.encodeSqrtPriceX96(amt0DesiredUsdc, amt1DesiredUsdc)
            );

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
                        recipient:      locker,
                        deadline:       block.timestamp
                    })
                );

            usdcTokenId = id;

            // Return USDC pool dust to ownerWallet
            uint256 dust0 = amt0DesiredUsdc - used0;
            uint256 dust1 = amt1DesiredUsdc - used1;
            if (dust0 > 0) IERC20(token0Usdc).safeTransfer(p.ownerWallet, dust0);
            if (dust1 > 0) IERC20(token1Usdc).safeTransfer(p.ownerWallet, dust1);
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
                ? (tokenAddr, WETH, launchTokensEth, p.ethPairAmount)
                : (WETH, tokenAddr, p.ethPairAmount, launchTokensEth);

            token.approve(positionManager, launchTokensEth);
            IERC20(WETH).approve(positionManager, p.ethPairAmount);

            // The merchant token was created moments ago in this same transaction, so its
            // pool cannot exist yet. mint() reverts against an uninitialised pool, and
            // sqrtPriceX96 is what actually sets the launch price.
            INonfungiblePositionManager(positionManager).createAndInitializePoolIfNecessary(
                token0Eth,
                token1Eth,
                p.ethFeeTier,
                LaunchPricing.encodeSqrtPriceX96(amt0DesiredEth, amt1DesiredEth)
            );

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
                        recipient:      locker,
                        deadline:       block.timestamp
                    })
                );

            ethTokenId = id;

            // Return ETH pool dust to ownerWallet (as WETH)
            uint256 dust0 = amt0DesiredEth - used0;
            uint256 dust1 = amt1DesiredEth - used1;
            if (dust0 > 0) IERC20(token0Eth).safeTransfer(p.ownerWallet, dust0);
            if (dust1 > 0) IERC20(token1Eth).safeTransfer(p.ownerWallet, dust1);
        }

        // ── STEP 9: Transfer LP reserve to LPLocker ───────────────────────────
        // Remaining factory token balance = LP_RESERVE (27M tokens)
        // Transfer to locker — initializeLP records this as reserveTokens

        uint256 reserveBal = token.balanceOf(address(this));
        if (reserveBal > 0) {
            token.safeTransfer(locker, reserveBal);
        }

        assert(token.balanceOf(address(this)) == 0);
        assert(IERC20(USDC).balanceOf(address(this)) == 0);

        // ── STEP 10: Initialize LPLocker with both positions ──────────────────

        ILPLocker(locker).initializeLP(usdcTokenId, ethTokenId, p.usdcFeeTier, p.ethFeeTier);

        // ── STEP 11: Register suite ───────────────────────────────────────────

        IWindDownController(windDownController).register(
            tokenAddr,
            escrow,
            vesting,
            treasury,
            locker
        );

        // ── STEP 12: Store metadata and emit ─────────────────────────────────

        ipfsHashes[tokenAddr] = p.ipfsHash;

        emit MerchantDeployed(
            tokenAddr,
            p.ownerWallet,
            p.teamWallet,
            p.operator,
            escrow,
            vesting,
            treasury,
            locker,
            p.ipfsHash,
            block.timestamp
        );
    }

    // ── INTERNAL ──────────────────────────────────────────────────────────────

    /// @notice ETH/USD normalised to 8dp, with staleness and sanity checks.
    /// @dev A stale or negative answer would mis-split the pools, so this reverts rather
    ///      than deploying a merchant at a wrong price.
    function _ethUsdPrice() internal view returns (uint256) {
        IEthUsdOracle oracle = IEthUsdOracle(ethUsdOracle);
        (, int256 answer,, uint256 updatedAt,) = oracle.latestRoundData();

        require(answer > 0,                                     "Bad oracle answer");
        require(updatedAt != 0,                                 "Incomplete round");
        require(block.timestamp - updatedAt <= MAX_ORACLE_AGE,  "Stale oracle price");

        uint8 dec = oracle.decimals();
        uint256 price = uint256(answer);
        if (dec < 8)      price = price * (10 ** (8 - dec));
        else if (dec > 8) price = price / (10 ** (dec - 8));
        return price;
    }

    function _tickSpacing(uint24 fee) internal pure returns (int24) {
        if (fee == 100)   return 1;
        if (fee == 500)   return 10;
        if (fee == 3000)  return 60;
        if (fee == 10000) return 200;
        revert("Invalid fee tier");
    }
}
