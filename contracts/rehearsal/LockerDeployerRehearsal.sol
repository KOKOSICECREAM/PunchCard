// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./LPLockerRehearsal.sol";

/// @title LockerDeployerRehearsal — REHEARSAL ONLY. NEVER USE IN PRODUCTION.
/// @notice Same interface as LockerDeployer, but produces lockers with a temporary,
///         self-expiring LP evacuation hatch.
/// @dev This is the whole mechanism by which a factory becomes a rehearsal factory:
///      TokenFactory takes its locker deployer as a constructor argument and calls it
///      through ILockerDeployer, so swapping this in changes what every merchant's LP
///      guarantee means — while the factory's own bytecode is byte-identical to
///      production. That invisibility is the danger. TokenFactoryRehearsal exists purely
///      to make it visible on-chain.
contract LockerDeployerRehearsal {

    bool public constant REHEARSAL_ONLY = true;

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
        return address(new LPLockerRehearsal(
            merchantToken, ownerWallet, windDownController, positionManager,
            factory, usdc, weth, punchcardFeeRecipient
        ));
    }
}
