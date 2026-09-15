// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./LPLockerPilot.sol";

/// @title LockerDeployerPilot — produces lockers whose recovery hatch never expires.
/// @dev Same interface as LockerDeployer and LockerDeployerBeta. Swapping this into a
///      factory changes what every merchant it deploys is promised, while the factory's own
///      bytecode is unchanged — which is exactly why TokenFactoryPilot exists to make the
///      difference visible on-chain rather than leaving it in a constructor argument.
contract LockerDeployerPilot {

    bool public constant HAS_LP_RECOVERY = true;
    bool public constant HAS_UNLIMITED_LP_RECOVERY = true;

    function deployLocker(
        address merchantToken,
        address ownerWallet,
        address windDownController,
        address positionManager,
        address factory,
        address usdc,
        address weth,
        address punchcardFeeRecipient
    ) external returns (address) {
        return address(new LPLockerPilot(
            merchantToken, ownerWallet, windDownController, positionManager,
            factory, usdc, weth, punchcardFeeRecipient
        ));
    }
}
