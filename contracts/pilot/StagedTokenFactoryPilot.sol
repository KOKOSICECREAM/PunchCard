// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../beta/StagedTokenFactoryBeta.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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

    using SafeERC20 for IERC20;

    bool public constant HAS_UNLIMITED_LP_RECOVERY = true;

    /// @notice Always true. Stage 1 mints the whole supply to the merchant; nothing is put
    ///         into the escrow, vesting wallet or treasury until they do it by hand.
    bool public constant SUPPLY_IS_HAND_FUNDED = true;

    /// @dev The whole supply to the merchant, and nothing into the suite contracts.
    ///
    ///      The default path funds 45/15/10 in the same transaction that creates those three
    ///      contracts. For a merchant that is right — a programme should be live the moment
    ///      it is assembled, and three hand-made transfers is three chances to get an address
    ///      or an amount wrong.
    ///
    ///      For the first launch of unaudited code it is exactly backwards. It puts 70% of
    ///      supply inside contracts nobody has exercised, so the first test of each one
    ///      happens with everything already in it. Minting to the merchant instead lets them
    ///      fund one contract at a time and test as they go, with the rest of the supply
    ///      still in a wallet they control.
    ///
    ///      **This does not weaken what registration means.** `activateMerchant` checks
    ///      every balance before it registers anything, so a hand-funded suite is either
    ///      identical to an atomically-funded one by then, or it does not get on the
    ///      network. The merchant also ends at zero — they must have moved all of it,
    ///      including approving the LP share to the factory for stage 2.
    function _distributeAllocations(
        IERC20  token,
        address /* escrow */,
        address /* vesting */,
        address /* treasury */,
        address ownerWallet
    ) internal override {
        token.safeTransfer(ownerWallet, TOTAL_SUPPLY);
    }

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
