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
        // Base refuses any transaction above 16,777,216 gas and the atomic lineage's
        // deploy() costs 17,325,962, so a network built here could be deployed and could
        // never onboard anyone. Mechanical, because a warning in a doc is a warning
        // somebody has to have read. Use DeployNetworkStaged.s.sol on Base.
        require(
            block.chainid != 8453,
            "The atomic TokenFactory lineage cannot deploy merchants on Base - deploy() exceeds the 16,777,216 per-transaction gas cap. Use DeployNetworkStaged.s.sol and StageMerchant.s.sol."
        );

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
        // ownerWallet is the merchant, so the merchant must approve the factory themselves.
        //
        // This deliberately does NOT try to detect whether the broadcaster is the owner.
        // `msg.sender` here is the script's sender, which before vm.startBroadcast() is not
        // reliably the broadcast signer — it depends on --sender, --account and the forge
        // version. Inferring identity from it looked like it worked and would have been
        // brittle. Intent is declared explicitly instead.
        uint256 allowance = IERC20(usdc).allowance(owner, factoryAddr);

        if (allowance < usdcSeed) {
            require(
                vm.envOr("MERCHANT_SELF_APPROVE", false),
                "ownerWallet has not approved the factory. Either have the MERCHANT approve it from their own wallet, or set MERCHANT_SELF_APPROVE=true when you are deliberately broadcasting AS ownerWallet."
            );
        }

        vm.startBroadcast();
        if (allowance < usdcSeed) {
            // Runs as the broadcaster. If the broadcaster is not actually ownerWallet this
            // approval lands on the wrong account and deploy() reverts on transferFrom a
            // few lines later — a loud, immediate failure rather than a silent mis-approval.
            // Exact amount, immediately before use: never leave a standing allowance, since
            // anyone able to call deploy() could consume it with their own parameters.
            IERC20(usdc).approve(factoryAddr, usdcSeed);
        }
        factory.deploy{value: ethSeed}(p);
        vm.stopBroadcast();

        console2.log("deployed - read MerchantDeployed from the tx receipt for addresses");
    }
}
