// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../contracts/WindDownController.sol";
import "../contracts/TokenFactory.sol";
import "../contracts/PunchCardRouter.sol";
import "../contracts/deployers/SuiteDeployer.sol";
import "../contracts/deployers/LockerDeployer.sol";

/// @title DeployNetwork
/// @notice One-time PunchCard network deployment. Run once per chain.
/// @dev Resolves the WindDownController <-> TokenFactory circular dependency by predicting
///      the factory's address with computeCreateAddress, rather than deploying a throwaway
///      controller and leaving a dead one on-chain.
///
///      Every external address is read from the environment so nothing is hardcoded — a
///      wrong address here mis-deploys the whole network, and one in the original README
///      was a single character off from an address with no code on it.
contract DeployNetwork is Script {
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

        // Fail loudly here rather than after spending gas on a network nobody can use.
        require(posMgr.code.length     > 0, "position manager has no code");
        require(swapRouter.code.length > 0, "swap router has no code");
        require(usdc.code.length       > 0, "USDC has no code");
        require(weth.code.length       > 0, "WETH has no code");
        require(oracle.code.length     > 0, "oracle has no code");

        vm.startBroadcast();

        SuiteDeployer  suite  = new SuiteDeployer();
        LockerDeployer locker = new LockerDeployer();

        address predictedFactory =
            vm.computeCreateAddress(msg.sender, vm.getNonce(msg.sender) + 1);
        WindDownController wdc = new WindDownController(multisig, predictedFactory);

        TokenFactory factory = new TokenFactory(
            multisig, deployerHot, address(wdc), posMgr, usdc, weth,
            oracle, feeRecip, address(suite), address(locker), minUsdc, minEth
        );
        require(address(factory) == predictedFactory, "factory address mismatch");

        PunchCardRouter router = new PunchCardRouter(
            multisig, address(wdc), swapRouter, usdc, weth, feeRate, feeRecip
        );

        vm.stopBroadcast();

        console2.log("suiteDeployer      ", address(suite));
        console2.log("lockerDeployer     ", address(locker));
        console2.log("windDownController ", address(wdc));
        console2.log("tokenFactory       ", address(factory));
        console2.log("punchCardRouter    ", address(router));
    }
}
