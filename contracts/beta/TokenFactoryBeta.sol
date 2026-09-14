// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../TokenFactory.sol";

/// @title TokenFactoryBeta — real merchants, with a temporary LP recovery window.
/// @notice Identical logic to TokenFactory. Exists to be a different address with a
///         different name and an unmissable on-chain marker.
///
/// @dev Why this contract exists at all, given it adds nothing:
///
///      A beta factory is just a TokenFactory constructed with LockerDeployerBeta.
///      Nothing in its bytecode differs from production, so someone reading a block
///      explorer six months from now would see "TokenFactory", with no way to tell that
///      every merchant it deploys has a recoverable LP.
///
///      Configuration that silently changes a trust guarantee is the exact failure this
///      codebase keeps producing. So the distinction is made structural: a different
///      contract name, and a constant anyone can query before trusting it.
///
///          cast call $FACTORY 'HAS_LP_RECOVERY()(bool)'
///
///      Production reverts (no such function). A beta factory returns true.
///
///      Beta and production merchants share ONE WindDownController and ONE router, so they
///      route against each other as a single network. That is why the controller accepts
///      multiple authorised factories: a separate controller per stage would have split
///      the network exactly where the network effect is being proven.
contract TokenFactoryBeta is TokenFactory {

    /// @notice Always true. Production TokenFactory has no such function, so a call that
    ///         reverts means production and a call returning true means beta — i.e. this
    ///         factory's merchants have a temporary LP recovery window.
    bool public constant HAS_LP_RECOVERY = true;

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
