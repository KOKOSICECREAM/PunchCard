// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRewardEscrow {

    // ── STRUCTS ──────────────────────────────────────────────────────────────

    struct EscrowState {
        uint256 dailyBalance;
        uint256 lastRefillTime;
        uint256 perTxMax;
        bool frozen;
    }

    // ── EVENTS ───────────────────────────────────────────────────────────────

    event EscrowRefilled(
        address indexed merchantToken,
        uint256 amount,
        uint256 newDailyBalance,
        uint256 timestamp
    );

    event RewardDistributed(
        address indexed merchantToken,
        address indexed recipient,
        uint256 amount,
        uint256 timestamp
    );

    event EscrowFrozen(
        address indexed merchantToken,
        uint256 timestamp
    );

    event EscrowBurned(
        address indexed merchantToken,
        uint256 amount,
        uint256 timestamp
    );

    event PerTxMaxUpdated(
        address indexed merchantToken,
        uint256 oldMax,
        uint256 newMax,
        uint256 timestamp
    );

    /// @notice Emitted when main reward pool drops below the low threshold
    /// @dev Signals merchant to plan ahead — issue new token or wind down
    ///      Emitted at most once per refill cycle to avoid spam
    event RewardPoolLow(
        address indexed merchantToken,
        uint256 mainPoolBalance,
        uint256 threshold,
        uint256 timestamp
    );

    // ── WIND-DOWN ─────────────────────────────────────────────────────────────

    /// @notice Freezes reward distribution and refill permanently
    /// @dev WindDownController only. Called at wind-down initiation.
    function freeze() external;

    /// @notice Burns entire contract balance
    /// @dev WindDownController only. Called at expiry step. No-op if balance == 0.
    function burnRemaining() external;

    // ── REFILL ────────────────────────────────────────────────────────────────

    /// @notice Tops up daily escrow from main reward pool
    /// @dev Callable by anyone. 24hr cooldown enforced on-chain.
    ///      Cooldown only advances on meaningful refill (refillAmount > 0).
    ///      No-op if already at cap or main pool exhausted — does not revert.
    function refill() external;

    // ── DISTRIBUTION ──────────────────────────────────────────────────────────

    /// @notice Distributes reward to customer wallet
    /// @dev Operator only. Reverts if frozen, below floor, above perTxMax, or above dailyBalance.
    function distributeReward(address recipient, uint256 amount) external;

    // ── CONFIGURATION ─────────────────────────────────────────────────────────

    /// @notice Updates per-transaction maximum
    /// @dev ownerWallet only. Must be within [PER_TX_FLOOR, DAILY_CAP].
    function setPerTxMax(uint256 newMax) external;

    // ── VIEWS ─────────────────────────────────────────────────────────────────

    /// @notice Updates the low pool warning threshold
    /// @dev ownerWallet only. Set to 0 to disable warnings.
    function setLowThreshold(uint256 newThreshold) external;

    function getState() external view returns (EscrowState memory);
    function isFrozen() external view returns (bool);
    function dailyBalance() external view returns (uint256);
    function lastRefillTime() external view returns (uint256);
    function perTxMax() external view returns (uint256);
    function timeUntilRefill() external view returns (uint256);
    function mainPoolBalance() external view returns (uint256);
    function lowThreshold() external view returns (uint256);
    function DAILY_CAP() external view returns (uint256);
    function PER_TX_FLOOR() external view returns (uint256);
    function operator() external view returns (address);
    function ownerWallet() external view returns (address);
}
