// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../contracts/WindDownController.sol";
import "../contracts/PunchCardRouter.sol";
import "../contracts/deployers/SuiteDeployer.sol";
import "../contracts/rehearsal/TokenFactoryRehearsal.sol";
import "../contracts/rehearsal/LockerDeployerRehearsal.sol";

/// @title DeployNetworkRehearsal — REHEARSAL ONLY
/// @notice Same choreography as DeployNetwork, but wires LockerDeployerRehearsal so every
///         merchant it deploys has a temporary, self-expiring LP evacuation hatch.
/// @dev Never run this for production. The addresses it prints belong in
///      deploy/network/base-mainnet-rehearsal.json and nowhere else. Merchants deployed
///      through this factory do NOT have the locked-LP guarantee that punchcard.club
///      describes, so no outside merchant may ever be onboarded through it.
contract DeployNetworkRehearsal is Script {
    function run() external {
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

        // Refuse to run against production-sized floors. A rehearsal is defined by being
        // small; if someone points this at $2,000/$1,000 they are not rehearsing, they are
        // launching a real merchant through a factory with an evacuable LP.
        require(minUsdc <= 100 * 1e8, "Rehearsal floors must stay small");
        require(minEth  <= 100 * 1e8, "Rehearsal floors must stay small");

        require(posMgr.code.length     > 0, "position manager has no code");
        require(swapRouter.code.length > 0, "swap router has no code");
        require(usdc.code.length       > 0, "USDC has no code");
        require(weth.code.length       > 0, "WETH has no code");
        require(oracle.code.length     > 0, "oracle has no code");

        vm.startBroadcast();

        SuiteDeployer            suite  = new SuiteDeployer();
        LockerDeployerRehearsal  locker = new LockerDeployerRehearsal();

        address predictedFactory =
            vm.computeCreateAddress(msg.sender, vm.getNonce(msg.sender) + 1);
        WindDownController wdc = new WindDownController(multisig, predictedFactory);

        TokenFactoryRehearsal factory = new TokenFactoryRehearsal(
            multisig, deployerHot, address(wdc), posMgr, usdc, weth,
            oracle, feeRecip, address(suite), address(locker), minUsdc, minEth
        );
        require(address(factory) == predictedFactory, "factory address mismatch");

        PunchCardRouter router = new PunchCardRouter(
            multisig, address(wdc), swapRouter, usdc, weth, feeRate, feeRecip
        );

        vm.stopBroadcast();

        console2.log("*** REHEARSAL DEPLOYMENT - EVACUABLE LP - NOT FOR REAL MERCHANTS ***");
        console2.log("suiteDeployer           ", address(suite));
        console2.log("lockerDeployerRehearsal ", address(locker));
        console2.log("windDownController      ", address(wdc));
        console2.log("tokenFactoryRehearsal   ", address(factory));
        console2.log("punchCardRouter         ", address(router));
    }
}
