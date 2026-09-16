// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../contracts/StagedTokenFactory.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title StageMerchant — one step of a merchant launch per run
///
/// @notice `PC_STAGE` selects which:
///
///             1  stageSuite        deploy token and suite, distribute allocations
///             2  fundAndMintLP     pull the seed, create both pools, mint LP
///             3  activateMerchant  hand LP over, start the clocks, register
///             0  abortStaging      abandon before activation, return the seed
///
///         Deliberately one step per invocation rather than a loop. Between them the
///         assembly is inspectable, and the whole reason for staging is that it can be
///         looked at before it becomes a merchant. A script that ran all three in sequence
///         would be the atomic factory again, with extra steps and no inspection.
///
/// @dev Stage 2 pulls USDC from the MERCHANT's wallet, not the broadcaster's, so the
///      merchant must approve the factory themselves first — same rule the atomic
///      DeployMerchant.s.sol had, and the same reason: the broadcaster is PunchCard's hot
///      wallet and the capital is the merchant's.
contract StageMerchant is Script {
    function run() external {
        address factoryAddr = vm.envAddress("PC_FACTORY");
        uint256 stage       = vm.envUint("PC_STAGE");
        StagedTokenFactory f = StagedTokenFactory(payable(factoryAddr));

        if (stage == 1) {
            vm.startBroadcast();
            address staged = f.stageSuite(StagedTokenFactory.StageParams({
                name:        vm.envString("MERCHANT_NAME"),
                symbol:      vm.envString("MERCHANT_SYMBOL"),
                ipfsHash:    keccak256(bytes(vm.envString("MERCHANT_IPFS"))),
                ownerWallet: vm.envAddress("MERCHANT_OWNER"),
                teamWallet:  vm.envAddress("MERCHANT_TEAM"),
                operator:    vm.envAddress("MERCHANT_OPERATOR"),
                perTxFloor:  vm.envUint("MERCHANT_PER_TX_FLOOR"),
                perTxMax:    vm.envUint("MERCHANT_PER_TX_MAX")
            }));
            vm.stopBroadcast();

            console2.log("STAGED - not a merchant yet, not registered, no clocks running.");
            console2.log("merchantToken ", staged);
            console2.log("Pass it as PC_TOKEN for stage 2.");
            return;
        }

        address token = vm.envAddress("PC_TOKEN");

        if (stage == 2) {
            uint256 usdcSeed = vm.envUint("MERCHANT_USDC_SEED");
            uint256 ethSeed  = vm.envUint("MERCHANT_ETH_SEED");
            address usdc     = vm.envAddress("PC_USDC");
            (, address owner,,,,,,,,,,,,,) = f.suites(token);

            require(
                IERC20(usdc).allowance(owner, factoryAddr) >= usdcSeed,
                "ownerWallet has not approved the factory for the USDC seed. The MERCHANT must approve it from their own wallet - deploy pulls from them, not from the broadcaster."
            );

            vm.startBroadcast();
            f.fundAndMintLP{value: ethSeed}(StagedTokenFactory.FundParams({
                token:          token,
                usdcFeeTier:    uint24(vm.envUint("MERCHANT_USDC_FEE_TIER")),
                ethFeeTier:     uint24(vm.envUint("MERCHANT_ETH_FEE_TIER")),
                usdcPairAmount: usdcSeed,
                ethPairAmount:  ethSeed
            }));
            vm.stopBroadcast();

            console2.log("FUNDED - pools created, LP held by the factory, still not a merchant.");
            console2.log("Inspect everything, then run stage 3.");
            return;
        }

        if (stage == 3) {
            vm.startBroadcast();
            f.activateMerchant(token);
            vm.stopBroadcast();
            console2.log("ACTIVE - registered, clocks started, LP handed to the locker.");
            console2.log("This is now a PunchCard merchant. It cannot be un-activated.");
            return;
        }

        if (stage == 0) {
            require(
                vm.envOr("PC_CONFIRM_ABORT", false),
                "abortStaging is terminal: the token can never be staged again. Set PC_CONFIRM_ABORT=true."
            );
            vm.startBroadcast();
            f.abortStaging(token);
            vm.stopBroadcast();
            console2.log("ABORTED - seed returned to the merchant, token left dead and unregistered.");
            return;
        }

        revert("PC_STAGE must be 1, 2, 3, or 0 to abort");
    }
}
