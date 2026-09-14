// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/ITreasuryTimelock.sol";

/// @title TreasuryTimelock
/// @notice Merchant treasury with 90-day autonomous release timelock.
/// @dev Deployed per merchant by factory. All addresses immutable after deploy.
///      Merchant-initiated, fully autonomous — PunchCard has no custody or veto.
///      Wind-down freezes treasury and cancels any pending release silently.
///      executeRelease() transfers to ownerWallet — not msg.sender.
///      Sequencing guarantee: freeze() always fires before burnUnclaimed(),
///      so no pending release can survive to executeRelease() with insufficient balance.
contract TreasuryTimelock is ITreasuryTimelock, ReentrancyGuard {

    using SafeERC20 for IERC20;

    // ── IMMUTABLES ────────────────────────────────────────────────────────────

    IERC20 public immutable token;

    /// @notice Merchant wallet — submits releases, receives executed releases
    address public immutable override ownerWallet;

    /// @notice WindDownController — sole caller of freeze() and burnUnclaimed()
    address public immutable windDownController;

    /// @notice 90 days, set by factory
    uint256 public immutable override TIMELOCK_DURATION;

    // ── STATE ─────────────────────────────────────────────────────────────────

    PendingRelease private _pending;
    bool public override isFrozen;

    // ── CONSTRUCTOR ───────────────────────────────────────────────────────────

    constructor(
        address _token,
        address _ownerWallet,
        address _windDownController,
        uint256 _timelockDuration
    ) {
        require(_token              != address(0), "Invalid token");
        require(_ownerWallet        != address(0), "Invalid owner");
        require(_windDownController != address(0), "Invalid controller");
        require(_timelockDuration    > 0,          "Invalid duration");

        token              = IERC20(_token);
        ownerWallet        = _ownerWallet;
        windDownController = _windDownController;
        TIMELOCK_DURATION  = _timelockDuration;
    }

    // ── MODIFIERS ─────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == ownerWallet, "Not owner");
        _;
    }

    modifier onlyWindDown() {
        require(msg.sender == windDownController, "Not controller");
        _;
    }

    modifier notFrozen() {
        require(!isFrozen, "Frozen");
        _;
    }

    // ── OPERATIONAL ───────────────────────────────────────────────────────────

    /// @inheritdoc ITreasuryTimelock
    function submitRelease(uint256 amount)
        external
        onlyOwner
        notFrozen
    {
        require(amount > 0,                                    "Zero amount");
        require(_pending.amount == 0,                          "Release pending");
        require(amount <= token.balanceOf(address(this)),      "Insufficient balance");

        uint256 availableAt = block.timestamp + TIMELOCK_DURATION;

        _pending = PendingRelease({
            amount:      amount,
            submittedAt: block.timestamp,
            availableAt: availableAt
        });

        emit ReleaseSubmitted(address(token), amount, availableAt, block.timestamp);
    }

    /// @inheritdoc ITreasuryTimelock
    /// @dev Callable by anyone. Transfers to ownerWallet — NOT msg.sender.
    ///      Submission-time balance check is sufficient — freeze() guarantees
    ///      no pending release survives to this point with insufficient balance.
    function executeRelease() external notFrozen nonReentrant {
        require(_pending.amount > 0,                       "No pending release");
        require(block.timestamp >= _pending.availableAt,   "Timelock active");

        uint256 amount = _pending.amount;

        // CEI — clear state before transfer
        delete _pending;

        token.safeTransfer(ownerWallet, amount);
        emit ReleaseExecuted(address(token), amount, block.timestamp);
    }

    /// @inheritdoc ITreasuryTimelock
    /// @dev Silent no-op if frozen (wind-down already cancelled it).
    ///      Silent no-op if nothing to cancel.
    ///      Does NOT emit ReleaseCancelled on no-op — zero-amount events are noise.
    function cancelRelease() external onlyOwner {
        if (isFrozen) return;
        if (_pending.amount == 0) return;

        uint256 amount = _pending.amount;
        delete _pending;

        emit ReleaseCancelled(address(token), amount, block.timestamp);
    }

    // ── WIND-DOWN ─────────────────────────────────────────────────────────────

    /// @inheritdoc ITreasuryTimelock
    /// @dev Cancels pending release silently — no ReleaseCancelled event.
    ///      TreasuryFrozen is the only signal. Emitting ReleaseCancelled here
    ///      would imply merchant-initiated cancellation, which is incorrect.
    function freeze() external onlyWindDown {
        isFrozen = true;

        if (_pending.amount > 0) {
            delete _pending;
        }

        emit TreasuryFrozen(address(token), block.timestamp);
    }

    /// @inheritdoc ITreasuryTimelock
    function burnUnclaimed() external onlyWindDown {
        uint256 bal = token.balanceOf(address(this));
        if (bal == 0) return;

        ERC20Burnable(address(token)).burn(bal);
        emit TreasuryBurned(address(token), bal, block.timestamp);
    }

    // ── VIEWS ─────────────────────────────────────────────────────────────────

    function getPendingRelease() external view returns (PendingRelease memory) {
        return _pending;
    }

    function hasPendingRelease() external view returns (bool) {
        return _pending.amount > 0;
    }

    function balance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function timeUntilRelease() external view returns (uint256) {
        if (_pending.amount == 0) return 0;
        if (block.timestamp >= _pending.availableAt) return 0;
        return _pending.availableAt - block.timestamp;
    }
}
