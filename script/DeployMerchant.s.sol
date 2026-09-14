// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../contracts/TokenFactory.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title DeployMerchant
/// @notice Deploys one merchant suite through an already-deployed TokenFactory.
/// @dev Approves the factory for exactly the USDC seed immediately before deploying.
///      A standing approval is a live risk: deploy() pulls from ownerWallet, so anyone
///      able to call it could consume a lingering allowance with their own parameters.
contract DeployMerchant is Script {
    function run() external {
        address factoryAddr = vm.envAddress("PC_FACTORY");
        address usdc        = vm.envAddress("PC_USDC");

        address owner    = vm.envAddress("MERCHANT_OWNER");
        address team     = vm.envAddress("MERCHANT_TEAM");
        address operator = vm.envAddress("MERCHANT_OPERATOR");

        uint256 usdcSeed = vm.envUint("MERCHANT_USDC_SEED");   // 6dp
        uint256 ethSeed  = vm.envUint("MERCHANT_ETH_SEED");    // wei

        TokenFactory factory = TokenFactory(factoryAddr);

        TokenFactory.DeployParams memory p = TokenFactory.DeployParams({
            name:           vm.envString("MERCHANT_NAME"),
            symbol:         vm.envString("MERCHANT_SYMBOL"),
            ipfsHash:       keccak256(bytes(vm.envString("MERCHANT_IPFS"))),
            ownerWallet:    owner,
            teamWallet:     team,
            operator:       operator,
            usdcFeeTier:    3000,
            ethFeeTier:     3000,
            usdcPairAmount: usdcSeed,
            ethPairAmount:  ethSeed,
            perTxFloor:     vm.envUint("MERCHANT_PER_TX_FLOOR"),
            perTxMax:       vm.envUint("MERCHANT_PER_TX_MAX")
        });

        // deploy() pulls USDC from p.ownerWallet, NOT from msg.sender. In production the
        // broadcaster is PunchCard's deployer hot wallet (deploy() is onlyDeployer) and
        // ownerWallet is the merchant — two different accounts — so approving from the
        // broadcaster does nothing and the deploy reverts on transferFrom.
        //
        // Only approve when the broadcaster genuinely is the owner. Otherwise require the
        // merchant's allowance to already be in place, and say so clearly rather than
        // failing later inside the factory.
        uint256 allowance = IERC20(usdc).allowance(owner, factoryAddr);
        bool broadcasterIsOwner = msg.sender == owner;

        if (!broadcasterIsOwner) {
            require(
                allowance >= usdcSeed,
                "ownerWallet has not approved the factory for usdcSeed - the MERCHANT must approve from their own wallet before this runs"
            );
        }

        vm.startBroadcast();
        if (broadcasterIsOwner && allowance < usdcSeed) {
            // Exact amount, immediately before use — never leave a standing allowance,
            // since anyone able to call deploy() could consume it with their own params.
            IERC20(usdc).approve(factoryAddr, usdcSeed);
        }
        factory.deploy{value: ethSeed}(p);
        vm.stopBroadcast();

        console2.log("deployed - read MerchantDeployed from the tx receipt for addresses");
    }
}
