// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ITreasuryTimelock {

    // ── STRUCTS ──────────────────────────────────────────────────────────────

    struct PendingRelease {
        uint256 amount;
        uint256 submittedAt;
        uint256 availableAt;
    }

    // ── EVENTS ───────────────────────────────────────────────────────────────

    event ReleaseSubmitted(
        address indexed merchantToken,
        uint256 amount,
        uint256 availableAt,
        uint256 timestamp
    );

    event ReleaseExecuted(
        address indexed merchantToken,
        uint256 amount,
        uint256 timestamp
    );

    event ReleaseCancelled(
        address indexed merchantToken,
        uint256 amount,
        uint256 timestamp
    );

    event TreasuryFrozen(
        address indexed merchantToken,
        uint256 timestamp
    );

    event TreasuryBurned(
        address indexed merchantToken,
        uint256 amount,
        uint256 timestamp
    );

    // ── OPERATIONAL ───────────────────────────────────────────────────────────

    /// @notice Submits a treasury release request
    /// @dev ownerWallet only. Reverts if frozen, pending exists, amount zero, or insufficient balance.
    ///      Starts 90-day timelock from block.timestamp.
    function submitRelease(uint256 amount) external;

    /// @notice Executes a matured release
    /// @dev Callable by anyone after availableAt. Transfers to ownerWallet — not msg.sender.
    ///      Reverts if frozen, no pending release, or timelock still active.
    function executeRelease() external;

    /// @notice Cancels a pending release before execution
    /// @dev ownerWallet only.
    ///      Silent no-op if frozen (wind-down already cancelled it).
    ///      Silent no-op if no pending release exists.
    function cancelRelease() external;

    // ── WIND-DOWN ─────────────────────────────────────────────────────────────

    /// @notice Freezes treasury and cancels any pending release silently
    /// @dev WindDownController only. Called at wind-down initiation.
    ///      Does NOT emit ReleaseCancelled — TreasuryFrozen is sufficient signal.
    function freeze() external;

    /// @notice Burns entire treasury balance
    /// @dev WindDownController only. Called at expiry step. No-op if balance == 0.
    function burnUnclaimed() external;

    // ── VIEWS ─────────────────────────────────────────────────────────────────

    function getPendingRelease() external view returns (PendingRelease memory);
    function hasPendingRelease() external view returns (bool);
    function isFrozen() external view returns (bool);
    function balance() external view returns (uint256);
    function timeUntilRelease() external view returns (uint256);
    function ownerWallet() external view returns (address);
    function TIMELOCK_DURATION() external view returns (uint256);
}
