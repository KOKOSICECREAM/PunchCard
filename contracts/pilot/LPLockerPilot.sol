// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../beta/LPLockerBeta.sol";

/// @title LPLockerPilot — an LPLocker whose recovery hatch never closes by itself.
///
/// @notice **This removes the guardrail LPLockerBeta was written to enforce.** Read that
///         contract's first guardrail before using this one:
///
///         > **It expires by itself.** A manually-closed hatch can be left open forever
///         > through neglect or intent, which is the trapdoor this was supposed to avoid.
///         > `EVACUATION_WINDOW` closes it regardless of whether anyone acts.
///
///         That reasoning is still correct, and this contract does not refute it. It
///         accepts it, for one deployment, with the trapdoor open on purpose.
///
/// @dev **Why it exists.** KOKOS's own pilot is not a merchant launch on a schedule — it is
///      PunchCard testing its own machine with its own money, on its own token, for as long
///      as that takes. A 30-day fuse on that is a deadline invented by a constant rather
///      than by the work, and the failure it produces is the worst available one: the
///      window shuts mid-test and the capital is committed for a year because nobody
///      watched a calendar.
///
///      **Who may use it.** KOKOS/SKOOP, deployed by PunchCard, and nothing else. It is a
///      separate contract with a separate deployer and a separate factory precisely so that
///      "and nothing else" is enforced by which factory is authorised rather than by a
///      constructor argument nobody reads. A PunchCard merchant NEVER gets one of these:
///      merchants get `LPLockerBeta` during Stage 1 (30-day window, self-closing) and
///      `LPLocker` from Stage 2 (no recovery path at all, ever).
///
///      **What it costs.** For as long as the hatch is open, SKOOP's liquidity is not
///      locked, and no PunchCard surface may say that it is. `evacuationOpen()` is the
///      source of truth and the dapp already reads it rather than asserting a state.
///      Closing it is a deliberate act — `lockLP()` — and after that this contract is
///      byte-for-byte equivalent in behaviour to production.
///
///      **What is unchanged.** Evacuation is still all-or-nothing, still owner-only, still
///      terminal, and still loud. Only the deadline is gone.
contract LPLockerPilot is LPLockerBeta {

    /// @notice Always true. The locker lineages are told apart by which calls answer at
    ///         all — LPLockerBeta carries no marker constant of its own, so the functions
    ///         are the discriminator:
    ///
    ///             evacuationOpen() reverts                      → production, no hatch
    ///             evacuationOpen() answers, this reverts        → beta, 30-day hatch
    ///             both answer                                   → pilot, never expires
    ///
    ///         At the factory and deployer level the constants do the same job:
    ///         HAS_LP_RECOVERY is on beta and pilot, HAS_UNLIMITED_LP_RECOVERY on pilot only.
    bool public constant HAS_UNLIMITED_LP_RECOVERY = true;

    constructor(
        address _merchantToken,
        address _ownerWallet,
        address _windDownController,
        address _positionManager,
        address _factory,
        address _usdc,
        address _weth,
        address _punchcardFeeRecipient
    ) LPLockerBeta(
        _merchantToken, _ownerWallet, _windDownController, _positionManager,
        _factory, _usdc, _weth, _punchcardFeeRecipient
    ) {}

    /// @notice Open until someone closes it. `evacuationDeadline` is inherited and
    ///         meaningless here — deliberately not read.
    /// @dev The inherited immutable still says deploy + 30 days. Leaving a stale value
    ///      readable would be a trap for anything reading it directly, so
    ///      `evacuationExpiresAt()` below is the value to read, and it says never.
    function evacuationOpen() public view override returns (bool) {
        return !lpPermanentlyLocked;
    }

    /// @notice When the hatch closes on its own: never. type(uint256).max, not a date.
    /// @dev Exists so that anything reading a deadline gets the pilot's real answer rather
    ///      than the inherited 30-day value, which does not apply.
    function evacuationExpiresAt() external pure returns (uint256) {
        return type(uint256).max;
    }
}
