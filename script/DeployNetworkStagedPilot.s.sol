// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../contracts/WindDownController.sol";
import "../contracts/PunchCardRouter.sol";
import "../contracts/deployers/SuiteDeployer.sol";
import "../contracts/pilot/StagedTokenFactoryPilot.sol";
import "../contracts/pilot/LockerDeployerPilot.sol";

/// @title DeployNetworkStagedPilot — the pSKOOP network, once and never again
///
/// @notice Identical choreography to `DeployNetworkStaged`, wiring the **pilot** lineage:
///         lockers whose LP recovery hatch never closes by itself. That is the whole
///         difference, and it is the reason this is a separate script rather than a flag.
///
///         The runbook used to say "substitute `StagedTokenFactoryPilot`", meaning hand-edit
///         a deploy script on launch day. Every other guarantee in this repo is structural
///         because configuration that silently changes a trust guarantee is the failure it
///         keeps producing — and an edit made under time pressure is worse than a
///         configuration flag, not better.
///
/// @dev **One merchant is meant to come through the factory this deploys: pSKOOP.**
///      Afterwards, `proposeFactory(pilot, false)` closes the path while leaving the
///      merchant it registered working. A merchant must never be launched through a pilot
///      factory — an open-ended hatch means a liquidity guarantee that can be withdrawn at
///      any time, which is not a guarantee. Merchants get the beta lineage's self-closing
///      window, or production's absence of one.
///
///          cast call $FACTORY 'HAS_LP_RECOVERY()(bool)'            -> true on beta and pilot
///          cast call $FACTORY 'HAS_UNLIMITED_LP_RECOVERY()(bool)'  -> true on pilot only
///
///      Merchants launch through `StageMerchant.s.sol` in three steps afterwards. Nothing is
///      a merchant until the third.
contract DeployNetworkStagedPilot is Script {
    function run() external {
        address multisig    = vm.envAddress("PC_MULTISIG");
        address deployerHot = vm.envAddress("PC_DEPLOYER");
        address feeRecip    = vm.envAddress("PC_FEE_RECIPIENT");
        address posMgr      = vm.envAddress("PC_POSITION_MANAGER");
        address swapRouter  = vm.envAddress("PC_SWAP_ROUTER");
        address usdc        = vm.envAddress("PC_USDC");
        address weth        = vm.envAddress("PC_WETH");
        address oracle      = vm.envAddress("PC_ETH_USD_FEED");
        uint256 minUsdc     = vm.envUint("PC_MIN_USDC_SEED_USD");
        uint256 minEth      = vm.envUint("PC_MIN_ETH_SEED_USD");
        uint256 feeRate     = vm.envUint("PC_ROUTER_FEE_BPS");

        // An open-ended hatch is PunchCard testing its own token with its own money. It is
        // not a thing to deploy by reaching for the wrong script, so it takes its own
        // acknowledgement on top of the network one.
        require(
            vm.envOr("PC_PILOT_LINEAGE", false),
            "This deploys the PILOT lineage: every merchant under it has an LP recovery hatch that NEVER closes by itself. Correct for pSKOOP and wrong for a merchant. Set PC_PILOT_LINEAGE=true to confirm, or use DeployNetworkStaged.s.sol."
        );

        // A WindDownController IS the network. A second one forks it: the router binds to
        // one controller and only recognises merchants in that registry, so merchants under
        // a second controller could never swap against the first's. Unfixable afterwards,
        // and invisible until a cross-merchant swap fails.
        require(
            vm.envOr("PC_CREATE_NEW_NETWORK", false),
            "This deploys a NEW WindDownController and therefore a NEW network. To add a factory to an existing network, authorise it via the multisig instead. Set PC_CREATE_NEW_NETWORK=true only when genuinely starting from nothing."
        );

        require(posMgr.code.length     > 0, "position manager has no code");
        require(swapRouter.code.length > 0, "swap router has no code");
        require(usdc.code.length       > 0, "USDC has no code");
        require(weth.code.length       > 0, "WETH has no code");
        require(oracle.code.length     > 0, "oracle has no code");

        vm.startBroadcast();

        SuiteDeployer       suite  = new SuiteDeployer();
        LockerDeployerPilot locker = new LockerDeployerPilot();

        address predictedFactory =
            vm.computeCreateAddress(msg.sender, vm.getNonce(msg.sender) + 1);
        WindDownController wdc = new WindDownController(multisig, predictedFactory);

        StagedTokenFactoryPilot factory = new StagedTokenFactoryPilot(
            multisig, deployerHot, address(wdc), posMgr, usdc, weth,
            oracle, feeRecip, address(suite), address(locker), minUsdc, minEth
        );
        require(address(factory) == predictedFactory, "factory address mismatch");

        PunchCardRouter router = new PunchCardRouter(
            multisig, address(wdc), swapRouter, usdc, weth, feeRate, feeRecip
        );

        vm.stopBroadcast();

        console2.log("*** PILOT LINEAGE - THE LP HATCH NEVER CLOSES BY ITSELF ***");
        console2.log("Only pSKOOP launches through this factory. Disable it afterwards.");
        console2.log("");
        console2.log("suiteDeployer           ", address(suite));
        console2.log("lockerDeployerPilot     ", address(locker));
        console2.log("windDownController      ", address(wdc));
        console2.log("stagedTokenFactoryPilot ", address(factory));
        console2.log("punchCardRouter         ", address(router));
        console2.log("");
        console2.log("The factory is already authorised in this controller - no proposeFactory needed.");
        console2.log("Launch through StageMerchant.s.sol: PC_STAGE=1, then 2, then 3.");
        console2.log("While the hatch is open, nothing may claim this liquidity is locked.");
    }
}
