// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../contracts/WindDownController.sol";
import "../contracts/PunchCardRouter.sol";
import "../contracts/deployers/SuiteDeployer.sol";
import "../contracts/beta/StagedTokenFactoryBeta.sol";
import "../contracts/beta/LockerDeployerBeta.sol";

/// @title DeployNetworkStaged — the network, with a factory that can actually run on Base
///
/// @dev Replaces DeployNetworkBeta for anything targeting Base. The atomic TokenFactory
///      lineage costs 17,325,962 gas to run `deploy()` against a 16,777,216 per-transaction
///      ceiling, so a network built around it can be deployed and can never onboard anyone.
///
///      Merchants come through `StageMerchant.s.sol` in three steps afterwards.
contract DeployNetworkStaged is Script {
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

        // A WindDownController IS the network. A second one forks it: the router binds to
        // one controller and only recognises merchants in that registry, so merchants under
        // a second controller can never swap against the first one's. Unfixable afterwards
        // and invisible until a cross-stage swap fails.
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

        SuiteDeployer      suite  = new SuiteDeployer();
        LockerDeployerBeta locker = new LockerDeployerBeta();

        address predictedFactory =
            vm.computeCreateAddress(msg.sender, vm.getNonce(msg.sender) + 1);
        WindDownController wdc = new WindDownController(multisig, predictedFactory);

        StagedTokenFactoryBeta factory = new StagedTokenFactoryBeta(
            multisig, deployerHot, address(wdc), posMgr, usdc, weth,
            oracle, feeRecip, address(suite), address(locker), minUsdc, minEth
        );
        require(address(factory) == predictedFactory, "factory address mismatch");

        PunchCardRouter router = new PunchCardRouter(
            multisig, address(wdc), swapRouter, usdc, weth, feeRate, feeRecip
        );

        vm.stopBroadcast();

        console2.log("*** STAGED BETA LINEAGE - MERCHANT LP IS RECOVERABLE FOR 30 DAYS ***");
        console2.log("suiteDeployer          ", address(suite));
        console2.log("lockerDeployerBeta     ", address(locker));
        console2.log("windDownController     ", address(wdc));
        console2.log("stagedTokenFactoryBeta ", address(factory));
        console2.log("punchCardRouter        ", address(router));
        console2.log("");
        console2.log("Merchants launch in three steps - see StageMerchant.s.sol.");
        console2.log("Nothing is a merchant until stage 3 registers it.");
    }
}
