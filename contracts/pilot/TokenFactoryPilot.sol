// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../beta/TokenFactoryBeta.sol";

/// @title TokenFactoryPilot — KOKOS's own pilot, with an LP hatch that never expires.
///
/// @notice One merchant is meant to come through here: SKOOP. Authorise it, deploy KOKOS,
///         and disable it again. The WindDownController's `proposeFactory(addr, false)`
///         path exists for exactly this — merchants already registered keep working, and
///         the deployment path closes.
///
/// @dev Identical logic to TokenFactory. Like TokenFactoryBeta, it exists to be a different
///      address with a different name and an unmissable on-chain marker, because the only
///      real difference is which locker deployer it was constructed with and that is
///      invisible in a block explorer.
///
///          cast call $FACTORY 'HAS_LP_RECOVERY()(bool)'            → true on beta and pilot
///          cast call $FACTORY 'HAS_UNLIMITED_LP_RECOVERY()(bool)'  → true on pilot only
///
///      **Do not authorise this factory for a merchant.** Merchants get a self-closing
///      30-day window from TokenFactoryBeta, or no window at all from TokenFactory. An
///      open-ended hatch is PunchCard testing its own token with its own money; offering it
///      to a merchant would mean offering a liquidity guarantee that can be withdrawn at
///      any time, which is not a guarantee.
contract TokenFactoryPilot is TokenFactoryBeta {

    /// @notice Always true. TokenFactory has neither marker; TokenFactoryBeta has only
    ///         HAS_LP_RECOVERY. A call that reverts, returns true, or returns true on both
    ///         distinguishes the three lineages without trusting a label.
    bool public constant HAS_UNLIMITED_LP_RECOVERY = true;

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
    ) TokenFactoryBeta(
        _multisig, _deployer, _windDownController, _positionManager, _usdc, _weth,
        _ethUsdOracle, _punchcardFeeRecipient, _suiteDeployer, _lockerDeployer,
        _minUsdcSeedUsd, _minEthSeedUsd
    ) {}
}
