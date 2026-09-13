// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../LPLocker.sol";

/// @title LockerDeployer
/// @notice Construction helper — deploys a merchant's LPLocker.
/// @dev Separate from SuiteDeployer because LPLocker alone is 12,113 bytes of initcode;
///      holding all five suite contracts in one helper would exceed EIP-170 again.
///      Permissionless for the same reasons as SuiteDeployer — see the note there.
contract LockerDeployer {

    /// @param factory Address the locker will accept initializeLP() from — the TokenFactory
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
        return address(new LPLocker(
            merchantToken,
            ownerWallet,
            windDownController,
            positionManager,
            factory,
            usdc,
            weth,
            punchcardFeeRecipient
        ));
    }
}
