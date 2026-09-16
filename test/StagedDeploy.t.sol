// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/StagedTokenFactory.sol";
import "../contracts/WindDownController.sol";
import "../contracts/RewardEscrow.sol";
import "../contracts/VestingWallet.sol";
import "../contracts/deployers/SuiteDeployer.sol";
import "../contracts/beta/LockerDeployerBeta.sol";
import "../contracts/beta/LPLockerBeta.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title The staged launch, against live Base
///
/// @notice The point of all of this is one number. `TokenFactory.deploy()` is 17,325,962
///         gas and Base refuses anything above 16,777,216, so no merchant could be
///         deployed at all. Every test here is downstream of proving the three stages fit.
contract StagedDeployTest is Test {
    address constant POSITION_MANAGER = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address constant USDC             = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH             = 0x4200000000000000000000000000000000000006;
    address constant ETH_USD_FEED     = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    uint256 constant BASE_TX_GAS_CEILING = 16_777_216;

    address constant MULTISIG = address(0xA1);
    address constant FEE_RECIP= address(0xA2);
    address constant DEPLOYER = address(0xD1);
    address constant BACKUP   = address(0xD2);
    address constant OWNER    = address(0xB1);
    address constant TEAM     = address(0xB2);
    address constant OP       = address(0xB3);

    StagedTokenFactory f;
    WindDownController wdc;
    bool forked;

    uint256 constant USDC_SEED = 2_000 * 1e6;
    uint256 constant ETH_SEED  = 0.415 ether;

    function setUp() public {
        if (block.chainid != 8453) return;
        forked = true;

        SuiteDeployer       sd = new SuiteDeployer();
        LockerDeployerBeta  ld = new LockerDeployerBeta();

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        wdc = new WindDownController(MULTISIG, predicted);
        f = new StagedTokenFactory(
            MULTISIG, DEPLOYER, address(wdc), POSITION_MANAGER, USDC, WETH,
            ETH_USD_FEED, FEE_RECIP, address(sd), address(ld), 1, 1
        );
        require(address(f) == predicted, "factory address mismatch");
    }

    function _skipUnlessForked() internal {
        if (!forked) { emit log("SKIPPED - needs --fork-url https://mainnet.base.org"); vm.skip(true); }
    }

    function _params() internal pure returns (StagedTokenFactory.StageParams memory) {
        return StagedTokenFactory.StageParams({
            name: "KOKOS SKOOPS Pilot", symbol: "pSKOOP", ipfsHash: keccak256("meta"),
            ownerWallet: OWNER, teamWallet: TEAM, operator: OP,
            perTxFloor: 1e6, perTxMax: 20_000 * 1e6
        });
    }

    function _fundOwner() internal {
        deal(USDC, OWNER, USDC_SEED);
        vm.prank(OWNER);
        IERC20(USDC).approve(address(f), USDC_SEED);
        vm.deal(DEPLOYER, ETH_SEED);
    }

    function _stage() internal returns (address token) {
        vm.prank(DEPLOYER);
        token = f.stageSuite(_params());
    }

    function _fund(address token) internal {
        vm.prank(DEPLOYER);
        f.fundAndMintLP{value: ETH_SEED}(StagedTokenFactory.FundParams({
            token: token, usdcFeeTier: 3000, ethFeeTier: 3000,
            usdcPairAmount: USDC_SEED, ethPairAmount: ETH_SEED
        }));
    }

    // ═════════════════════════════════════════════════════════════════════════
    // THE NUMBER
    // ═════════════════════════════════════════════════════════════════════════

    function test_everyStageFitsInABaseTransaction() public {
        _skipUnlessForked();
        _fundOwner();

        uint256 g = gasleft();
        vm.prank(DEPLOYER);
        address token = f.stageSuite(_params());
        uint256 gStage = g - gasleft();

        g = gasleft();
        _fund(token);
        uint256 gFund = g - gasleft();

        g = gasleft();
        vm.prank(DEPLOYER);
        f.activateMerchant(token);
        uint256 gActivate = g - gasleft();

        emit log_named_uint("stage 1  stageSuite      ", gStage);
        emit log_named_uint("stage 2  fundAndMintLP   ", gFund);
        emit log_named_uint("stage 3  activateMerchant", gActivate);
        emit log_named_uint("Base ceiling             ", BASE_TX_GAS_CEILING);
        emit log_named_uint("total across three       ", gStage + gFund + gActivate);

        assertLt(gStage,    BASE_TX_GAS_CEILING, "stageSuite must fit");
        assertLt(gFund,     BASE_TX_GAS_CEILING, "fundAndMintLP must fit");
        assertLt(gActivate, BASE_TX_GAS_CEILING, "activateMerchant must fit");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // THE LAUNCH IS THE SAME LAUNCH
    // ═════════════════════════════════════════════════════════════════════════

    function test_anActivatedMerchantIsIndistinguishableFromAnAtomicOne() public {
        _skipUnlessForked();
        _fundOwner();
        address token = _stage();
        _fund(token);
        vm.prank(DEPLOYER);
        f.activateMerchant(token);

        (, , , , address escrow, address vesting, address treasury, address locker,,,,,,,) = f.suites(token);

        assertEq(IERC20(token).totalSupply(),      100_000_000 * 1e6, "supply");
        assertEq(IERC20(token).balanceOf(escrow),   45_000_000 * 1e6, "rewards");
        assertEq(IERC20(token).balanceOf(vesting),  15_000_000 * 1e6, "team");
        assertEq(IERC20(token).balanceOf(treasury), 10_000_000 * 1e6, "treasury");
        assertGe(IERC20(token).balanceOf(locker),   27_000_000 * 1e6, "reserve");
        assertEq(IERC20(token).balanceOf(OWNER),                   0, "merchant holds none");
        assertEq(IERC20(token).balanceOf(address(f)),              0, "factory drained");
        assertEq(IERC721Min(POSITION_MANAGER).ownerOf(_usdcId(token)), locker, "USDC position with locker");
        assertTrue(wdc.isRegistered(token), "on the network");

        // Clocks all start at activation, at one instant.
        assertTrue(RewardEscrow(escrow).isActivated(),   "escrow live");
        assertTrue(VestingWallet(vesting).isActivated(), "vesting live");
        assertTrue(LPLockerBeta(locker).isActivated(),   "locker live");
        assertEq(VestingWallet(vesting).cliffTime(), block.timestamp + 30 days, "full cliff ahead");
        assertEq(LPLockerBeta(locker).evacuationDeadline(), block.timestamp + 30 days, "full hatch ahead");
        assertEq(RewardEscrow(escrow).emitted(), 0, "no emission accrued before going live");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // NOTHING IS A MERCHANT BEFORE ACTIVATION
    // ═════════════════════════════════════════════════════════════════════════

    function test_stagedAndFundedSuitesAreNotOnTheNetwork() public {
        _skipUnlessForked();
        _fundOwner();

        address token = _stage();
        assertFalse(wdc.isRegistered(token), "staged is not registered");

        _fund(token);
        assertFalse(wdc.isRegistered(token), "funded is not registered either");

        (, , , , , , , address locker,,,,,,,) = f.suites(token);
        assertEq(IERC20(token).balanceOf(locker), 0, "locker holds nothing before activation");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // REPLAY AND ORDER
    // ═════════════════════════════════════════════════════════════════════════

    function test_stagesCannotBeSkippedOrReplayed() public {
        _skipUnlessForked();
        _fundOwner();

        address token = _stage();

        vm.prank(DEPLOYER);
        vm.expectRevert("Not funded");
        f.activateMerchant(token);

        _fund(token);

        vm.prank(DEPLOYER);
        vm.expectRevert("Not staged");
        f.fundAndMintLP{value: 0}(StagedTokenFactory.FundParams({
            token: token, usdcFeeTier: 3000, ethFeeTier: 3000,
            usdcPairAmount: USDC_SEED, ethPairAmount: 0
        }));

        vm.prank(DEPLOYER);
        f.activateMerchant(token);

        vm.prank(DEPLOYER);
        vm.expectRevert("Not funded");
        f.activateMerchant(token);
    }

    function test_onlyApprovedDeployersMayAdvanceAStaging() public {
        _skipUnlessForked();
        _fundOwner();

        vm.prank(address(0xBAD));
        vm.expectRevert("Not deployer");
        f.stageSuite(_params());

        // A backup deployer exists for a lost or compromised hot wallet.
        vm.prank(MULTISIG);
        f.setDeployer(BACKUP, true);

        vm.prank(BACKUP);
        address token = f.stageSuite(_params());
        assertTrue(token != address(0), "backup deployer can stage");

        vm.prank(MULTISIG);
        f.setDeployer(BACKUP, false);

        vm.prank(BACKUP);
        vm.expectRevert("Not deployer");
        f.stageSuite(_params());
    }

    // ═════════════════════════════════════════════════════════════════════════
    // ABORT
    // ═════════════════════════════════════════════════════════════════════════

    /// The gap staging would otherwise open: a funded suite that never activates must not
    /// strand the seed. Production LPLocker has no hatch, so this is the only way out.
    function test_abortFromFundedReturnsTheSeed() public {
        _skipUnlessForked();
        _fundOwner();
        address token = _stage();
        _fund(token);

        uint256 usdcBefore = IERC20(USDC).balanceOf(OWNER);
        uint256 wethBefore = IERC20(WETH).balanceOf(OWNER);

        vm.prank(OWNER);
        f.abortStaging(token);

        assertGt(IERC20(USDC).balanceOf(OWNER) - usdcBefore, (USDC_SEED * 95) / 100, "most USDC back");
        assertGt(IERC20(WETH).balanceOf(OWNER) - wethBefore, (ETH_SEED  * 95) / 100, "most ETH back");
        assertFalse(wdc.isRegistered(token), "an aborted token is never registered");
    }

    function test_abortIsTerminalAndTheAddressCannotBeReused() public {
        _skipUnlessForked();
        _fundOwner();
        address token = _stage();

        vm.prank(DEPLOYER);
        f.abortStaging(token);

        vm.prank(DEPLOYER);
        vm.expectRevert("Not staged");
        f.fundAndMintLP{value: 0}(StagedTokenFactory.FundParams({
            token: token, usdcFeeTier: 3000, ethFeeTier: 3000,
            usdcPairAmount: 1, ethPairAmount: 0
        }));

        vm.prank(DEPLOYER);
        vm.expectRevert("Not funded");
        f.activateMerchant(token);

        vm.prank(DEPLOYER);
        vm.expectRevert("Not abortable");
        f.abortStaging(token);
    }

    /// Either party may need out, and neither may act once the merchant is live.
    function test_bothSidesCanAbortButNobodyElseCan() public {
        _skipUnlessForked();
        _fundOwner();

        address token = _stage();
        vm.prank(address(0xBAD));
        vm.expectRevert("Not deployer or owner");
        f.abortStaging(token);

        vm.prank(OWNER);
        f.abortStaging(token);
    }

    function test_anActiveMerchantCannotBeAborted() public {
        _skipUnlessForked();
        _fundOwner();
        address token = _stage();
        _fund(token);
        vm.prank(DEPLOYER);
        f.activateMerchant(token);

        vm.prank(DEPLOYER);
        vm.expectRevert("Not abortable");
        f.abortStaging(token);

        vm.prank(OWNER);
        vm.expectRevert("Not abortable");
        f.abortStaging(token);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // THE FRONT-RUN STAGING CREATES
    // ═════════════════════════════════════════════════════════════════════════

    /// The one thing staging makes genuinely harder rather than merely explicit.
    ///
    /// The atomic factory said, twice, that the merchant token was created moments ago in
    /// the same transaction so its pool could not exist yet — which is what made
    /// sqrtPriceX96 the launch price. Split stage 1 from stage 2 and that stops being
    /// true: anyone watching the mempool can create the pool first, at any price, and the
    /// launch mint would land inside it.
    ///
    /// Checking prices at activation is too late, because by then the seed is already in
    /// the poisoned pool and the only remedy is an abort. So stage 2 creates the pool and
    /// reverts if one exists.
    function test_aPoisonedPoolStopsTheStagingInsteadOfBeingDiscoveredLater() public {
        _skipUnlessForked();
        _fundOwner();
        address token = _stage();

        // An attacker creates the USDC pool first, at a price of their choosing.
        address attacker = address(0xBEEF);
        vm.prank(attacker);
        INonfungiblePositionManager(POSITION_MANAGER).createAndInitializePoolIfNecessary(
            token < USDC ? token : USDC,
            token < USDC ? USDC : token,
            3000,
            // ~1000x off the intended launch price, the direction that matters
            token < USDC ? 79228162514264337593543950336000 : 79228162514264337593543950
        );

        vm.prank(DEPLOYER);
        vm.expectRevert("Pool already exists");
        f.fundAndMintLP{value: ETH_SEED}(StagedTokenFactory.FundParams({
            token: token, usdcFeeTier: 3000, ethFeeTier: 3000,
            usdcPairAmount: USDC_SEED, ethPairAmount: ETH_SEED
        }));

        // The suite is untouched and still abortable — no seed was moved.
        assertEq(IERC20(USDC).balanceOf(OWNER), USDC_SEED, "the merchant's USDC never left");
        vm.prank(OWNER);
        f.abortStaging(token);
    }

    /// A different fee tier is a different pool, so a poisoned 0.3% pool does not blockade
    /// the launch — it costs the attacker a pool and buys them nothing.
    function test_aPoisonedTierCanBeRoutedAround() public {
        _skipUnlessForked();
        _fundOwner();
        address token = _stage();

        vm.prank(address(0xBEEF));
        INonfungiblePositionManager(POSITION_MANAGER).createAndInitializePoolIfNecessary(
            token < USDC ? token : USDC, token < USDC ? USDC : token, 3000,
            token < USDC ? 79228162514264337593543950336000 : 79228162514264337593543950
        );

        vm.prank(DEPLOYER);
        f.fundAndMintLP{value: ETH_SEED}(StagedTokenFactory.FundParams({
            token: token, usdcFeeTier: 500, ethFeeTier: 3000,
            usdcPairAmount: USDC_SEED, ethPairAmount: ETH_SEED
        }));

        vm.prank(DEPLOYER);
        f.activateMerchant(token);
        assertTrue(wdc.isRegistered(token), "launched on a clean tier");
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function _usdcId(address token) internal view returns (uint256 id) {
        (,,,,,,,,,, id,,,,) = _suiteRaw(token);
    }

    function _suiteRaw(address token) internal view returns (
        StagedTokenFactory.Stage, address, address, address, address, address, address,
        address, uint24, uint24, uint256, uint256, uint256, uint256, bytes32
    ) {
        return f.suites(token);
    }
}
