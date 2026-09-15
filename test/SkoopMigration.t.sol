// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/beta/TokenFactoryBeta.sol";
import "../contracts/beta/LockerDeployerBeta.sol";
import "../contracts/beta/LPLockerBeta.sol";
import "../contracts/WindDownController.sol";
import "../contracts/RewardEscrow.sol";
import "../contracts/VestingWallet.sol";
import "../contracts/TreasuryTimelock.sol";
import "../contracts/deployers/SuiteDeployer.sol";
import "../contracts/interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title SKOOP migration rehearsal — the real cutover, against live Base state
///
/// @notice `ForkDeploy.t.sol` proves `deploy()` works. It says nothing about the operation
///         that is actually frightening: pulling KOKOS's live SKOOP liquidity, relaunching
///         through the beta factory with that exact capital, running the suite for a year
///         of simulated time, and getting the money back out if something is wrong.
///
///         This is that rehearsal. It answers four questions, each as a pass/fail rather
///         than a judgement call:
///
///         1. Can the live SKOOP LP actually be recovered, and how much comes out?
///         2. Does the recovered capital clear the factory's seed floors?
///         3. Does the migrated suite operate — rewards, vesting, treasury, fees?
///         4. Do the two exits work — the beta hatch, and the never-yet-used wind-down?
///
///         Run with:
///           forge test --match-path test/SkoopMigration.t.sol --fork-url https://mainnet.base.org -vv
///
///         Phase 1 drains the REAL positions, so it needs the wallet that holds them:
///           PC_SKOOP_LP_OWNER=0x... forge test ...
///
///         Without that variable the drain is skipped and the rehearsal runs on the
///         capital figures below, which is still worth running — but do not call the
///         migration rehearsed until phase 1 has executed against the real positions.
///         A test that quietly substitutes made-up capital for the real thing is exactly
///         the kind of green tick this codebase has been burned by before.
contract SkoopMigrationTest is Test {

    // ── LIVE BASE INFRASTRUCTURE ─────────────────────────────────────────────
    // Verified on-chain 2026-09-13, chainId 8453 — see deploy/network/base-mainnet.json
    address constant POSITION_MANAGER = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address constant SWAP_ROUTER      = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant USDC             = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH             = 0x4200000000000000000000000000000000000006;
    address constant ETH_USD_FEED     = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    // ── LIVE KOKOS DEPLOYMENT ────────────────────────────────────────────────
    // From KOKOS/README.md, "Smart Contracts (Base Mainnet)".
    address constant SKOOP_V1         = 0xfd3ce21c5Acd8BbbE576d0E2336C210C3cEBeb92;
    address constant SKOOP_USDC_POOL  = 0x64Ef20F32445EB0A86f4b97CA895fE508AF253CD;
    address constant SKOOP_ETH_POOL   = 0xc1D89ca13D5cBC24B92e9F40B36d43Da347c5198;

    // ── REHEARSAL WALLETS ────────────────────────────────────────────────────
    address constant MULTISIG  = address(0xA1);
    address constant FEE_RECIP = address(0xA2);
    address constant OWNER     = address(0xB1);   // KOKOS merchant wallet
    address constant TEAM      = address(0xB2);
    address constant OPERATOR  = address(0xB3);   // the POS kiosk
    address constant CUSTOMER  = address(0xC0FFEE);
    address constant TRADER    = address(0xDEAF);

    /// @notice Fallback capital if the real LP is not drained, sized to the live pool.
    /// @dev ROADMAP.md records a ~$720 pool as of 2026-09-14. Deliberately NOT rounded up
    ///      to something comfortable — the whole point of phase 2 is to find out whether
    ///      the real figure clears the real floors, and a flattering default would hide
    ///      the answer.
    uint256 constant ASSUMED_USDC_RECOVERED = 360 * 1e6;      // ~$360
    uint256 constant ASSUMED_ETH_RECOVERED  = 0.145 ether;    // ~$360 at ~$2,475/ETH

    // ── MAINNET POLICY FLOORS ────────────────────────────────────────────────
    uint256 constant MAINNET_USDC_FLOOR = 2_000 * 1e8;
    uint256 constant MAINNET_ETH_FLOOR  = 1_000 * 1e8;

    SuiteDeployer      suiteDeployer;
    LockerDeployerBeta lockerDeployer;

    bool forked;

    struct Suite {
        TokenFactoryBeta   factory;
        WindDownController wdc;
        address token;
        address escrow;
        address vesting;
        address treasury;
        address locker;
        uint24  usdcFeeTier;
        uint24  ethFeeTier;
    }

    function setUp() public {
        if (block.chainid != 8453) return;
        forked = true;

        suiteDeployer  = new SuiteDeployer();
        lockerDeployer = new LockerDeployerBeta();
    }

    function _requireFork() internal {
        if (!forked) {
            emit log("SKIPPED - needs --fork-url https://mainnet.base.org");
            vm.skip(true);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // PHASE 1 — can the live SKOOP liquidity actually be recovered?
    // ═════════════════════════════════════════════════════════════════════════

    /// The step that makes old SKOOP untradeable and funds the relaunch. It is the one
    /// action in the whole migration that is visible to holders before anything good has
    /// happened, so it had better not fail halfway.
    function test_phase1_liveSkoopLiquidityIsRecoverable() public {
        _requireFork();

        address lpOwner = vm.envOr("PC_SKOOP_LP_OWNER", address(0));
        if (lpOwner == address(0)) {
            emit log("SKIPPED - set PC_SKOOP_LP_OWNER to the wallet holding the SKOOP v3 positions");
            vm.skip(true);
        }

        uint256 positionsFound = _skoopPositionCount(lpOwner);
        assertGt(positionsFound, 0, "lpOwner holds no SKOOP positions - wrong wallet?");

        uint256 usdcBefore = IERC20(USDC).balanceOf(lpOwner);
        uint256 wethBefore = IERC20(WETH).balanceOf(lpOwner);
        uint256 skoopBefore = IERC20(SKOOP_V1).balanceOf(lpOwner);

        (uint256 usdcOut, uint256 wethOut, uint256 skoopOut) = _drainSkoopPositions(lpOwner);

        assertEq(IERC20(USDC).balanceOf(lpOwner) - usdcBefore, usdcOut, "USDC landed with lpOwner");
        assertEq(IERC20(WETH).balanceOf(lpOwner) - wethBefore, wethOut, "WETH landed with lpOwner");
        assertEq(IERC20(SKOOP_V1).balanceOf(lpOwner) - skoopBefore, skoopOut, "SKOOP landed with lpOwner");

        // Something must have come out. A silent zero-recovery would otherwise read as a
        // successful pull, and the announcement would already have gone out.
        assertTrue(usdcOut > 0 || wethOut > 0, "no pair capital recovered from either pool");

        // And the positions must be empty afterwards, not partially drained.
        assertEq(_skoopLiquidityRemaining(lpOwner), 0, "liquidity left behind in a SKOOP position");

        emit log_named_uint("positions drained", positionsFound);
        emit log_named_decimal_uint("USDC recovered", usdcOut, 6);
        emit log_named_decimal_uint("WETH recovered", wethOut, 18);
        emit log_named_decimal_uint("SKOOP recovered", skoopOut, 6);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // PHASE 2 — does the recovered capital clear the seed floors?
    // ═════════════════════════════════════════════════════════════════════════

    /// The question that decides which factory KOKOS can relaunch through, and it is an
    /// economics question wearing a require() costume. A $720 pool does not clear $2,000 +
    /// $1,000, so either fresh capital goes in or the relaunch uses micro floors — and
    /// that is a decision to make deliberately, not discover in a reverted mainnet tx.
    function test_phase2_recoveredCapitalAgainstSeedFloors() public {
        _requireFork();

        (uint256 usdcCapital, uint256 ethCapital) = _migrationCapital();

        uint256 ethUsdPrice = _ethUsdPrice();                 // 8dp
        uint256 usdcValueUsd = usdcCapital * 100;             // 6dp -> 8dp
        uint256 ethValueUsd  = (ethCapital * ethUsdPrice) / 1e18;

        emit log_named_decimal_uint("USDC side, USD", usdcValueUsd, 8);
        emit log_named_decimal_uint("ETH side, USD",  ethValueUsd,  8);
        emit log_named_decimal_uint("total, USD",     usdcValueUsd + ethValueUsd, 8);

        bool clearsMainnet = usdcValueUsd >= MAINNET_USDC_FLOOR && ethValueUsd >= MAINNET_ETH_FLOOR;

        if (clearsMainnet) {
            emit log("recovered capital clears the $2,000 / $1,000 mainnet floors");
        } else {
            emit log("recovered capital does NOT clear mainnet floors - relaunch needs fresh capital or a micro-floor factory");
            emit log_named_decimal_uint("USDC shortfall, USD",
                usdcValueUsd >= MAINNET_USDC_FLOOR ? 0 : MAINNET_USDC_FLOOR - usdcValueUsd, 8);
            emit log_named_decimal_uint("ETH shortfall, USD",
                ethValueUsd >= MAINNET_ETH_FLOOR ? 0 : MAINNET_ETH_FLOOR - ethValueUsd, 8);
        }

        // Whatever the answer, a factory built at the mainnet floors must actually reject
        // this capital when it is short. The floors existing is not the same as the floors
        // binding, and only one of those protects anything.
        if (!clearsMainnet) {
            TokenFactoryBeta strict = _newFactory(MAINNET_USDC_FLOOR, MAINNET_ETH_FLOOR);
            _fund(OWNER, usdcCapital, ethCapital);
            vm.prank(OWNER);
            IERC20(USDC).approve(address(strict), usdcCapital);

            vm.expectRevert(
                usdcValueUsd < MAINNET_USDC_FLOOR
                    ? bytes("USDC seed below minimum")
                    : bytes("ETH seed below minimum")
            );
            strict.deploy{value: ethCapital}(_params("KOKOS SKOOPS", "SKOOP", usdcCapital, ethCapital));
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // PHASE 3 — the migrated suite has to actually run
    // ═════════════════════════════════════════════════════════════════════════

    /// Deploy the relaunched SKOOP from real recovered capital and then use it: issue a
    /// reward from the POS drawer, trade against the pools, collect fees. This is the part
    /// KOKOS's live contracts cannot vouch for — different code, different guarantees.
    function test_phase3_migratedSuiteOperates() public {
        _requireFork();
        Suite memory s = _deployMigratedSuite();

        // ── the beta marker is queryable, so nobody has to trust a doc ──
        assertTrue(s.factory.HAS_LP_RECOVERY(), "factory advertises LP recovery");
        assertTrue(LPLockerBeta(s.locker).evacuationOpen(), "hatch open at launch");

        // ── allocations landed exactly where the migration plan says ──
        assertEq(IERC20(s.token).totalSupply(),          100_000_000 * 1e6, "100M supply");
        assertEq(IERC20(s.token).balanceOf(s.escrow),     45_000_000 * 1e6, "45M rewards");
        assertEq(IERC20(s.token).balanceOf(s.vesting),    15_000_000 * 1e6, "15M team");
        assertEq(IERC20(s.token).balanceOf(s.treasury),   10_000_000 * 1e6, "10M treasury");
        assertGe(IERC20(s.token).balanceOf(s.locker),     27_000_000 * 1e6, "27M LP reserve");
        assertEq(IERC20(s.token).balanceOf(OWNER),                       0, "merchant holds no supply at launch");
        assertTrue(s.wdc.isRegistered(s.token), "on the network");

        // ── day zero: the escrow pays nothing, and that is correct ──
        // emitted() accrues from deploy, so spendable() is ~0 in the first minutes. This
        // WILL look like a bricked POS on launch day if nobody is expecting it.
        assertEq(RewardEscrow(s.escrow).emitted(), 0, "nothing emitted at t=0");
        vm.prank(OPERATOR);
        vm.expectRevert("Emission limit");
        RewardEscrow(s.escrow).distributeReward(CUSTOMER, 1_000 * 1e6);

        // ── after a day of emission, the kiosk works ──
        vm.warp(block.timestamp + 1 days);
        uint256 perDay = uint256(45_000_000 * 1e6) / 1825;
        assertApproxEqRel(RewardEscrow(s.escrow).emitted(), perDay, 0.01e18, "one day of emission");

        vm.prank(OPERATOR);
        RewardEscrow(s.escrow).distributeReward(CUSTOMER, 1_000 * 1e6);
        assertEq(IERC20(s.token).balanceOf(CUSTOMER), 1_000 * 1e6, "reward delivered to customer");

        // ── a real trade against the new pools, then fees collected and split ──
        _swapUsdcForMerchantToken(s, 50 * 1e6);

        uint256 feeRecipBefore = IERC20(USDC).balanceOf(FEE_RECIP);
        (uint256 usdcFee,, uint256 burned) = LPLockerBeta(s.locker).collectFees();
        assertEq(IERC20(USDC).balanceOf(FEE_RECIP) - feeRecipBefore, usdcFee, "network fee paid to PunchCard");
        assertGt(usdcFee + burned, 0, "the trade generated collectable fees");

        emit log_named_address("relaunched SKOOP", s.token);
        emit log_named_decimal_uint("network fee from one $50 trade, USDC", usdcFee, 6);
    }

    /// Vesting and the treasury run on a much longer clock than the evacuation window, so
    /// they get their own timeline. The assertion that matters is the SHAPE of the curve:
    /// PunchCard restarts vesting at the cliff, where KOKOS's live TeamVesting accrues
    /// from deploy and merely gates claiming at the cliff. Same words, different money.
    function test_phase3_vestingAndTreasuryOnTheLongClock() public {
        _requireFork();
        Suite memory s = _deployMigratedSuite();

        // Read the schedule back from the contract rather than computing it from a cached
        // `block.timestamp`. Under `via_ir` the optimiser treats block.timestamp as
        // loop-invariant and folds a local copy of it back into a fresh read, so a second
        // `vm.warp(start + N)` lands at `now + N` instead of `start + N` and every
        // subsequent warp compounds. These getters are external calls, so they cannot be
        // folded. See the note on _absoluteWarpHazard below.
        uint256 cliff   = VestingWallet(s.vesting).cliffTime();
        uint256 vestEnd = VestingWallet(s.vesting).vestingEnd();

        assertEq(cliff - VestingWallet(s.vesting).vestingStart(), 180 days, "180-day cliff");
        assertEq(vestEnd - cliff, 1080 days, "1080-day ramp AFTER the cliff, not from launch");

        // ── nothing before the cliff, and release() is a silent no-op, not a revert ──
        vm.warp(cliff - 1 days);
        VestingWallet(s.vesting).release();
        assertEq(IERC20(s.token).balanceOf(TEAM), 0, "no team tokens before the 180-day cliff");

        // ── at the cliff itself, still zero. This is the KOKOS divergence. ──
        // KOKOS's live TeamVesting accrues from its start timestamp and only GATES claiming
        // at the cliff, so ~17% of the team allocation is claimable the instant the cliff
        // passes. PunchCard restarts the clock at the cliff: zero here, then linear over
        // the following 1080 days. Same three words in the docs, different money.
        vm.warp(cliff);
        assertEq(VestingWallet(s.vesting).totalVested(), 0, "vesting RESTARTS at the cliff, it does not unlock a chunk");
        VestingWallet(s.vesting).release();
        assertEq(IERC20(s.token).balanceOf(TEAM), 0, "still nothing at the cliff instant");

        // ── half way through the post-cliff ramp ──
        vm.warp(cliff + 540 days);
        VestingWallet(s.vesting).release();
        assertApproxEqRel(IERC20(s.token).balanceOf(TEAM), 7_500_000 * 1e6, 0.001e18, "half of 15M at the midpoint");

        // ── fully vested at launch + 1260 days, not launch + 1080 ──
        vm.warp(vestEnd);
        VestingWallet(s.vesting).release();
        assertEq(IERC20(s.token).balanceOf(TEAM), 15_000_000 * 1e6, "fully vested at start + cliff + duration");
        assertEq(IERC20(s.token).balanceOf(s.vesting), 0, "vesting wallet emptied");

        // ── treasury: submit, wait out the 90 days, execute ──
        vm.prank(OWNER);
        TreasuryTimelock(s.treasury).submitRelease(1_000_000 * 1e6);

        vm.expectRevert("Timelock active");
        TreasuryTimelock(s.treasury).executeRelease();

        // Same reasoning as above — take the deadline from the contract, not from arithmetic
        // on a cached timestamp.
        uint256 availableAt = TreasuryTimelock(s.treasury).getPendingRelease().availableAt;
        assertEq(availableAt - block.timestamp, 90 days, "90-day treasury delay");

        vm.warp(availableAt);
        uint256 ownerBefore = IERC20(s.token).balanceOf(OWNER);
        TreasuryTimelock(s.treasury).executeRelease();
        assertEq(IERC20(s.token).balanceOf(OWNER) - ownerBefore, 1_000_000 * 1e6, "treasury released after 90 days");
    }

    /// Not a test of the protocol — a test of the harness this repo tests the protocol with.
    ///
    /// `via_ir` is mandatory here (TokenFactory.deploy() will not compile without it), and
    /// under it the optimiser folds a cached `uint256 start = block.timestamp` back into a
    /// fresh read of block.timestamp, because nothing in the language says a timestamp can
    /// move inside a call. `vm.warp` moves it anyway. The result is that a sequence of
    /// supposedly ABSOLUTE warps silently becomes RELATIVE and compounds:
    ///
    ///     uint256 start = block.timestamp;
    ///     vm.warp(start + 179 days);   // lands at start + 179d  — correct
    ///     vm.warp(start + 180 days);   // lands at start + 359d  — NOT correct
    ///
    /// A test written that way still passes whenever the assertion is monotonic in time,
    /// so it does not announce itself. It just quietly checks a different, later moment
    /// than the one named in the test. This pins the behaviour so that if a future solc or
    /// foundry fixes it, this test fails and the workarounds above can be removed.
    function test_absoluteWarpHazard_cachedTimestampCompounds() public {
        // vm.getBlockTimestamp() is a cheatcode staticcall, so the optimiser has to honour
        // it. A plain `block.timestamp` read is what it is free to fold.
        uint256 real   = vm.getBlockTimestamp();
        uint256 cached = block.timestamp;

        vm.warp(real + 100 days);
        vm.warp(cached + 100 days);   // names the same instant as the line above

        assertEq(
            vm.getBlockTimestamp(),
            real + 200 days,
            "absolute warps against a cached block.timestamp no longer compound - the getter workarounds above can be simplified"
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // PHASE 4 — both exits
    // ═════════════════════════════════════════════════════════════════════════

    /// The safety net the whole beta stage rests on: if the relaunch is wrong, the capital
    /// that came out of old SKOOP goes back to the merchant rather than sitting in a
    /// locker for a year. Nothing has ever proved this against live Uniswap positions.
    function test_phase4_capitalCanBeEvacuatedAfterMigration() public {
        _requireFork();

        (uint256 usdcCapital, uint256 ethCapital) = _migrationCapital();
        Suite memory s = _deployMigratedSuite();

        // Operate a little first — evacuation has to work from a used suite, not a pristine one.
        vm.warp(block.timestamp + 1 days);
        vm.prank(OPERATOR);
        RewardEscrow(s.escrow).distributeReward(CUSTOMER, 1_000 * 1e6);
        _swapUsdcForMerchantToken(s, 50 * 1e6);

        uint256 usdcBefore  = IERC20(USDC).balanceOf(OWNER);
        uint256 wethBefore  = IERC20(WETH).balanceOf(OWNER);

        vm.prank(OWNER);
        LPLockerBeta(s.locker).evacuateLP();

        uint256 usdcBack = IERC20(USDC).balanceOf(OWNER) - usdcBefore;
        uint256 wethBack = IERC20(WETH).balanceOf(OWNER) - wethBefore;

        // The trade moved the pool, so this is not a round trip to the cent. What must
        // hold is that the great majority of the seeded capital comes home — a hatch that
        // returns a fraction is not a hatch.
        assertGe(usdcBack + wethBack, 0, "types");
        assertGt(usdcBack, (usdcCapital * 90) / 100, "most of the USDC seed recovered");
        assertGt(wethBack, (ethCapital  * 90) / 100, "most of the ETH seed recovered");

        // The reserve comes home too, and the locker is dead afterwards.
        assertGe(IERC20(s.token).balanceOf(OWNER), 27_000_000 * 1e6, "27M reserve returned");
        assertEq(IERC20(s.token).balanceOf(s.locker), 0, "locker emptied of merchant tokens");
        assertTrue(LPLockerBeta(s.locker).lpPermanentlyLocked(), "locker bricked by evacuation");
        assertFalse(LPLockerBeta(s.locker).evacuationOpen(), "hatch closed forever");

        vm.expectRevert("Frozen");
        LPLockerBeta(s.locker).collectFees();

        emit log_named_decimal_uint("USDC recovered from the relaunch", usdcBack, 6);
        emit log_named_decimal_uint("WETH recovered from the relaunch", wethBack, 18);
    }

    /// WindDownController has never been executed against a real deployment. It is not on
    /// the operating path — every suite contract gates it behind onlyWindDown, and their
    /// notFrozen checks read a local bool rather than calling out — so a bug here cannot
    /// brick day-to-day SKOOP. But it is a promise made to merchants, and an untested
    /// promise is a lie with good intentions.
    function test_phase4_windDownCompletesOnAMigratedSuite() public {
        _requireFork();
        Suite memory s = _deployMigratedSuite();

        // Run the suite for a while first, so the wind-down settles real balances.
        vm.warp(block.timestamp + 200 days);
        vm.prank(OPERATOR);
        RewardEscrow(s.escrow).distributeReward(CUSTOMER, 10_000 * 1e6);
        VestingWallet(s.vesting).release();

        uint256 supplyBefore = IERC20(s.token).totalSupply();

        // ── initiate freezes all three, immediately ──
        vm.prank(MULTISIG);
        s.wdc.initiate(s.token);

        assertTrue(RewardEscrow(s.escrow).isFrozen(),    "escrow frozen");
        assertTrue(LPLockerBeta(s.locker).isFrozen(),    "LP frozen");
        assertTrue(s.wdc.isInitiated(s.token),           "wind-down initiated");

        vm.prank(OPERATOR);
        vm.expectRevert();
        RewardEscrow(s.escrow).distributeReward(CUSTOMER, 1_000 * 1e6);

        // ── the terminal gate refuses to open early ──
        vm.expectRevert("Not expired");
        s.wdc.onExpiryBurnEscrow(s.token);

        vm.warp(block.timestamp + 365 days);

        vm.expectRevert("Settle other steps first");
        s.wdc.onExpiryReleaseLP(s.token);

        // ── settle each leg, then release LP ──
        s.wdc.onExpiryBurnEscrow(s.token);
        s.wdc.onExpiryBurnTreasury(s.token);
        s.wdc.onExpirySettleVesting(s.token);
        s.wdc.onExpiryReleaseLP(s.token);

        assertTrue(s.wdc.isComplete(s.token), "wind-down complete");
        assertEq(IERC20(s.token).balanceOf(s.escrow),   0, "escrow burned");
        assertEq(IERC20(s.token).balanceOf(s.treasury), 0, "treasury burned");
        assertEq(IERC20(s.token).balanceOf(s.vesting),  0, "vesting settled");
        assertLt(IERC20(s.token).totalSupply(), supplyBefore, "undistributed supply was burned");

        emit log_named_decimal_uint("supply burned by wind-down", supplyBefore - IERC20(s.token).totalSupply(), 6);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ═════════════════════════════════════════════════════════════════════════

    /// Capital for the relaunch: the real drained LP when PC_SKOOP_LP_OWNER is set,
    /// otherwise the documented estimate. Logs which one it used — a rehearsal that is
    /// vague about whether it touched real money is not a rehearsal.
    function _migrationCapital() internal returns (uint256 usdcCapital, uint256 ethCapital) {
        address lpOwner = vm.envOr("PC_SKOOP_LP_OWNER", address(0));

        if (lpOwner == address(0)) {
            emit log("capital source: ESTIMATE (set PC_SKOOP_LP_OWNER to drain the real positions)");
            return (ASSUMED_USDC_RECOVERED, ASSUMED_ETH_RECOVERED);
        }

        (uint256 usdcOut, uint256 wethOut,) = _drainSkoopPositions(lpOwner);
        emit log("capital source: REAL, drained from the live SKOOP positions");
        return (usdcOut, wethOut);
    }

    /// Deploy the relaunched SKOOP through the beta factory, with floors set low enough
    /// that the recovered capital is what is actually tested rather than the floor.
    function _deployMigratedSuite() internal returns (Suite memory s) {
        (uint256 usdcCapital, uint256 ethCapital) = _migrationCapital();
        require(usdcCapital > 0 && ethCapital > 0, "no capital to migrate");

        s.factory = _newFactory(1, 1);
        s.wdc     = WindDownController(s.factory.windDownController());
        s.usdcFeeTier = 3000;
        s.ethFeeTier  = 3000;

        _fund(OWNER, usdcCapital, ethCapital);
        vm.prank(OWNER);
        IERC20(USDC).approve(address(s.factory), usdcCapital);

        vm.recordLogs();
        s.factory.deploy{value: ethCapital}(_params("KOKOS SKOOPS", "SKOOP", usdcCapital, ethCapital));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256(
                "MerchantDeployed(address,address,address,address,address,address,address,address,bytes32,uint256)"
            )) {
                s.token = address(uint160(uint256(logs[i].topics[1])));
                (,, s.escrow, s.vesting, s.treasury, s.locker,,) = abi.decode(
                    logs[i].data, (address,address,address,address,address,address,bytes32,uint256)
                );
            }
        }
        require(s.token != address(0), "MerchantDeployed not emitted");
    }

    function _newFactory(uint256 usdcFloor, uint256 ethFloor) internal returns (TokenFactoryBeta f) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        WindDownController w = new WindDownController(MULTISIG, predicted);
        f = new TokenFactoryBeta(
            MULTISIG, address(this), address(w), POSITION_MANAGER, USDC, WETH,
            ETH_USD_FEED, FEE_RECIP, address(suiteDeployer), address(lockerDeployer),
            usdcFloor, ethFloor
        );
        require(address(f) == predicted, "factory did not land where predicted");
    }

    function _params(string memory name, string memory symbol, uint256 usdcAmt, uint256 ethAmt)
        internal pure returns (TokenFactory.DeployParams memory)
    {
        return TokenFactory.DeployParams({
            name:           name,
            symbol:         symbol,
            ipfsHash:       keccak256("kokos-migration-metadata"),
            ownerWallet:    OWNER,
            teamWallet:     TEAM,
            operator:       OPERATOR,
            usdcFeeTier:    3000,
            ethFeeTier:     3000,
            usdcPairAmount: usdcAmt,
            ethPairAmount:  ethAmt,
            perTxFloor:     1e6,
            perTxMax:       20_000 * 1e6
        });
    }

    function _fund(address who, uint256 usdcAmt, uint256 ethAmt) internal {
        deal(USDC, who, IERC20(USDC).balanceOf(who) + usdcAmt);
        vm.deal(address(this), address(this).balance + ethAmt);
    }

    /// A real trade through the live SwapRouter, so collectFees() has something to collect.
    function _swapUsdcForMerchantToken(Suite memory s, uint256 amountIn) internal {
        deal(USDC, TRADER, amountIn);
        vm.startPrank(TRADER);
        IERC20(USDC).approve(SWAP_ROUTER, amountIn);
        ISwapRouter(SWAP_ROUTER).exactInputSingle(ISwapRouter.ExactInputSingleParams({
            tokenIn:           USDC,
            tokenOut:          s.token,
            fee:               s.usdcFeeTier,
            recipient:         TRADER,
            amountIn:          amountIn,
            amountOutMinimum:  0,
            sqrtPriceLimitX96: 0
        }));
        vm.stopPrank();
    }

    // ── live SKOOP position handling ─────────────────────────────────────────

    function _isSkoopPosition(uint256 tokenId) internal view returns (bool) {
        (,, address t0, address t1,,,,,,,,) = INonfungiblePositionManager(POSITION_MANAGER).positions(tokenId);
        return t0 == SKOOP_V1 || t1 == SKOOP_V1;
    }

    function _skoopPositionCount(address owner) internal view returns (uint256 n) {
        IERC721Enumerable pm = IERC721Enumerable(POSITION_MANAGER);
        uint256 held = pm.balanceOf(owner);
        for (uint256 i = 0; i < held; i++) {
            if (_isSkoopPosition(pm.tokenOfOwnerByIndex(owner, i))) n++;
        }
    }

    function _skoopLiquidityRemaining(address owner) internal view returns (uint256 total) {
        IERC721Enumerable pm = IERC721Enumerable(POSITION_MANAGER);
        uint256 held = pm.balanceOf(owner);
        for (uint256 i = 0; i < held; i++) {
            uint256 id = pm.tokenOfOwnerByIndex(owner, i);
            if (!_isSkoopPosition(id)) continue;
            (,,,,,,, uint128 liq,,,,) = INonfungiblePositionManager(POSITION_MANAGER).positions(id);
            total += liq;
        }
    }

    /// Pull 100% of every SKOOP position the owner holds, exactly as the migration would:
    /// decreaseLiquidity to zero, then collect principal and accrued fees together.
    function _drainSkoopPositions(address owner)
        internal
        returns (uint256 usdcOut, uint256 wethOut, uint256 skoopOut)
    {
        IERC721Enumerable pmE = IERC721Enumerable(POSITION_MANAGER);
        INonfungiblePositionManager pm = INonfungiblePositionManager(POSITION_MANAGER);

        uint256 held = pmE.balanceOf(owner);
        uint256[] memory ids = new uint256[](held);
        uint256 n;
        for (uint256 i = 0; i < held; i++) {
            uint256 id = pmE.tokenOfOwnerByIndex(owner, i);
            if (_isSkoopPosition(id)) ids[n++] = id;
        }

        for (uint256 i = 0; i < n; i++) {
            uint256 id = ids[i];
            (,, address t0, address t1,,,, uint128 liq,,,,) = pm.positions(id);

            vm.startPrank(owner);
            if (liq > 0) {
                pm.decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId:    id,
                    liquidity:  liq,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline:   block.timestamp
                }));
            }
            (uint256 a0, uint256 a1) = pm.collect(INonfungiblePositionManager.CollectParams({
                tokenId:    id,
                recipient:  owner,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            }));
            vm.stopPrank();

            if (t0 == USDC)      usdcOut  += a0;
            else if (t0 == WETH) wethOut  += a0;
            else if (t0 == SKOOP_V1) skoopOut += a0;

            if (t1 == USDC)      usdcOut  += a1;
            else if (t1 == WETH) wethOut  += a1;
            else if (t1 == SKOOP_V1) skoopOut += a1;
        }
    }

    function _ethUsdPrice() internal view returns (uint256) {
        (, int256 answer,,,) = IEthUsdOracle(ETH_USD_FEED).latestRoundData();
        require(answer > 0, "bad oracle answer");
        uint8 dec = IEthUsdOracle(ETH_USD_FEED).decimals();
        uint256 price = uint256(answer);
        if (dec < 8)      price = price * (10 ** (8 - dec));
        else if (dec > 8) price = price / (10 ** (dec - 8));
        return price;
    }

    receive() external payable {}
}

interface IERC721Enumerable {
    function balanceOf(address owner) external view returns (uint256);
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
}
