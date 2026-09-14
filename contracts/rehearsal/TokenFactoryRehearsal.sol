// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../TokenFactory.sol";

/// @title TokenFactoryRehearsal — REHEARSAL ONLY. NEVER ONBOARD A REAL MERCHANT.
/// @notice Identical logic to TokenFactory. Exists to be a different address with a
///         different name and an unmissable on-chain marker.
///
/// @dev Why this contract exists at all, given it adds nothing:
///
///      A rehearsal factory is just a TokenFactory constructed with
///      LockerDeployerRehearsal. Nothing in its bytecode differs from production, so
///      someone reading a block explorer six months from now would see "TokenFactory",
///      with no way to tell that every merchant it deploys has an evacuable LP.
///
///      Configuration that silently changes a trust guarantee is the exact failure this
///      codebase keeps producing. So the distinction is made structural: a different
///      contract name, and a constant anyone can query before trusting it.
///
///          cast call $FACTORY 'REHEARSAL_ONLY()(bool)'
///
///      Production reverts (no such function). A rehearsal factory returns true.
contract TokenFactoryRehearsal is TokenFactory {

    /// @notice Always true. Production TokenFactory has no such function, so a call that
    ///         reverts means production and a call returning true means rehearsal.
    bool public constant REHEARSAL_ONLY = true;

    constructor(
        address _multisig,
        address _deployer,
        address _windDownController,
        address _positionManager,
        address _usdc,
        address _weth,
        address _ethUsdOracle,
        address _punchcardFeeRecipient,
        address _suiteDeployer,
        address _lockerDeployer,
        uint256 _minUsdcSeedUsd,
        uint256 _minEthSeedUsd
    ) TokenFactory(
        _multisig, _deployer, _windDownController, _positionManager, _usdc, _weth,
        _ethUsdOracle, _punchcardFeeRecipient, _suiteDeployer, _lockerDeployer,
        _minUsdcSeedUsd, _minEthSeedUsd
    ) {}
}
