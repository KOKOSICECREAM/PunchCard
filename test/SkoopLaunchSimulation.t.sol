// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/WindDownController.sol";
import "../contracts/PunchCardRouter.sol";
import "../contracts/deployers/SuiteDeployer.sol";
import "../contracts/beta/StagedTokenFactoryBeta.sol";
import "../contracts/beta/LockerDeployerBeta.sol";
import "../contracts/RewardEscrow.sol";
import "../contracts/VestingWallet.sol";
import "../contracts/TreasuryTimelock.sol";
import "../contracts/pilot/LPLockerPilot.sol";

interface ISkoopMeta {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function totalSupply() external view returns (uint256);
}

/// @title Steps 2 and 3 of the SKOOP launch, run end to end against live Base
///
/// @notice Simulates the network deploy and the hand-assembled suite in one forked session,
///         against the REAL token at 0xBa147713…, and then proves the property the whole
///         manual path depends on:
///
///             everything up to registration is reversible, and nothing before it is live.
///
/// @dev Run with:  forge test --match-path test/SkoopLaunchSimulation.t.sol -vv --fork-url <base>
///
///      This is a rehearsal, not a deployment. It broadcasts nothing. Addresses printed here
///      come from the fork's nonces and will differ on the real run.
contract SkoopLaunchSimulationTest is Test {

    address constant SKOOP     = 0xBa147713adF122A8Fc224e52Cb431D7919831939;
    address constant OWNER     = 0x5426E59b783cd3b5083Ccc8cB571AA36e9f4a3be;
    address constant POS_MGR   = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address constant SWAP_RTR  = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant USDC      = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH      = 0x4200000000000000000000000000000000000006;
    address constant ETH_FEED  = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    // Placeholders. Substitute real values before the real run — these change every
    // resulting address, because addresses come from the deployer's nonce.
    address constant MULTISIG  = address(0x1111);
    address constant DEPLOYER  = address(0x2222);
    address constant FEE_RECIP = address(0x3333);
    address constant TEAM      = address(0x4444);
    address constant OPERATOR  = address(0x5555);

    uint256 constant MIN_USDC_SEED = 200_000_000_000; // $2,000 at 8dp
    uint256 constant MIN_ETH_SEED  = 100_000_000_000; // $1,000 at 8dp
    uint256 constant ROUTER_FEE_BPS = 30;

    uint256 constant REWARDS_ALLOC  = 45_000_000 * 1e6;
    uint256 constant PER_TX_FLOOR   = 1e6;
    uint256 constant PER_TX_MAX     = 20_000 * 1e6;

    WindDownController wdc;
    PunchCardRouter    router;
    RewardEscrow       escrow;
    VestingWallet      vesting;
    TreasuryTimelock   treasury;
    LPLockerPilot      locker;

    function test_simulateStepsTwoAndThree() public {
        // The token must already exist. This is the one thing the simulation does not create.
        assertGt(SKOOP.code.length, 0, "SKOOP has no code - are you forked to Base?");
        console2.log("== TOKEN (already deployed, untouched) ==");
        console2.log("  address    ", SKOOP);
        console2.log("  name       ", ISkoopMeta(SKOOP).name());
        console2.log("  symbol     ", ISkoopMeta(SKOOP).symbol());
        console2.log("  totalSupply", ISkoopMeta(SKOOP).totalSupply());

        // ── STEP 2: the network ───────────────────────────────────────────────
        SuiteDeployer      sd = new SuiteDeployer();
        LockerDeployerBeta ld = new LockerDeployerBeta();

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        wdc = new WindDownController(MULTISIG, predicted);
        StagedTokenFactoryBeta factory = new StagedTokenFactoryBeta(
            MULTISIG, DEPLOYER, address(wdc), POS_MGR, USDC, WETH,
            ETH_FEED, FEE_RECIP, address(sd), address(ld), MIN_USDC_SEED, MIN_ETH_SEED
        );
        assertEq(address(factory), predicted, "factory address mismatch");

        router = new PunchCardRouter(
            MULTISIG, address(wdc), SWAP_RTR, USDC, WETH, ROUTER_FEE_BPS, FEE_RECIP
        );

        console2.log("");
        console2.log("== STEP 2: NETWORK ==");
        console2.log("  suiteDeployer         ", address(sd));
        console2.log("  lockerDeployerBeta    ", address(ld));
        console2.log("  windDownController    ", address(wdc));
        console2.log("  stagedTokenFactoryBeta", address(factory));
        console2.log("  punchCardRouter       ", address(router));

        // ── STEP 3: the suite, hand-assembled ─────────────────────────────────
        // The activator is this contract, standing in for the deployer hot wallet. In the
        // factory path the factory holds that role; by hand, the caller must, or
        // initializeLP and activate() can never be called.
        address activator = address(this);

        escrow = new RewardEscrow(
            SKOOP, OPERATOR, OWNER, address(wdc), REWARDS_ALLOC, PER_TX_FLOOR, PER_TX_MAX, activator
        );
        vesting  = new VestingWallet(SKOOP, TEAM, address(wdc), 30 days, 730 days, activator);
        treasury = new TreasuryTimelock(SKOOP, OWNER, address(wdc), 7 days, activator);
        locker   = new LPLockerPilot(
            SKOOP, OWNER, address(wdc), POS_MGR, activator, USDC, WETH, FEE_RECIP
        );

        console2.log("");
        console2.log("== STEP 3: SKOOP SUITE ==");
        console2.log("  rewardEscrow    ", address(escrow));
        console2.log("  vestingWallet   ", address(vesting));
        console2.log("  treasuryTimelock", address(treasury));
        console2.log("  lpLockerPilot   ", address(locker));

        // ── the lineage is the pilot's, and the hatch is open ─────────────────
        assertTrue(locker.HAS_UNLIMITED_LP_RECOVERY(), "must be the pilot lineage");
        assertTrue(locker.evacuationOpen(),            "hatch must be open");
        assertEq(locker.evacuationDeadline(), 0,       "no deadline while unactivated");

        // ── NOT LIVE: this is the whole point of stopping before step 11 ──────
        assertFalse(wdc.isRegistered(SKOOP), "SKOOP must NOT be registered yet");

        vm.expectRevert("Token not on network");
        router.getPoolFeeTiers(SKOOP);

        assertFalse(escrow.isActivated(),   "escrow must be inert");
        assertFalse(vesting.isActivated(),  "vesting must be inert");
        assertFalse(treasury.isActivated(), "treasury must be inert");
        assertEq(escrow.emitted(),      0, "no emission before activation");
        assertEq(vesting.totalVested(), 0, "no vesting before activation");

        console2.log("");
        console2.log("== STATE ==");
        console2.log("  registered on the network : false");
        console2.log("  router serves it          : false (reverts 'Token not on network')");
        console2.log("  clocks running            : false (nothing activated)");
        console2.log("  funded                    : false");
        console2.log("  evacuation hatch          : OPEN, no deadline");
    }

    /// Reversibility, proven rather than asserted in prose: a suite contract deployed with
    /// the wrong parameter is simply abandoned. Nothing points at it, so a replacement is a
    /// redeploy, not a migration. This is what makes step 11 the only irreversible step.
    function test_aWrongSuiteContractIsJustAbandoned() public {
        wdc = new WindDownController(MULTISIG, address(this));

        // Deployed with the wrong team wallet.
        VestingWallet wrong = new VestingWallet(SKOOP, address(0xBAD), address(wdc), 30 days, 730 days, address(this));
        // Nothing references it, nothing registered it, it holds nothing.
        assertFalse(wdc.isRegistered(SKOOP), "a deployed suite contract is not registration");

        // Deploy the right one. The wrong one is inert forever and costs only its gas.
        VestingWallet right = new VestingWallet(SKOOP, TEAM, address(wdc), 30 days, 730 days, address(this));
        assertTrue(address(wrong) != address(right));
        assertFalse(right.isActivated(), "and the replacement is still inert until activated");
    }
}
