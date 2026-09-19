// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ISuiteDeployer
/// @notice Interface the factory uses to reach SuiteDeployer.
/// @dev The factory must call through this interface, never the concrete contract —
///      importing SuiteDeployer would pull the suite's creation bytecode back into the
///      factory and undo the split entirely.
interface ISuiteDeployer {
    function deployToken(
        string calldata name,
        string calldata symbol,
        uint256 totalSupply_,
        address mintTo,
        bytes32 ipfsHash
    ) external returns (address);

    function deployVesting(
        address token,
        address teamWallet,
        address windDownController,
        uint256 cliffDuration,
        uint256 vestDuration,
        address activator
    ) external returns (address);

    function deployTreasury(
        address token,
        address ownerWallet,
        address windDownController,
        uint256 timelockDuration,
        address activator
    ) external returns (address);

    function deployEscrow(
        address token,
        address operator,
        address ownerWallet,
        address windDownController,
        uint256 rewardsAllocation,
        uint256 perTxFloor,
        uint256 perTxMax,
        address activator
    ) external returns (address);
}
