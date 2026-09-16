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
import "./Activatable.sol";

/// @title StagedTokenFactory — the same merchant launch, across three transactions
///
/// @notice `TokenFactory.deploy()` costs 17,325,962 gas and Base refuses any transaction
///         above 16,777,216. Not a tuning problem: the most aggressive compiler settings
///         save 38k of the 549k needed. The launch has to be staged.
///
///         Three steps, each an approved-deployer call:
///
///             stageSuite      deploy token and suite contracts, distribute allocations
///             fundAndMintLP   create both pools, mint LP, hold it here
///             activateMerchant  hand LP to the locker, start the clocks, register
///
///         **Nothing is a PunchCard merchant until `activateMerchant`.** Before it the
///         token is not registered, the router will not quote it, the suite's schedules
///         have not started and the locker is empty. After it, nothing here can touch the
///         merchant again: every wallet in the suite is immutable, `register()` refuses a
///         token twice, and there is no function that mutates a registered suite.
///
/// @dev **Why the token address is the id.** An earlier sketch had `stageSuite` return a
///      `suiteId` hashed from the parameters, which stage 2 and 3 would present as a claim.
///      That machinery earns its place only when an untrusted party can advance a staging.
///      Here every step is `onlyApprovedDeployer` and the record is written by this
///      contract, so there is nothing to present and nothing to forge. The token address
///      identifies the suite and the `Stage` enum prevents replay. Simpler, and the reason
///      it is safe is the trust model rather than the cryptography.
///
///      **Why the LP is held here until activation.** Production `LPLocker` has no
///      withdrawal path — that is the guarantee — so if it held LP for a suite that was
///      funded and then abandoned, the seed would be stranded permanently. Staging must not
///      invent a new way to lose money while fixing a gas problem. So stage 2 mints both
///      positions to this contract, and stage 3 hands them over. Before activation the
///      locker is empty and `abortStaging` can return everything; after it, production's
///      promise is untouched because no withdrawal code exists to reason about.
contract StagedTokenFactory {

    using SafeERC20 for IERC20;

    // ── NETWORK CONSTANTS ─────────────────────────────────────────────────────

    uint256 public constant TOTAL_SUPPLY    = 100_000_000 * 1e6;
    uint256 public constant REWARDS_ALLOC   =  45_000_000 * 1e6;
    uint256 public constant LP_ALLOC        =  30_000_000 * 1e6;
    uint256 public constant TEAM_ALLOC      =  15_000_000 * 1e6;
    uint256 public constant TREASURY_ALLOC  =  10_000_000 * 1e6;
    uint256 public constant LAUNCH_LP_ALLOC =   3_000_000 * 1e6;
    uint256 public constant LP_RESERVE      = LP_ALLOC - LAUNCH_LP_ALLOC;

    uint256 public constant MAX_ORACLE_AGE    = 1 hours;
    uint256 public constant EMISSION_DAYS     = 1825;
    uint256 public constant EMISSION_PER_DAY  = REWARDS_ALLOC / EMISSION_DAYS;
    uint256 public constant MAX_DRAWER_DAYS   = 14;
    uint256 public constant MAX_PER_TX        = EMISSION_PER_DAY * MAX_DRAWER_DAYS;
    /// @notice Team vesting: a 30-day cliff, then linear over 730 days.
    /// @dev Changed 2026-09-15, from 180 + 1080. The old curve was a long-term lockup; the
    ///      intent here is launch protection — a short cliff that stops an immediate dump,
    ///      then a steady two-year release. Full unlock at day 760 rather than day 1260.
    ///
    ///      The SHAPE is deliberately not KOKOS's. Its live TeamVesting accrues from the
    ///      start timestamp and uses the cliff only to gate claiming, so 12.3% is claimable
    ///      the instant the cliff passes. `VestingWallet` starts accrual AT the cliff, so
    ///      nothing at all is claimable on day 30. Same two words, different money.
    ///
    ///      `constant`, so this is the schedule for every merchant on the network and not a
    ///      term pSKOOP negotiated. Changing it was clean only because no merchant had
    ///      launched yet.
    uint256 public constant CLIFF_DURATION    = 30 days;
    uint256 public constant VEST_DURATION     = 730 days;
    uint256 public constant TIMELOCK_DURATION = 90 days;

    int24 private constant MIN_TICK = -887272;
    int24 private constant MAX_TICK =  887272;

    // ── IMMUTABLES ────────────────────────────────────────────────────────────

    address public immutable multisig;
    address public immutable windDownController;
    address public immutable positionManager;
    address public immutable USDC;
    address public immutable WETH;
    address public immutable ethUsdOracle;
    address public immutable punchcardFeeRecipient;
    address public immutable suiteDeployer;
    address public immutable lockerDeployer;

    uint256 public immutable MIN_USDC_SEED_USD;
    uint256 public immutable MIN_ETH_SEED_USD;

    // ── LIFECYCLE ─────────────────────────────────────────────────────────────

    /// @notice `Active` and `Aborted` are both terminal, and only `Active` is registered.
    ///
    ///             None -> Staged -> Funded -> Active
    ///                         \         \
    ///                          ---------> Aborted
    enum Stage { None, Staged, Funded, Active, Aborted }

    struct MerchantSuite {
        Stage   stage;
        address ownerWallet;
        address teamWallet;
        address operator;
        address escrow;
        address vesting;
        address treasury;
        address locker;
        uint24  usdcFeeTier;
        uint24  ethFeeTier;
        uint256 usdcTokenId;
        uint256 ethTokenId;
        uint256 usdcSeed;
        uint256 ethSeed;
        bytes32 ipfsHash;
    }

    mapping(address => MerchantSuite) public suites;

    /// @notice Who may stage, fund and activate merchants.
    /// @dev A set rather than a single address, so a compromised or lost hot wallet has a
    ///      standby rather than a recovery project. Multisig-controlled and deliberately
    ///      NOT timelocked: the power to add a deployment path deserves a visible delay
    ///      (see `WindDownController.proposeFactory`), but rotating a key away from an
    ///      attacker is the opposite situation and wants to be immediate.
    mapping(address => bool) public approvedDeployers;

    // ── EVENTS ────────────────────────────────────────────────────────────────

    event SuiteStaged(
        address indexed merchantToken, address indexed ownerWallet, address teamWallet,
        address operator, address rewardEscrow, address vestingWallet,
        address treasuryTimelock, address lpLocker, bytes32 ipfsHash, uint256 timestamp
    );
    event SuiteFunded(
        address indexed merchantToken, uint256 usdcTokenId, uint256 ethTokenId,
        uint256 usdcSeed, uint256 ethSeed, uint256 timestamp
    );
    event MerchantActivated(address indexed merchantToken, uint256 timestamp);
    event StagingAborted(
        address indexed merchantToken, address indexed by, Stage fromStage,
        uint256 usdcReturned, uint256 wethReturned, uint256 timestamp
    );
    event DeployerApproved(address indexed deployer, bool approved, uint256 timestamp);

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
        require(_multisig              != address(0), "Invalid multisig");
        require(_deployer              != address(0), "Invalid deployer");
        require(_windDownController    != address(0), "Invalid controller");
        require(_positionManager       != address(0), "Invalid position manager");
        require(_usdc                  != address(0), "Invalid USDC");
        require(_weth                  != address(0), "Invalid WETH");
        require(_ethUsdOracle          != address(0), "Invalid oracle");
        require(_punchcardFeeRecipient != address(0), "Invalid fee recipient");
        require(_suiteDeployer         != address(0), "Invalid suite deployer");
        require(_lockerDeployer        != address(0), "Invalid locker deployer");
        require(_minUsdcSeedUsd         > 0,          "Invalid USDC minimum");
        require(_minEthSeedUsd          > 0,          "Invalid ETH minimum");

        multisig              = _multisig;
        windDownController    = _windDownController;
        positionManager       = _positionManager;
        USDC                  = _usdc;
        WETH                  = _weth;
        ethUsdOracle          = _ethUsdOracle;
        punchcardFeeRecipient = _punchcardFeeRecipient;
        suiteDeployer         = _suiteDeployer;
        lockerDeployer        = _lockerDeployer;
        MIN_USDC_SEED_USD     = _minUsdcSeedUsd;
        MIN_ETH_SEED_USD      = _minEthSeedUsd;

        approvedDeployers[_deployer] = true;
        emit DeployerApproved(_deployer, true, block.timestamp);
    }

    // ── MODIFIERS ─────────────────────────────────────────────────────────────

    modifier onlyApprovedDeployer() {
        require(approvedDeployers[msg.sender], "Not deployer");
        _;
    }

    modifier onlyMultisig() {
        require(msg.sender == multisig, "Not multisig");
        _;
    }

    // ── DEPLOYER MANAGEMENT ───────────────────────────────────────────────────

    function setDeployer(address who, bool approved) external onlyMultisig {
        require(who != address(0), "Invalid deployer");
        approvedDeployers[who] = approved;
        emit DeployerApproved(who, approved, block.timestamp);
    }

    // ── STAGE 1 ───────────────────────────────────────────────────────────────

    struct StageParams {
        string  name;
        string  symbol;
        bytes32 ipfsHash;
        address ownerWallet;
        address teamWallet;
        address operator;
        uint256 perTxFloor;
        uint256 perTxMax;
    }

    /// @notice Deploy the token and its suite, distribute every non-LP allocation.
    /// @dev Produces an inert suite: no clocks running, nothing registered, locker empty.
    function stageSuite(StageParams calldata p)
        external
        onlyApprovedDeployer
        returns (address tokenAddr)
    {
        require(bytes(p.name).length   > 0,           "Invalid name");
        require(bytes(p.symbol).length > 0,           "Invalid symbol");
        require(p.ipfsHash    != bytes32(0),          "Invalid IPFS hash");
        require(p.ownerWallet != address(0),          "Invalid owner");
        require(p.teamWallet  != address(0),          "Invalid team wallet");
        require(p.operator    != address(0),          "Invalid operator");
        require(p.perTxFloor   > 0,                   "Invalid floor");
        require(p.perTxFloor  <= MAX_PER_TX,          "Floor above ceiling");
        require(p.perTxMax    >= p.perTxFloor,        "Max below floor");
        require(p.perTxMax    <= MAX_PER_TX,          "Max above ceiling");

        ISuiteDeployer sd = ISuiteDeployer(suiteDeployer);

        tokenAddr = sd.deployToken(p.name, p.symbol, TOTAL_SUPPLY, address(this), p.ipfsHash);
        IERC20 token = IERC20(tokenAddr);

        // A fresh CREATE address cannot collide with a live suite, but assert it rather
        // than reason about it — a staged record silently overwritten would be invisible.
        require(suites[tokenAddr].stage == Stage.None, "Token already staged");

        address vesting  = sd.deployVesting(tokenAddr, p.teamWallet, windDownController, CLIFF_DURATION, VEST_DURATION, address(this));
        address treasury = sd.deployTreasury(tokenAddr, p.ownerWallet, windDownController, TIMELOCK_DURATION, address(this));
        address escrow   = sd.deployEscrow(tokenAddr, p.operator, p.ownerWallet, windDownController, REWARDS_ALLOC, p.perTxFloor, p.perTxMax, address(this));
        address locker   = ILockerDeployer(lockerDeployer).deployLocker(
            tokenAddr, p.ownerWallet, windDownController, positionManager,
            address(this), USDC, WETH, punchcardFeeRecipient
        );

        token.safeTransfer(vesting,  TEAM_ALLOC);
        token.safeTransfer(treasury, TREASURY_ALLOC);
        token.safeTransfer(escrow,   REWARDS_ALLOC);

        // The 30% LP allocation stays here until activation, alongside the LP positions
        // stage 2 will mint. Per-token balances, so concurrent stagings cannot commingle.
        assert(token.balanceOf(address(this)) == LP_ALLOC);

        suites[tokenAddr] = MerchantSuite({
            stage:       Stage.Staged,
            ownerWallet: p.ownerWallet,
            teamWallet:  p.teamWallet,
            operator:    p.operator,
            escrow:      escrow,
            vesting:     vesting,
            treasury:    treasury,
            locker:      locker,
            usdcFeeTier: 0,
            ethFeeTier:  0,
            usdcTokenId: 0,
            ethTokenId:  0,
            usdcSeed:    0,
            ethSeed:     0,
            ipfsHash:    p.ipfsHash
        });

        emit SuiteStaged(
            tokenAddr, p.ownerWallet, p.teamWallet, p.operator,
            escrow, vesting, treasury, locker, p.ipfsHash, block.timestamp
        );
    }

    // ── STAGE 2 ───────────────────────────────────────────────────────────────

    struct FundParams {
        address token;
        uint24  usdcFeeTier;
        uint24  ethFeeTier;
        uint256 usdcPairAmount;
        uint256 ethPairAmount;
    }

    /// @notice Pull the seed, create both pools, mint both positions to this contract.
    /// @dev The positions are held here, not by the locker. See the note at the top.
    function fundAndMintLP(FundParams calldata f)
        external
        payable
        onlyApprovedDeployer
    {
        MerchantSuite storage s = suites[f.token];
        require(s.stage == Stage.Staged, "Not staged");

        require(f.usdcPairAmount > 0,               "Invalid USDC amount");
        require(f.ethPairAmount  > 0,               "Invalid ETH amount");
        require(msg.value       == f.ethPairAmount, "ETH amount mismatch");
        require(_validFeeTier(f.usdcFeeTier),       "Invalid USDC fee tier");
        require(_validFeeTier(f.ethFeeTier),        "Invalid ETH fee tier");

        IERC20(USDC).safeTransferFrom(s.ownerWallet, address(this), f.usdcPairAmount);
        IWETH(WETH).deposit{value: f.ethPairAmount}();

        uint256 launchTokensUsdc;
        uint256 launchTokensEth;
        {
            uint256 ethUsdPrice  = _ethUsdPrice();
            uint256 usdcValueUsd = f.usdcPairAmount * 100;
            uint256 ethValueUsd  = (f.ethPairAmount * ethUsdPrice) / 1e18;

            require(usdcValueUsd >= MIN_USDC_SEED_USD, "USDC seed below minimum");
            require(ethValueUsd  >= MIN_ETH_SEED_USD,  "ETH seed below minimum");

            (launchTokensUsdc, launchTokensEth) =
                LaunchPricing.deriveTokenSplit(LAUNCH_LP_ALLOC, usdcValueUsd, ethValueUsd);
        }

        s.usdcFeeTier = f.usdcFeeTier;
        s.ethFeeTier  = f.ethFeeTier;
        s.usdcSeed    = f.usdcPairAmount;
        s.ethSeed     = f.ethPairAmount;

        s.usdcTokenId = _openPool(f.token, USDC, f.usdcFeeTier, launchTokensUsdc, f.usdcPairAmount, s.ownerWallet);
        s.ethTokenId  = _openPool(f.token, WETH, f.ethFeeTier,  launchTokensEth,  f.ethPairAmount,  s.ownerWallet);

        assert(IERC20(USDC).balanceOf(address(this)) == 0);

        s.stage = Stage.Funded;
        emit SuiteFunded(f.token, s.usdcTokenId, s.ethTokenId, f.usdcPairAmount, f.ethPairAmount, block.timestamp);
    }

    // ── STAGE 3 ───────────────────────────────────────────────────────────────

    /// @notice Check the assembly, hand it to the merchant, and put it on the network.
    /// @dev Every check here held by construction when this was one transaction. They are
    ///      assertions now because the assembly can be observed — and therefore interfered
    ///      with — between steps.
    function activateMerchant(address token) external onlyApprovedDeployer {
        MerchantSuite storage s = suites[token];
        require(s.stage == Stage.Funded, "Not funded");

        IERC20 t = IERC20(token);

        // ── the invariants atomicity used to give for free ───────────────────
        require(IERC20Meta(token).totalSupply() == TOTAL_SUPPLY,      "Supply changed");
        require(t.balanceOf(s.escrow)   == REWARDS_ALLOC,             "Escrow allocation wrong");
        require(t.balanceOf(s.vesting)  == TEAM_ALLOC,                "Team allocation wrong");
        require(t.balanceOf(s.treasury) == TREASURY_ALLOC,            "Treasury allocation wrong");
        require(t.balanceOf(s.ownerWallet) == 0,                      "Merchant holds supply");
        require(t.balanceOf(s.locker)   == 0,                         "Locker not empty before handover");
        require(IERC721Min(positionManager).ownerOf(s.usdcTokenId) == address(this), "USDC position not held here");
        require(IERC721Min(positionManager).ownerOf(s.ethTokenId)  == address(this), "ETH position not held here");

        // ── hand the LP over ─────────────────────────────────────────────────
        INonfungiblePositionManager(positionManager).transferFrom(address(this), s.locker, s.usdcTokenId);
        INonfungiblePositionManager(positionManager).transferFrom(address(this), s.locker, s.ethTokenId);

        uint256 reserve = t.balanceOf(address(this));
        if (reserve > 0) t.safeTransfer(s.locker, reserve);

        require(t.balanceOf(s.locker) >= LP_RESERVE, "Reserve short");
        assert(t.balanceOf(address(this)) == 0);

        ILPLocker(s.locker).initializeLP(s.usdcTokenId, s.ethTokenId, s.usdcFeeTier, s.ethFeeTier);

        // ── clocks start here, all at one instant ────────────────────────────
        IActivatable(s.escrow).activate();
        IActivatable(s.vesting).activate();
        IActivatable(s.treasury).activate();
        IActivatable(s.locker).activate();

        s.stage = Stage.Active;

        IWindDownController(windDownController).register(token, s.escrow, s.vesting, s.treasury, s.locker);
        emit MerchantActivated(token, block.timestamp);
    }

    // ── ABORT ─────────────────────────────────────────────────────────────────

    /// @notice Abandon a staging and return any capital. Terminal, and never registers.
    /// @dev Callable by an approved deployer OR the merchant's own owner wallet. Either
    ///      party may need out: if PunchCard goes quiet the merchant must not have capital
    ///      stuck, and if the merchant goes quiet PunchCard must be able to close the
    ///      record. Neither can do it once the merchant is live.
    ///
    ///      The token is left dead rather than cleaned up. It exists on chain holding an
    ///      inert suite, is never registered, never routable and never a PunchCard
    ///      merchant. `Aborted` is terminal, so the address can never be staged again.
    function abortStaging(address token) external {
        MerchantSuite storage s = suites[token];
        require(s.stage == Stage.Staged || s.stage == Stage.Funded, "Not abortable");
        require(
            approvedDeployers[msg.sender] || msg.sender == s.ownerWallet,
            "Not deployer or owner"
        );

        Stage from = s.stage;
        s.stage = Stage.Aborted;          // CEI: terminal before any external call

        uint256 usdcBack;
        uint256 wethBack;

        if (from == Stage.Funded) {
            _drainPosition(s.usdcTokenId);
            _drainPosition(s.ethTokenId);

            // Read balances after both drains rather than summing what each returned:
            // the pair tokens land here from collect(), and a balance read cannot
            // disagree with itself the way two running totals can.
            usdcBack = IERC20(USDC).balanceOf(address(this));
            wethBack = IERC20(WETH).balanceOf(address(this));
            if (usdcBack > 0) IERC20(USDC).safeTransfer(s.ownerWallet, usdcBack);
            if (wethBack > 0) IERC20(WETH).safeTransfer(s.ownerWallet, wethBack);
        }

        // Merchant tokens are NOT returned. They are the factory's own mint, worth nothing
        // outside a live merchant, and sending 30M of a dead token to a wallet is noise at
        // best and a confusing balance at worst. They stay here, inert.

        emit StagingAborted(token, msg.sender, from, usdcBack, wethBack, block.timestamp);
    }

    // ── INTERNAL ──────────────────────────────────────────────────────────────

    /// @dev Create the pool and REVERT if one already exists — deliberately stricter than
    ///      `createAndInitializePoolIfNecessary`, which tolerates it. Under the atomic
    ///      factory the token was minted in the same transaction so its pool could not
    ///      exist; staged, anyone watching the mempool can create it first at a price of
    ///      their choosing and the launch mint would land inside it. Detecting that at
    ///      activation is too late — the seed is already in the poisoned pool.
    function _openPool(
        address token,
        address pair,
        uint24  feeTier,
        uint256 tokenAmount,
        uint256 pairAmount,
        address dustTo
    ) private returns (uint256 tokenId) {
        address uniFactory = INonfungiblePositionManager(positionManager).factory();
        require(
            IUniswapV3Factory(uniFactory).getPool(token, pair, feeTier) == address(0),
            "Pool already exists"
        );

        bool tokenIsToken0 = token < pair;
        (address token0, address token1, uint256 amt0, uint256 amt1) = tokenIsToken0
            ? (token, pair, tokenAmount, pairAmount)
            : (pair, token, pairAmount, tokenAmount);

        IERC20(token).approve(positionManager, tokenAmount);
        IERC20(pair).approve(positionManager, pairAmount);

        INonfungiblePositionManager(positionManager).createAndInitializePoolIfNecessary(
            token0, token1, feeTier, LaunchPricing.encodeSqrtPriceX96(amt0, amt1)
        );

        int24 spacing = _tickSpacing(feeTier);
        (uint256 id,, uint256 used0, uint256 used1) =
            INonfungiblePositionManager(positionManager).mint(
                INonfungiblePositionManager.MintParams({
                    token0: token0, token1: token1, fee: feeTier,
                    tickLower: (MIN_TICK / spacing) * spacing,
                    tickUpper: (MAX_TICK / spacing) * spacing,
                    amount0Desired: amt0, amount1Desired: amt1,
                    amount0Min: 0, amount1Min: 0,
                    recipient: address(this),
                    deadline: block.timestamp
                })
            );
        tokenId = id;

        // Pair-token dust only — the merchant's own capital. Merchant-token dust stays and
        // is swept into the locker as reserve at activation; returning it would let
        // allocation escape the locked 30%.
        uint256 dust0 = amt0 - used0;
        uint256 dust1 = amt1 - used1;
        if (token0 != token && dust0 > 0) IERC20(token0).safeTransfer(dustTo, dust0);
        if (token1 != token && dust1 > 0) IERC20(token1).safeTransfer(dustTo, dust1);
    }

    function _drainPosition(uint256 tokenId) private {
        INonfungiblePositionManager pm = INonfungiblePositionManager(positionManager);
        (,,,,,,, uint128 liq,,,,) = pm.positions(tokenId);
        if (liq > 0) {
            pm.decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId, liquidity: liq, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            }));
        }
        pm.collect(INonfungiblePositionManager.CollectParams({
            tokenId: tokenId, recipient: address(this),
            amount0Max: type(uint128).max, amount1Max: type(uint128).max
        }));
    }

    function _ethUsdPrice() private view returns (uint256) {
        IEthUsdOracle oracle = IEthUsdOracle(ethUsdOracle);
        (, int256 answer,, uint256 updatedAt,) = oracle.latestRoundData();
        require(answer > 0,                                    "Bad oracle answer");
        require(updatedAt != 0,                                "Incomplete round");
        require(block.timestamp - updatedAt <= MAX_ORACLE_AGE, "Stale oracle price");
        uint8 dec = oracle.decimals();
        uint256 price = uint256(answer);
        if (dec < 8)      price = price * (10 ** (8 - dec));
        else if (dec > 8) price = price / (10 ** (dec - 8));
        return price;
    }

    function _validFeeTier(uint24 fee) private pure returns (bool) {
        return fee == 100 || fee == 500 || fee == 3000 || fee == 10000;
    }

    function _tickSpacing(uint24 fee) private pure returns (int24) {
        if (fee == 100)   return 1;
        if (fee == 500)   return 10;
        if (fee == 3000)  return 60;
        if (fee == 10000) return 200;
        revert("Invalid fee tier");
    }

    /// @dev Uniswap mints the position NFT to this contract in stage 2.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

interface IERC20Meta { function totalSupply() external view returns (uint256); }
interface IERC721Min { function ownerOf(uint256 tokenId) external view returns (address); }
