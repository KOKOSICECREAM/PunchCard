// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../script/DeployNetworkStaged.s.sol";
import "../script/StageMerchant.s.sol";
import "../contracts/pilot/StagedTokenFactoryPilot.sol";
import "../contracts/pilot/LockerDeployerPilot.sol";
import "../contracts/pilot/LPLockerPilot.sol";
import "../contracts/RewardEscrow.sol";
import "../contracts/VestingWallet.sol";
import "../contracts/TreasuryTimelock.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title The whole staged lifecycle, driven through the real scripts
///
/// @notice A pSKOOP-shaped rehearsal on a Base fork: fresh network, fresh token symbol,
///         fresh wallets, tiny seed. Nothing here touches KOKOS's live SKOOP, its LP, or
///         the dead micro-rehearsal controller.
///
///         It drives `DeployNetworkStaged` and `StageMerchant` rather than calling the
///         factory directly, because the thing that has never been exercised is the
///         OPERATOR'S path — four separate invocations with environment plumbing between
///         them — not the factory's internals, which `StagedDeploy.t.sol` already covers.
///
/// @dev One test function for the lifecycle, on purpose. `vm.setEnv` writes the process
///      environment and forge runs tests concurrently without rolling it back, so a
///      variable one test sets is visible to every test racing beside it. Split up, this
///      file failed with errors belonging to its siblings. Inside one function execution is
///      sequential and the environment is whatever the previous line set.
contract StagedNetworkRehearsalTest is Test {
    address constant POSITION_MANAGER = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address constant SWAP_ROUTER      = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant USDC             = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH             = 0x4200000000000000000000000000000000000006;
    address constant ETH_USD_FEED     = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    /// @dev The dead controller from the rehearsal that found the gas ceiling. Nothing here
    ///      may register into it, ever — registration is permanent.
    address constant DEAD_MICRO_CONTROLLER = 0x54BeC817f99f1a477944e84688bCeBEAF92175E7;
    address constant LIVE_SKOOP            = 0xfd3ce21c5Acd8BbbE576d0E2336C210C3cEBeb92;

    // Fresh wallets. None of these is a KOKOS address.
    address constant MULTISIG = address(0x9001);
    address constant DEPLOYER = address(0x9002);
    address constant FEERECIP = address(0x9003);
    address constant OWNER    = address(0x9004);
    address constant TEAM     = address(0x9005);
    address constant OPERATOR = address(0x9006);
    address constant CUSTOMER = address(0x9007);
    address constant TRADER   = address(0x9008);

    uint256 constant USDC_SEED = 5 * 1e6;        // $5
    uint256 constant ETH_SEED  = 0.0025 ether;   // ~$6

    bool forked;

    function setUp() public {
        if (block.chainid == 8453) forked = true;
    }

    function _env(address factory) internal {
        vm.setEnv("PC_MULTISIG",            vm.toString(MULTISIG));
        vm.setEnv("PC_DEPLOYER",            vm.toString(DEPLOYER));
        vm.setEnv("PC_FEE_RECIPIENT",       vm.toString(FEERECIP));
        vm.setEnv("PC_POSITION_MANAGER",    vm.toString(POSITION_MANAGER));
        vm.setEnv("PC_SWAP_ROUTER",         vm.toString(SWAP_ROUTER));
        vm.setEnv("PC_USDC",                vm.toString(USDC));
        vm.setEnv("PC_WETH",                vm.toString(WETH));
        vm.setEnv("PC_ETH_USD_FEED",        vm.toString(ETH_USD_FEED));
        vm.setEnv("PC_MIN_USDC_SEED_USD",   "500000000");    // $5 floor, micro
        vm.setEnv("PC_MIN_ETH_SEED_USD",    "500000000");    // $5 floor, micro
        vm.setEnv("PC_ROUTER_FEE_BPS",      "30");
        vm.setEnv("PC_CREATE_NEW_NETWORK",  "true");
        vm.setEnv("PC_FACTORY",             vm.toString(factory));
        vm.setEnv("MERCHANT_NAME",          "PunchCard Pilot Rehearsal");
        vm.setEnv("MERCHANT_SYMBOL",        "pRHRSL");
        vm.setEnv("MERCHANT_IPFS",          "ipfs://rehearsal");
        vm.setEnv("MERCHANT_OWNER",         vm.toString(OWNER));
        vm.setEnv("MERCHANT_TEAM",          vm.toString(TEAM));
        vm.setEnv("MERCHANT_OPERATOR",      vm.toString(OPERATOR));
        vm.setEnv("MERCHANT_PER_TX_FLOOR",  "1000000");
        vm.setEnv("MERCHANT_PER_TX_MAX",    "20000000000");
        vm.setEnv("MERCHANT_USDC_SEED",     vm.toString(USDC_SEED));
        vm.setEnv("MERCHANT_ETH_SEED",      vm.toString(ETH_SEED));
        vm.setEnv("MERCHANT_USDC_FEE_TIER", "3000");
        vm.setEnv("MERCHANT_ETH_FEE_TIER",  "3000");
    }

    // ═════════════════════════════════════════════════════════════════════════

    function test_theWholeStagedLifecycle() public {
        if (!forked) { emit log("SKIPPED - needs --fork-url https://mainnet.base.org"); vm.skip(true); }

        // ── 1. the network ───────────────────────────────────────────────────
        // Pilot lineage: this rehearses pSKOOP, whose hatch never self-closes.
        SuiteDeployer       sd = new SuiteDeployer();
        LockerDeployerPilot ld = new LockerDeployerPilot();

        vm.startPrank(DEPLOYER);
        address predicted = vm.computeCreateAddress(DEPLOYER, vm.getNonce(DEPLOYER) + 1);
        WindDownController wdc = new WindDownController(MULTISIG, predicted);
        StagedTokenFactoryPilot f = new StagedTokenFactoryPilot(
            MULTISIG, DEPLOYER, address(wdc), POSITION_MANAGER, USDC, WETH,
            ETH_USD_FEED, FEERECIP, address(sd), address(ld), 5 * 1e8, 5 * 1e8
        );
        PunchCardRouter router = new PunchCardRouter(
            MULTISIG, address(wdc), SWAP_ROUTER, USDC, WETH, 30, FEERECIP
        );
        vm.stopPrank();

        assertEq(address(f), predicted, "factory landed where predicted");
        assertTrue(address(wdc) != DEAD_MICRO_CONTROLLER, "must not be the dead micro controller");
        assertTrue(f.HAS_LP_RECOVERY() && f.HAS_UNLIMITED_LP_RECOVERY(), "pilot lineage markers");

        _env(address(f));
        StageMerchant sm = new StageMerchant();

        // The script contract is what actually calls the factory in this harness, so it is
        // the address that must be an approved deployer. A real run broadcasts from a hot
        // wallet instead — this is the one place the rehearsal differs from the operator's
        // path, and it exercises the backup-deployer mechanism rather than bypassing it.
        // `vm.startBroadcast()` inside a script run from a test does not execute as the
        // script contract — forge substitutes its default sender. Rather than encode which
        // address that is, approve every candidate: the script, the test's tx.origin, and
        // forge's DEFAULT_SENDER. In a real run exactly one hot wallet is approved.
        vm.startPrank(MULTISIG);
        f.setDeployer(address(sm), true);
        f.setDeployer(tx.origin, true);
        f.setDeployer(0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38, true);
        f.setDeployer(address(this), true);
        vm.stopPrank();
        vm.deal(0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38, ETH_SEED);
        vm.deal(tx.origin, ETH_SEED);
        vm.deal(address(this), ETH_SEED);
        vm.deal(address(sm), ETH_SEED);
        vm.recordLogs();

        // ── 2. stage 1 ───────────────────────────────────────────────────────
        vm.setEnv("PC_STAGE", "1");
        uint256 g = gasleft();
        sm.run();
        uint256 gStage1 = g - gasleft();

        address token = _findStagedToken(f);
        assertTrue(token != address(0), "token staged");
        assertTrue(token != LIVE_SKOOP, "not the live SKOOP");
        assertEq(IERC20Meta2(token).symbol(), "pRHRSL", "fresh symbol, not SKOOP");

        (StagedTokenFactory.Stage st,,,, address escrow, address vesting, address treasury, address locker,,,,,,,) = f.suites(token);
        assertTrue(st == StagedTokenFactory.Stage.Staged, "status Staged");
        assertFalse(wdc.isRegistered(token), "not registered after stage 1");
        assertFalse(RewardEscrow(escrow).isActivated(),  "escrow clock not running");
        assertFalse(VestingWallet(vesting).isActivated(),"vesting clock not running");
        assertEq(IERC20(token).balanceOf(locker), 0,     "locker empty");

        // The handoff file stage 1 wrote carries the whole suite, not just the token.
        {
            string memory json = vm.readFile(string.concat("deploy/staged/", vm.toString(block.chainid), "-latest.json"));
            assertEq(vm.parseJsonAddress(json, ".token"),   token,   "handoff records the token");
            assertEq(vm.parseJsonAddress(json, ".factory"), address(f), "and the factory it belongs to");
            assertEq(vm.parseJsonAddress(json, ".escrow"),  escrow,  "and the escrow");
            assertEq(vm.parseJsonAddress(json, ".locker"),  locker,  "and the locker");
        }

        // The router must refuse to trade it, and must SAY SO — both on the swap path and
        // on the view the interface calls first when quoting. getPoolFeeTiers used to read
        // a zero locker and revert with no data at all, which surfaced in the dapp's quote
        // flow as an unexplained failure for a token that was merely not live yet.
        vm.expectRevert("Token not on network");
        router.getPoolFeeTiers(token);

        deal(USDC, TRADER, 1e6);
        vm.startPrank(TRADER);
        IERC20(USDC).approve(address(router), 1e6);
        vm.expectRevert("Token not on network");
        router.swap(PunchCardRouter.SwapParams({
            tokenIn: USDC, tokenOut: token, amountIn: 1e6,
            amountOutMinimumHop1: 0, amountOutMinimumHop2: 0,
            midToken: address(0), recipient: TRADER, deadline: block.timestamp
        }));
        vm.stopPrank();

        // ── 2b. the whole supply is with the MERCHANT, not in the suite ──────
        // The pilot lineage mints to the owner so each contract can be funded and tested
        // one at a time, rather than the first test of an unaudited escrow happening with
        // 45M already inside it.
        assertEq(IERC20(token).balanceOf(OWNER), 100_000_000 * 1e6, "whole supply with the merchant");
        assertEq(IERC20(token).balanceOf(escrow),   0, "escrow starts empty");
        assertEq(IERC20(token).balanceOf(vesting),  0, "vesting starts empty");
        assertEq(IERC20(token).balanceOf(treasury), 0, "treasury starts empty");

        // Activation must refuse an unfunded suite. This is what keeps hand-funding from
        // weakening what registration means.
        //
        // Called directly rather than through the script: a reverting script leaves its
        // vm.startBroadcast open, and every later vm.prank in this test then fails with
        // "cannot prank for a broadcasted transaction" — an error about the harness that
        // reads like an error about the contract.
        vm.expectRevert("Not funded");
        f.activateMerchant(token);

        // ── 3. the merchant funds each contract by hand, testing as they go ──
        vm.startPrank(OWNER);
        IERC20(token).transfer(escrow,   45_000_000 * 1e6);
        IERC20(token).transfer(vesting,  15_000_000 * 1e6);
        IERC20(token).transfer(treasury, 10_000_000 * 1e6);
        // The LP share is approved rather than sent: stage 2 pulls exactly what it needs.
        IERC20(token).approve(address(f), 30_000_000 * 1e6);
        vm.stopPrank();

        deal(USDC, OWNER, USDC_SEED);
        vm.prank(OWNER);
        IERC20(USDC).approve(address(f), USDC_SEED);

        // ── 4. stage 2 ───────────────────────────────────────────────────────
        // Deliberately NOT setting PC_TOKEN: stage 2 must find the token in the file
        // stage 1 wrote. That is the copy-paste this removes.
        vm.setEnv("PC_STAGE", "2");
        g = gasleft();
        sm.run();
        uint256 gStage2 = g - gasleft();

        // ── 5. inspection ────────────────────────────────────────────────────
        uint256 usdcId;
        uint256 ethId;
        {
            StagedTokenFactory.Stage st2;
            (st2,,,,,,,,,, usdcId, ethId,,,) = f.suites(token);
            assertTrue(st2 == StagedTokenFactory.Stage.Funded, "status Funded");
        }
        assertFalse(wdc.isRegistered(token), "STILL not registered after funding");
        assertEq(IERC20(token).totalSupply(),      100_000_000 * 1e6, "supply");
        assertEq(IERC20(token).balanceOf(escrow),   45_000_000 * 1e6, "45M rewards");
        assertEq(IERC20(token).balanceOf(vesting),  15_000_000 * 1e6, "15M team");
        assertEq(IERC20(token).balanceOf(treasury), 10_000_000 * 1e6, "10M treasury");
        assertEq(IERC20(token).balanceOf(OWNER),                   0, "no merchant tokens leaked to owner");
        assertEq(IERC20(token).balanceOf(locker),                  0, "LP NOT in the locker before activation");
        assertEq(IERC721Rehearsal(POSITION_MANAGER).ownerOf(usdcId), address(f), "USDC position held by factory");
        assertEq(IERC721Rehearsal(POSITION_MANAGER).ownerOf(ethId),  address(f), "ETH position held by factory");

        emit log_named_address("token   ", token);
        emit log_named_address("escrow  ", escrow);
        emit log_named_address("vesting ", vesting);
        emit log_named_address("treasury", treasury);
        emit log_named_address("locker  ", locker);
        emit log_named_uint("usdc position", usdcId);
        emit log_named_uint("eth position ", ethId);

        // ── 6. stage 3 ───────────────────────────────────────────────────────
        vm.setEnv("PC_STAGE", "3");
        g = gasleft();
        sm.run();
        uint256 gStage3 = g - gasleft();
        uint256 liveAt = block.timestamp;

        {
            (StagedTokenFactory.Stage st3,,,,,,,,,,,,,,) = f.suites(token);
            assertTrue(st3 == StagedTokenFactory.Stage.Active, "status Active");
        }
        assertTrue(wdc.isRegistered(token), "registered");
        (uint24 uFee, uint24 eFee) = router.getPoolFeeTiers(token);
        assertEq(uFee, 3000, "router reads the USDC tier");
        assertEq(eFee, 3000, "router reads the ETH tier");
        assertEq(IERC721Rehearsal(POSITION_MANAGER).ownerOf(usdcId), locker, "LP moved to locker");
        assertGe(IERC20(token).balanceOf(locker), 27_000_000 * 1e6, "27M reserve in locker");
        assertEq(IERC20(token).balanceOf(address(f)), 0, "factory drained");

        // clocks start here, all at one instant
        assertEq(RewardEscrow(escrow).emissionStart(), liveAt, "emission starts at activation");
        assertEq(VestingWallet(vesting).cliffTime(), liveAt + 30 days, "full cliff ahead");
        assertEq(LPLockerPilot(locker).evacuationExpiresAt(), type(uint256).max, "pilot hatch never expires");
        assertTrue(LPLockerPilot(locker).evacuationOpen(), "and is open");

        emit log_named_uint("stage 1 gas", gStage1);
        emit log_named_uint("stage 2 gas", gStage2);
        emit log_named_uint("stage 3 gas", gStage3);

        // ── 7. behaviour ─────────────────────────────────────────────────────
        vm.warp(liveAt + 1 days);
        vm.prank(OPERATOR);
        RewardEscrow(escrow).distributeReward(CUSTOMER, 1_000 * 1e6);
        assertEq(IERC20(token).balanceOf(CUSTOMER), 1_000 * 1e6, "reward issued");

        // a swap through the PunchCard router, which is what the fee exists for
        uint256 feeBefore = IERC20(USDC).balanceOf(FEERECIP);
        deal(USDC, TRADER, 2 * 1e6);
        vm.startPrank(TRADER);
        IERC20(USDC).approve(address(router), 2 * 1e6);
        router.swap(PunchCardRouter.SwapParams({
            tokenIn: USDC, tokenOut: token, amountIn: 2 * 1e6,
            amountOutMinimumHop1: 0, amountOutMinimumHop2: 0,
            midToken: address(0), recipient: TRADER, deadline: block.timestamp
        }));
        vm.stopPrank();
        assertGt(IERC20(token).balanceOf(TRADER), 0, "trader received merchant tokens");
        assertGt(IERC20(USDC).balanceOf(FEERECIP), feeBefore, "router fee paid in USDC");

        // LP fees: PunchCard takes the pair asset and never the merchant token
        uint256 pcTokenBefore = IERC20(token).balanceOf(FEERECIP);
        (uint256 usdcFee,, uint256 burned) = LPLockerPilot(locker).collectFees();
        assertGt(usdcFee + burned, 0, "the trade generated fees");
        assertEq(IERC20(token).balanceOf(FEERECIP), pcTokenBefore, "PunchCard never receives merchant tokens");

        emit log_named_decimal_uint("router fee, USDC", IERC20(USDC).balanceOf(FEERECIP) - feeBefore, 6);
        emit log_named_decimal_uint("LP network fee, USDC", usdcFee, 6);
        emit log("full staged lifecycle completed");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 8. abort, on its own network so no environment is shared
    // ═════════════════════════════════════════════════════════════════════════

    function test_abortBeforeActivationReturnsTheSeedAndNeverRegisters() public {
        if (!forked) { vm.skip(true); }

        SuiteDeployer       sd = new SuiteDeployer();
        LockerDeployerPilot ld = new LockerDeployerPilot();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        WindDownController wdc = new WindDownController(MULTISIG, predicted);
        StagedTokenFactoryPilot f = new StagedTokenFactoryPilot(
            MULTISIG, DEPLOYER, address(wdc), POSITION_MANAGER, USDC, WETH,
            ETH_USD_FEED, FEERECIP, address(sd), address(ld), 5 * 1e8, 5 * 1e8
        );

        vm.prank(DEPLOYER);
        address token = f.stageSuite(StagedTokenFactory.StageParams({
            name: "PunchCard Pilot Rehearsal", symbol: "pRHRSL", ipfsHash: keccak256("r"),
            ownerWallet: OWNER, teamWallet: TEAM, operator: OPERATOR,
            perTxFloor: 1e6, perTxMax: 20_000 * 1e6
        }));

        // Pilot lineage: the supply is with the merchant, so they approve the LP share.
        vm.prank(OWNER);
        IERC20(token).approve(address(f), 30_000_000 * 1e6);

        deal(USDC, OWNER, USDC_SEED);
        vm.prank(OWNER);
        IERC20(USDC).approve(address(f), USDC_SEED);
        vm.deal(DEPLOYER, ETH_SEED);
        vm.prank(DEPLOYER);
        f.fundAndMintLP{value: ETH_SEED}(StagedTokenFactory.FundParams({
            token: token, usdcFeeTier: 3000, ethFeeTier: 3000,
            usdcPairAmount: USDC_SEED, ethPairAmount: ETH_SEED
        }));

        uint256 usdcBefore = IERC20(USDC).balanceOf(OWNER);
        uint256 wethBefore = IERC20(WETH).balanceOf(OWNER);

        vm.prank(OWNER);
        f.abortStaging(token);

        uint256 usdcBack = IERC20(USDC).balanceOf(OWNER) - usdcBefore;
        uint256 wethBack = IERC20(WETH).balanceOf(OWNER) - wethBefore;

        assertGt(usdcBack, (USDC_SEED * 95) / 100, "most USDC returned");
        assertGt(wethBack, (ETH_SEED  * 95) / 100, "most ETH returned");
        assertFalse(wdc.isRegistered(token), "an aborted token is never registered");

        emit log_named_decimal_uint("USDC returned on abort", usdcBack, 6);
        emit log_named_decimal_uint("WETH returned on abort", wethBack, 18);
    }

    // ── helper ────────────────────────────────────────────────────────────────

    /// @dev The script prints the token but returns nothing, so recover it from the event
    ///      the factory emitted — which is also how an operator would, from the receipt.
    function _findStagedToken(StagedTokenFactory f) internal returns (address) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256(
                "SuiteStaged(address,address,address,address,address,address,address,address,bytes32,uint256)"
            )) return address(uint160(uint256(logs[i].topics[1])));
        }
        revert("SuiteStaged not found - call vm.recordLogs() first");
    }
}

interface IERC721Rehearsal { function ownerOf(uint256) external view returns (address); }
interface IERC20Meta2 { function symbol() external view returns (string memory); }
