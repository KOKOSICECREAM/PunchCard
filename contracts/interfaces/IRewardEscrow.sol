// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRewardEscrow
interface IRewardEscrow {

    // ── STRUCTS ───────────────────────────────────────────────────────────────

    /// @notice One kiosk's till. Replenishes continuously up to `dailyAllowance`.
    struct Drawer {
        uint128 dailyAllowance;
        uint128 spent;        // decayed against elapsed time on every read
        uint64  lastDraw;
        bool    active;
    }

    // ── EVENTS ────────────────────────────────────────────────────────────────

    event RewardDistributed(address indexed token, address indexed operator, address indexed recipient, uint256 amount, uint256 timestamp);
    event OperatorAdded(address indexed operator, uint256 dailyAllowance, uint256 timestamp);
    event OperatorRemoved(address indexed operator, uint256 timestamp);
    event DrawerAllowanceSet(address indexed operator, uint256 dailyAllowance, uint256 timestamp);
    event EscrowPaused(uint256 until_, uint256 timestamp);
    event EscrowUnpaused(uint256 timestamp);
    event PerTxBoundsSet(uint256 floor_, uint256 max_, uint256 timestamp);
    event RewardPoolLow(address indexed token, uint256 remaining, uint256 threshold, uint256 timestamp);
    event EscrowFrozen(address indexed token, uint256 timestamp);
    event EscrowBurned(address indexed token, uint256 amount, uint256 timestamp);

    // ── WIND-DOWN ─────────────────────────────────────────────────────────────

    function freeze() external;
    function burnRemaining() external;
    function isFrozen() external view returns (bool);

    // ── DISTRIBUTION ──────────────────────────────────────────────────────────

    function distributeReward(address recipient, uint256 amount) external;

    // ── OWNER CONTROLS ────────────────────────────────────────────────────────

    function addOperator(address operator, uint256 dailyAllowance) external;
    function removeOperator(address operator) external;
    function setDrawerAllowance(address operator, uint256 dailyAllowance) external;
    function setPerTxBounds(uint256 floor_, uint256 max_) external;
    function pause() external;
    function unpause() external;

    // ── VIEWS ─────────────────────────────────────────────────────────────────

    function emitted() external view returns (uint256);
    function spendable() external view returns (uint256);
    function drawerAvailable(address operator) external view returns (uint256);
    function getDrawer(address operator) external view returns (Drawer memory);
    function totalDistributed() external view returns (uint256);
    function pausedUntil() external view returns (uint256);
    function ownerWallet() external view returns (address);
}
