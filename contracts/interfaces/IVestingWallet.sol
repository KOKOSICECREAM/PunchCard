// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IVestingWallet {

    // ── EVENTS ───────────────────────────────────────────────────────────────

    event TokensReleased(
        address indexed merchantToken,
        address indexed teamWallet,
        uint256 amount,
        uint256 timestamp
    );

    event VestingSettled(
        address indexed merchantToken,
        uint256 vestedToTeam,
        uint256 burned,
        uint256 timestamp
    );

    // ── OPERATIONAL ───────────────────────────────────────────────────────────

    /// @notice Transfers any newly vested tokens to teamWallet
    /// @dev Callable by anyone.
    ///      Silent no-op if cliff not yet reached.
    ///      Silent no-op if nothing newly vested since last release.
    ///      Zero emissions suppressed — event only emits on meaningful transfer.
    ///      Stays live through wind-down — team retains access to vested tokens.
    function release() external;

    // ── WIND-DOWN ─────────────────────────────────────────────────────────────

    /// @notice Final settlement — vested remainder to teamWallet, unvested burned
    /// @dev WindDownController only.
    ///      vestedToTeam = totalVested() - released (may be 0)
    ///      burned = balanceOf(this) - vestedToTeam (actual balance, not math-derived)
    ///      Emits VestingSettled with both amounts regardless (zeros valid).
    ///      After this call the contract holds no tokens.
    function settleAndBurn() external;

    // ── VIEWS ─────────────────────────────────────────────────────────────────

    /// @notice Returns total tokens vested to date based on block.timestamp
    /// @dev Returns 0 if cliff not reached. Linear from cliff to vestingEnd.
    ///      Caps at total allocation once fully vested.
    function totalVested() external view returns (uint256);

    /// @notice Returns tokens not yet earned
    /// @dev NOTE: This is tokens not yet earned (totalAllocation - totalVested()),
    ///      NOT tokens earned but unclaimed. See released() for unclaimed vested tokens.
    function unvested() external view returns (uint256);

    /// @notice Returns tokens already transferred to teamWallet
    function released() external view returns (uint256);

    /// @notice Returns true if cliff has been reached
    function cliffReached() external view returns (bool);

    function vestingStart() external view returns (uint256);
    function cliffTime() external view returns (uint256);
    function vestingEnd() external view returns (uint256);
    function teamWallet() external view returns (address);
    function CLIFF_DURATION() external view returns (uint256);
    function VEST_DURATION() external view returns (uint256);
}
