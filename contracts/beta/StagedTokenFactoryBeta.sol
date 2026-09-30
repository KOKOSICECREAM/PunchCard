// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../StagedTokenFactory.sol";

/// @title StagedTokenFactoryBeta — real merchants, with a temporary LP recovery window.
/// @notice Identical logic to StagedTokenFactory. Exists to be a different address with a
///         different name and an unmissable on-chain marker.
/// @dev A beta factory is just a StagedTokenFactory constructed with LockerDeployerBeta.
///      Nothing in its bytecode differs, so someone reading a block explorer later would
///      see "StagedTokenFactory" with no way to tell that every merchant under it has a
///      recoverable LP. Configuration that silently changes a trust guarantee is the exact
///      failure this codebase keeps producing, so the distinction is structural.
///
///          cast call $FACTORY 'HAS_LP_RECOVERY()(bool)'
///
///      Production reverts (no such function). A beta factory returns true.
contract StagedTokenFactoryBeta is StagedTokenFactory {

    bool public constant HAS_LP_RECOVERY = true;

    constructor(
        address _multisig, address _deployer, address _windDownController,
        address _positionManager, address _usdc, address _weth, address _ethUsdOracle,
        address _punchcardFeeRecipient, address _suiteDeployer, address _lockerDeployer,
        uint256 _minUsdcSeedUsd, uint256 _minEthSeedUsd
    ) StagedTokenFactory(
        _multisig, _deployer, _windDownController, _positionManager, _usdc, _weth,
        _ethUsdOracle, _punchcardFeeRecipient, _suiteDeployer, _lockerDeployer,
        _minUsdcSeedUsd, _minEthSeedUsd
    ) {}
}
