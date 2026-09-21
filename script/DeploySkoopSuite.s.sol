// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../contracts/RewardEscrow.sol";
import "../contracts/VestingWallet.sol";
import "../contracts/TreasuryTimelock.sol";
import "../contracts/pilot/LPLockerPilot.sol";

/// @title DeploySkoopSuite — step 3 of docs/skoop-launch-plan.md, SKOOP only
///
/// @notice Hand-assembles the four suite contracts around a token that ALREADY EXISTS.
///         It does not mint, does not seed pools, does not register, and cannot: admission
///         is `WindDownController.registerManual`, called by the registrar at step 11 after
///         `VerifyManualSuite` has passed. Nothing here is on the network.
///
/// @dev **Why a script and not the factory.** SKOOP is admitted by review, not by
///      construction. The factory deployed at step 2 is for FUTURE merchants and is
///      untouched by this; see docs/skoop-launch-plan.md, "Where SKOOP differs".
///
///      **Why the activator is the deployer.** `initializeLP` and `activate()` are
///      `onlyActivator`. In the factory path the factory is the activator and calls both
///      inside one transaction. By hand there is no factory, so the deployer hot wallet
///      takes that role and calls them directly. This is the whole mechanism that makes
///      manual assembly possible.
///
///      **LPLockerPilot, not Beta.** SKOOP's evacuation hatch must not expire on a
///      30-day timer while PunchCard is still testing its own machine. Merchants get
///      LPLockerBeta; only this deployment gets the pilot. See contracts/pilot/LPLockerPilot.sol.
contract DeploySkoopSuite is Script {

    // Allocation targets. Reported at registration, not enforced — the funding is by hand.
    uint256 constant REWARDS_ALLOC  = 45_000_000 * 1e6;
    uint256 constant TEAM_ALLOC     = 15_000_000 * 1e6;
    uint256 constant TREASURY_ALLOC = 10_000_000 * 1e6;

    // SKOOP's deliberate differences from the merchant standard.
    uint256 constant CLIFF_DURATION   = 30 days;   // same as merchants
    uint256 constant VEST_DURATION    = 730 days;  // same as merchants
    uint256 constant TIMELOCK_SKOOP   = 7 days;    // merchants get 90 — see the launch plan

    function run() external {
        address token     = vm.envAddress("PC_TOKEN");
        address wdc       = vm.envAddress("PC_WIND_DOWN_CONTROLLER");
        address owner     = vm.envAddress("PC_OWNER_WALLET");
        address team      = vm.envAddress("PC_TEAM_WALLET");
        address operator  = vm.envAddress("PC_OPERATOR");
        address posMgr    = vm.envAddress("PC_POSITION_MANAGER");
        address usdc      = vm.envAddress("PC_USDC");
        address weth      = vm.envAddress("PC_WETH");
        address feeRecip  = vm.envAddress("PC_FEE_RECIPIENT");
        uint256 perTxFloor = vm.envUint("PC_PER_TX_FLOOR");
        uint256 perTxMax   = vm.envUint("PC_PER_TX_MAX");

        // The activator. Not a parameter: doing this by hand means the caller must be able
        // to call initializeLP and activate(), and nothing else can.
        address activator = msg.sender;

        require(token.code.length  > 0, "token has no code");
        require(wdc.code.length    > 0, "controller has no code - deploy the network first (step 2)");
        require(posMgr.code.length > 0, "position manager has no code");

        console2.log("=== CONSTRUCTOR ARGUMENTS ===");
        console2.log("token             ", token);
        console2.log("windDownController", wdc);
        console2.log("ownerWallet       ", owner);
        console2.log("teamWallet        ", team);
        console2.log("operator          ", operator);
        console2.log("positionManager   ", posMgr);
        console2.log("usdc              ", usdc);
        console2.log("weth              ", weth);
        console2.log("feeRecipient      ", feeRecip);
        console2.log("activator         ", activator);
        console2.log("rewardsAllocation ", REWARDS_ALLOC);
        console2.log("perTxFloor        ", perTxFloor);
        console2.log("perTxMax          ", perTxMax);
        console2.log("cliffDuration  (s)", CLIFF_DURATION);
        console2.log("vestDuration   (s)", VEST_DURATION);
        console2.log("timelock       (s)", TIMELOCK_SKOOP);

        vm.startBroadcast();

        RewardEscrow escrow = new RewardEscrow(
            token, operator, owner, wdc, REWARDS_ALLOC, perTxFloor, perTxMax, activator
        );
        VestingWallet vesting = new VestingWallet(
            token, team, wdc, CLIFF_DURATION, VEST_DURATION, activator
        );
        TreasuryTimelock treasury = new TreasuryTimelock(
            token, owner, wdc, TIMELOCK_SKOOP, activator
        );
        LPLockerPilot locker = new LPLockerPilot(
            token, owner, wdc, posMgr, activator, usdc, weth, feeRecip
        );

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== DEPLOYED ===");
        console2.log("rewardEscrow    ", address(escrow));
        console2.log("vestingWallet   ", address(vesting));
        console2.log("treasuryTimelock", address(treasury));
        console2.log("lpLockerPilot   ", address(locker));
        console2.log("");
        // Lineage discriminators. Both answering means pilot; evacuationOpen() alone means
        // beta; neither means production. See LPLockerPilot's note on the marker constants.
        console2.log("HAS_UNLIMITED_LP_RECOVERY", locker.HAS_UNLIMITED_LP_RECOVERY());
        console2.log("evacuationOpen           ", locker.evacuationOpen());
        console2.log("evacuationDeadline       ", locker.evacuationDeadline());
        console2.log("  (0 = not activated yet; the pilot hatch never expires regardless)");
        console2.log("");
        console2.log("NOT funded. NOT activated. NOT registered. Nothing here is a merchant.");
        console2.log("Next: fund each contract, then seed pools, then initializeLP, then activate.");
    }
}
