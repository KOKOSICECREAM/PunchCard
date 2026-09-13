// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ILockerDeployer
/// @notice Interface the factory uses to reach LockerDeployer.
/// @dev Call through this interface only — see the note on ISuiteDeployer.
interface ILockerDeployer {
    function deployLocker(
        address merchantToken,
        address ownerWallet,
        address windDownController,
        address positionManager,
        address factory,
        address usdc,
        address weth,
        address punchcardFeeRecipient
    ) external returns (address);
}
