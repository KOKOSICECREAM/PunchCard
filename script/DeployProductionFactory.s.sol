// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../contracts/TokenFactory.sol";
import "../contracts/deployers/SuiteDeployer.sol";
import "../contracts/deployers/LockerDeployer.sol";
import "../contracts/interfaces/IWindDownController.sol";

/// @title DeployProductionFactory — Stage 2
/// @notice Deploys the STRICT production factory against the network that already exists.
///
/// @dev This script deliberately does NOT deploy a WindDownController.
///
///      One controller is the network. A second controller is a forked network: the router
///      binds to one controller and only recognises merchants in that controller's
///      registry, so merchants registered under a second controller can never swap against
///      the first one's. That is unfixable after the fact and invisible until the first
///      cross-stage swap fails.
///
///      DeployNetwork.s.sol creates a controller and is therefore the WRONG script for
///      Stage 2. This one exists so nobody has to remember that.
///
///      After running, the multisig authorises the new factory into the existing
///      controller. That is a two-step, 48-hour timelocked action — it is not done here,
///      because a deploy script should not hold governance keys.
contract DeployProductionFactory is Script {
    function run() external {
        address multisig   = vm.envAddress("PC_MULTISIG");
        address deployerHot= vm.envAddress("PC_DEPLOYER");
        address feeRecip   = vm.envAddress("PC_FEE_RECIPIENT");
        address posMgr     = vm.envAddress("PC_POSITION_MANAGER");
        address usdc       = vm.envAddress("PC_USDC");
        address weth       = vm.envAddress("PC_WETH");
        address oracle     = vm.envAddress("PC_ETH_USD_FEED");
        uint256 minUsdc    = vm.envUint("PC_MIN_USDC_SEED_USD");
        uint256 minEth     = vm.envUint("PC_MIN_ETH_SEED_USD");

        // The existing network. Not deployed here — reused.
        address wdc = vm.envAddress("PC_WIND_DOWN_CONTROLLER");
        require(wdc.code.length > 0, "controller has no code - is this the right address?");

        // Production floors are real. A strict factory with rehearsal floors would let a
        // merchant open a market on $10 of liquidity with no recovery path at all.
        require(minUsdc >= 1_000 * 1e8, "Production USDC floor too low");
        require(minEth  >= 500 * 1e8,   "Production ETH floor too low");

        require(posMgr.code.length > 0, "position manager has no code");
        require(usdc.code.length   > 0, "USDC has no code");
        require(weth.code.length   > 0, "WETH has no code");
        require(oracle.code.length > 0, "oracle has no code");

        vm.startBroadcast();

        SuiteDeployer  suite  = new SuiteDeployer();
        LockerDeployer locker = new LockerDeployer();

        TokenFactory factory = new TokenFactory(
            multisig, deployerHot, wdc, posMgr, usdc, weth,
            oracle, feeRecip, address(suite), address(locker), minUsdc, minEth
        );

        vm.stopBroadcast();

        console2.log("=== STAGE 2: production factory deployed ===");
        console2.log("suiteDeployer     ", address(suite));
        console2.log("lockerDeployer    ", address(locker));
        console2.log("tokenFactory      ", address(factory));
        console2.log("against controller", wdc);
        console2.log("");
        console2.log("NOT YET USABLE. The multisig must authorise it:");
        console2.log("  1. proposeFactory(factory, true)");
        console2.log("  2. wait 48 hours");
        console2.log("  3. executeFactory(factory)");
        console2.log("Then retire the beta factory the same way with authorize=false.");
        console2.log("Existing beta merchants keep working either way.");
    }
}
