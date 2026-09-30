// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../contracts/WindDownController.sol";
import "../contracts/PunchCardRouter.sol";
import "../contracts/deployers/SuiteDeployer.sol";
import "../contracts/beta/TokenFactoryBeta.sol";
import "../contracts/beta/LockerDeployerBeta.sol";

/// @title DeployNetworkBeta
/// @notice Same choreography as DeployNetwork, but wires LockerDeployerBeta so every
///         merchant it deploys has a temporary, self-expiring LP recovery window.
/// @dev Used for two different things, and the difference is operational, not structural:
///
///      STAGE 0 — rehearsal. Tiny floors, throwaway controller, disposable addresses.
///                Recorded in deploy/network/base-mainnet-rehearsal.json.
///      STAGE 1 — beta. Real merchants, real seed, THE network controller that the
///                production factory will later be authorised into.
///                Recorded in deploy/network/base-mainnet.json.
///
///      Merchants deployed here do NOT have the permanently-locked-LP guarantee until
///      their window closes, so the site must not claim it of them until then.
contract DeployNetworkBeta is Script {
    function run() external {
        // Base refuses any transaction above 16,777,216 gas and the atomic lineage's
        // deploy() costs 17,325,962, so a network built here could be deployed and could
        // never onboard anyone. Mechanical, because a warning in a doc is a warning
        // somebody has to have read. Use DeployNetworkStaged.s.sol on Base.
        require(
            block.chainid != 8453,
            "The atomic TokenFactory lineage cannot deploy merchants on Base - deploy() exceeds the 16,777,216 per-transaction gas cap. Use DeployNetworkStaged.s.sol and StageMerchant.s.sol."
        );

        address multisig   = vm.envAddress("PC_MULTISIG");
        address deployerHot= vm.envAddress("PC_DEPLOYER");
        address feeRecip   = vm.envAddress("PC_FEE_RECIPIENT");
        address posMgr     = vm.envAddress("PC_POSITION_MANAGER");
        address swapRouter = vm.envAddress("PC_SWAP_ROUTER");
        address usdc       = vm.envAddress("PC_USDC");
        address weth       = vm.envAddress("PC_WETH");
        address oracle     = vm.envAddress("PC_ETH_USD_FEED");
        uint256 minUsdc    = vm.envUint("PC_MIN_USDC_SEED_USD");
        uint256 minEth     = vm.envUint("PC_MIN_ETH_SEED_USD");
        uint256 feeRate    = vm.envUint("PC_ROUTER_FEE_BPS");

        // Stage 0 is defined by being small. Crossing into real money must be a deliberate
        // act, not a forgotten environment variable: the same command with bigger floors
        // stops being a rehearsal and starts being a real merchant launch on a factory
        // whose LP can be recovered.
        if (minUsdc > 100 * 1e8 || minEth > 100 * 1e8) {
            require(
                vm.envOr("PC_BETA_REAL_MERCHANTS", false),
                "Floors exceed rehearsal size. Set PC_BETA_REAL_MERCHANTS=true only when deliberately launching Stage 1 beta merchants."
            );
        }

        // A WindDownController IS the network. Deploying a second one forks it: the router
        // binds to one controller and only recognises merchants in that controller's
        // registry, so merchants under a second controller can never swap against the
        // first one's. Unfixable afterwards, and invisible until a cross-stage swap fails.
        //
        // To ADD a deployment path to an existing network, use DeployProductionFactory.s.sol
        // and authorise it via the multisig. That is almost always what is wanted.
        require(
            vm.envOr("PC_CREATE_NEW_NETWORK", false),
            "This deploys a NEW WindDownController and therefore a NEW network. If you meant to add a factory to the existing network, use DeployProductionFactory.s.sol. Set PC_CREATE_NEW_NETWORK=true only when genuinely starting a network from nothing."
        );

        require(posMgr.code.length     > 0, "position manager has no code");
        require(swapRouter.code.length > 0, "swap router has no code");
        require(usdc.code.length       > 0, "USDC has no code");
        require(weth.code.length       > 0, "WETH has no code");
        require(oracle.code.length     > 0, "oracle has no code");

        vm.startBroadcast();

        SuiteDeployer            suite  = new SuiteDeployer();
        LockerDeployerBeta  locker = new LockerDeployerBeta();

        address predictedFactory =
            vm.computeCreateAddress(msg.sender, vm.getNonce(msg.sender) + 1);
        WindDownController wdc = new WindDownController(multisig, predictedFactory);

        TokenFactoryBeta factory = new TokenFactoryBeta(
            multisig, deployerHot, address(wdc), posMgr, usdc, weth,
            oracle, feeRecip, address(suite), address(locker), minUsdc, minEth
        );
        require(address(factory) == predictedFactory, "factory address mismatch");

        PunchCardRouter router = new PunchCardRouter(
            multisig, address(wdc), swapRouter, usdc, weth, feeRate, feeRecip
        );

        vm.stopBroadcast();

        console2.log("*** BETA LINEAGE - MERCHANT LP IS RECOVERABLE FOR 30 DAYS ***");
        console2.log("suiteDeployer      ", address(suite));
        console2.log("lockerDeployerBeta ", address(locker));
        console2.log("windDownController ", address(wdc));
        console2.log("tokenFactoryBeta   ", address(factory));
        console2.log("punchCardRouter    ", address(router));
        console2.log("Authorise the production factory into THIS controller later;");
        console2.log("do not deploy a second controller, or the network splits.");
    }
}
