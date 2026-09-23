// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../beta/StagedTokenFactoryBeta.sol";

/// @notice **NOT USED FOR pSKOOP. Nothing on the live path deploys this.**
///
///         pSKOOP is hand-assembled and admitted through `WindDownController.registerManual`
///         — the manual registrar path. This contract was built when pSKOOP was going to
///         launch through a factory, and it no longer is.
///
///         Kept rather than deleted because a pilot factory is the obvious tool if a second
///         first-party token ever needs one, and pruning while the architecture is still
///         settling is churn. **Do not deploy it unless you are deliberately choosing a
///         factory-launched first-party pilot**, which is a decision, not a default.
///
///         `LPLockerPilot` is a different matter and IS live: it is the never-closing LP
///         hatch pSKOOP's hand-assembled suite uses. The pilot locker is needed; the pilot
///         factory is not.
///
/// @title StagedTokenFactoryPilot — pSKOOP's own path, LP hatch that never expires.
///
/// @notice One merchant is meant to come through here. Authorise it, stage/fund/activate
///         the pilot, then disable it again — `WindDownController.proposeFactory(addr,
///         false)` stops it registering new merchants while leaving the one it already
///         registered working.
///
/// @dev **Do not authorise this factory for a merchant.** Merchants get a self-closing
///      30-day window from the beta lineage, or no window at all from production. An
///      open-ended hatch is PunchCard testing its own token with its own money; offering it
///      to a merchant would mean offering a liquidity guarantee that can be withdrawn at
///      any time, which is not a guarantee.
///
///          cast call $FACTORY 'HAS_LP_RECOVERY()(bool)'            -> true on beta and pilot
///          cast call $FACTORY 'HAS_UNLIMITED_LP_RECOVERY()(bool)'  -> true on pilot only
contract StagedTokenFactoryPilot is StagedTokenFactoryBeta {

    bool public constant HAS_UNLIMITED_LP_RECOVERY = true;

    constructor(
        address _multisig, address _deployer, address _windDownController,
        address _positionManager, address _usdc, address _weth, address _ethUsdOracle,
        address _punchcardFeeRecipient, address _suiteDeployer, address _lockerDeployer,
        uint256 _minUsdcSeedUsd, uint256 _minEthSeedUsd
    ) StagedTokenFactoryBeta(
        _multisig, _deployer, _windDownController, _positionManager, _usdc, _weth,
        _ethUsdOracle, _punchcardFeeRecipient, _suiteDeployer, _lockerDeployer,
        _minUsdcSeedUsd, _minEthSeedUsd
    ) {}
}
