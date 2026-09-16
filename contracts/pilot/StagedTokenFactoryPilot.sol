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

    /// @notice Always true. Activation checks that the market can trade, not that every
    ///         allocation reached its target.
    bool public constant ALLOCATIONS_ARE_TARGETS = true;

    /// @dev Allocations are targets here, not gates.
    ///
    ///      On beta and production these are the point: "every business runs the same
    ///      programme with the same numbers" is only true if the numbers are checked before
    ///      the network accepts the token. A merchant 10% short on rewards is running a
    ///      different programme while claiming to run this one, so activation refuses.
    ///
    ///      The pilot is a first-party launch of unaudited code, funded by hand precisely so
    ///      each contract can be tested before it holds much. Gating activation on exact
    ///      balances would mean one transfer landing wrong — a decimal, a stuck token, a
    ///      contract that needs redeploying — strands the launch. That is the wrong failure
    ///      for the merchant that is meant to prove the network works.
    ///
    ///      **What it costs is a claim.** At activation the pilot cannot say the allocations
    ///      are fully funded, only that they are targets the owner can still complete by
    ///      sending more — nothing here prevents a top-up afterwards. `fundingAtActivation`
    ///      records what was actually there, so the difference is readable on-chain instead
    ///      of resting on anyone's word.
    ///
    ///      The hard gates in `activateMerchant` still apply: the token exists, the pools
    ///      were created, and the positions are here to hand over. A merchant that cannot
    ///      trade is not a network test.
    function _checkAllocations(address, MerchantSuite storage) internal pure override {
        // Deliberately empty. See above.
    }

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
