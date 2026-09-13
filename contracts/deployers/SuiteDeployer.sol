// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../PunchCardToken.sol";
import "../VestingWallet.sol";
import "../TreasuryTimelock.sol";
import "../RewardEscrow.sol";

/// @title SuiteDeployer
/// @notice Construction helper — deploys the four non-LP contracts of a merchant suite.
/// @dev Exists purely to keep TokenFactory under the EIP-170 24,576-byte limit. Using
///      `new X(...)` embeds X's full creation bytecode in the caller, and all five suite
///      contracts together are 27,772 bytes of initcode — more than a single contract can
///      hold. They are therefore split across this and LockerDeployer.
///
///      **Deliberately permissionless.** Restricting it to the factory would reintroduce a
///      circular dependency (factory needs the deployer's address, deployer needs the
///      factory's), and it buys nothing: a contract deployed through here in isolation is
///      inert. It holds no supply beyond what the caller asked to be minted to themselves,
///      is not registered with the WindDownController, and has no pools. Authority comes
///      from TokenFactory — which holds the supply, distributes it and registers the suite
///      — not from whoever called `new`.
///
///      Being a merchant of the network means being in a MerchantDeployed event from
///      TokenFactory and registered with WindDownController. Nothing else confers it.
contract SuiteDeployer {

    /// @param mintTo Receives the entire fixed supply — the factory, which distributes it
    function deployToken(
        string calldata name,
        string calldata symbol,
        uint256 totalSupply_,
        address mintTo,
        bytes32 ipfsHash
    ) external returns (address) {
        return address(new PunchCardToken(name, symbol, totalSupply_, mintTo, ipfsHash));
    }

    function deployVesting(
        address token,
        address teamWallet,
        address windDownController,
        uint256 cliffDuration,
        uint256 vestDuration
    ) external returns (address) {
        return address(new VestingWallet(token, teamWallet, windDownController, cliffDuration, vestDuration));
    }

    function deployTreasury(
        address token,
        address ownerWallet,
        address windDownController,
        uint256 timelockDuration
    ) external returns (address) {
        return address(new TreasuryTimelock(token, ownerWallet, windDownController, timelockDuration));
    }

    function deployEscrow(
        address token,
        address operator,
        address ownerWallet,
        address windDownController,
        uint256 dailyCap,
        uint256 perTxFloor,
        uint256 perTxMax
    ) external returns (address) {
        return address(new RewardEscrow(token, operator, ownerWallet, windDownController, dailyCap, perTxFloor, perTxMax));
    }
}
