// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IRewardEscrow.sol";

/// @title RewardEscrow
/// @notice Holds merchant reward pool. Manages daily distribution bucket.
/// @dev Deployed per merchant by factory. All addresses immutable after deploy.
///      Internal accounting only — no token transfer occurs on refill.
///      Main pool = balanceOf(this) - dailyBalance (implicit, never stored separately).
///      burnRemaining() burns total contract balance regardless of internal buckets.
contract RewardEscrow is IRewardEscrow, ReentrancyGuard {

    // ── IMMUTABLES ────────────────────────────────────────────────────────────

    IERC20 public immutable token;

    /// @notice Authorized reward distributor — merchant's POS signer
    address public immutable override operator;

    /// @notice Merchant wallet — controls perTxMax
    address public immutable override ownerWallet;

    /// @notice WindDownController — sole caller of freeze() and burnRemaining()
    address public immutable windDownController;

    /// @notice Hard ceiling on daily escrow bucket — 500,000 tokens network default
    uint256 public immutable override DAILY_CAP;

    /// @notice Minimum reward per transaction in tokens
    /// @dev Set at deploy time from $0.01 / tokenPriceUSD. No oracle dependency.
    ///      Generous by design — prevents dust/zero distributions, not precise USD enforcement.
    uint256 public immutable override PER_TX_FLOOR;

    // ── STATE ─────────────────────────────────────────────────────────────────

    /// @notice Current daily distribution bucket
    /// @dev Main pool is implicit: balanceOf(this) - dailyBalance
    uint256 public override dailyBalance;

    /// @notice Timestamp of last meaningful refill (refillAmount > 0)
    uint256 public override lastRefillTime;

    /// @notice Per-transaction maximum in tokens — configurable by ownerWallet
    uint256 public override perTxMax;

    /// @notice True after WindDownController calls freeze()
    bool private _frozen;

    /// @notice Main pool balance below which RewardPoolLow is emitted
    /// @dev Set by ownerWallet. Default 10% of REWARDS_ALLOC at deploy.
    ///      Set to 0 to disable warnings entirely.
    uint256 public lowThreshold;

    /// @notice Guards against emitting RewardPoolLow multiple times per refill
    bool private _lowWarningEmitted;

    // ── CONSTRUCTOR ───────────────────────────────────────────────────────────

    constructor(
        address _token,
        address _operator,
        address _ownerWallet,
        address _windDownController,
        uint256 _dailyCap,
        uint256 _perTxFloor,
        uint256 _perTxMax
    ) {
        require(_token              != address(0), "Invalid token");
        require(_operator           != address(0), "Invalid operator");
        require(_ownerWallet        != address(0), "Invalid owner");
        require(_windDownController != address(0), "Invalid controller");
        require(_dailyCap            > 0,           "Invalid cap");
        require(_perTxFloor          > 0,           "Invalid floor");
        require(_perTxFloor         <= _dailyCap,   "Floor above cap");
        require(_perTxMax           >= _perTxFloor, "Max below floor");
        require(_perTxMax           <= _dailyCap,   "Max above cap");

        token              = IERC20(_token);
        operator           = _operator;
        ownerWallet        = _ownerWallet;
        windDownController = _windDownController;
        DAILY_CAP          = _dailyCap;
        PER_TX_FLOOR       = _perTxFloor;
        perTxMax           = _perTxMax;

        // Default low threshold: 10% of total rewards allocation
        // Factory passes this in or merchant can update via setLowThreshold()
        lowThreshold = _dailyCap * 50; // ~5M tokens at default cap — roughly 10% of 45M
    }

    // ── MODIFIERS ─────────────────────────────────────────────────────────────

    modifier onlyOperator() {
        require(msg.sender == operator, "Not operator");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == ownerWallet, "Not owner");
        _;
    }

    modifier onlyWindDown() {
        require(msg.sender == windDownController, "Not controller");
        _;
    }

    modifier notFrozen() {
        require(!_frozen, "Frozen");
        _;
    }

    // ── WIND-DOWN ─────────────────────────────────────────────────────────────

    /// @inheritdoc IRewardEscrow
    /// @dev Also disables refill — no point topping up a frozen escrow.
    function freeze() external onlyWindDown {
        _frozen = true;
        emit EscrowFrozen(address(token), block.timestamp);
    }

    /// @inheritdoc IRewardEscrow
    /// @dev Burns entire contract balance — internal bucket accounting ignored.
    ///      No-op if balance == 0. Uses ERC20Burnable.burn() — consistent throughout suite.
    function burnRemaining() external onlyWindDown {
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) return;

        dailyBalance = 0;
        ERC20Burnable(address(token)).burn(balance);
        emit EscrowBurned(address(token), balance, block.timestamp);
    }

    // ── REFILL ────────────────────────────────────────────────────────────────

    /// @inheritdoc IRewardEscrow
    /// @dev Pure internal accounting — no token transfer occurs.
    ///      Cooldown only advances on meaningful refill (refillAmount > 0).
    ///      Grief attack closed: calling on full bucket costs gas, cooldown unchanged.
    function refill() external notFrozen {
        require(
            block.timestamp >= lastRefillTime + 24 hours,
            "Cooldown active"
        );

        uint256 totalBalance = token.balanceOf(address(this));
        uint256 mainPool     = totalBalance - dailyBalance;
        uint256 deficit      = DAILY_CAP - dailyBalance;
        uint256 refillAmount = deficit < mainPool ? deficit : mainPool;

        // No-op — cooldown does not advance
        if (refillAmount == 0) return;

        // Meaningful refill — advance cooldown and update bucket
        dailyBalance   += refillAmount;
        lastRefillTime  = block.timestamp;
        _lowWarningEmitted = false; // reset warning flag on successful refill

        emit EscrowRefilled(address(token), refillAmount, dailyBalance, block.timestamp);

        // Check if main pool has dropped below threshold after refill
        // Emit warning once per refill cycle — not on every distribution
        uint256 mainPoolAfter = token.balanceOf(address(this)) - dailyBalance;
        if (
            lowThreshold > 0 &&
            mainPoolAfter <= lowThreshold &&
            !_lowWarningEmitted
        ) {
            _lowWarningEmitted = true;
            emit RewardPoolLow(address(token), mainPoolAfter, lowThreshold, block.timestamp);
        }
    }

    // ── DISTRIBUTION ──────────────────────────────────────────────────────────

    /// @inheritdoc IRewardEscrow
    /// @dev CEI pattern — dailyBalance decremented before transfer.
    function distributeReward(address recipient, uint256 amount)
        external
        onlyOperator
        notFrozen
        nonReentrant
    {
        require(recipient != address(0), "Invalid recipient");
        require(amount >= PER_TX_FLOOR,  "Below floor");
        require(amount <= perTxMax,      "Exceeds per-tx max");
        require(amount <= dailyBalance,  "Exceeds daily balance");

        // CEI — decrement before transfer
        dailyBalance -= amount;

        token.transfer(recipient, amount);
        emit RewardDistributed(address(token), recipient, amount, block.timestamp);
    }

    // ── CONFIGURATION ─────────────────────────────────────────────────────────

    /// @inheritdoc IRewardEscrow
    function setPerTxMax(uint256 newMax) external onlyOwner {
        require(newMax >= PER_TX_FLOOR, "Below floor");
        require(newMax <= DAILY_CAP,    "Above cap");

        uint256 oldMax = perTxMax;
        perTxMax = newMax;

        emit PerTxMaxUpdated(address(token), oldMax, newMax, block.timestamp);
    }

    // ── CONFIGURATION (continued) ────────────────────────────────────────────

    /// @inheritdoc IRewardEscrow
    /// @dev Set to 0 to disable RewardPoolLow warnings entirely.
    function setLowThreshold(uint256 newThreshold) external onlyOwner {
        lowThreshold = newThreshold;
    }

    // ── VIEWS ─────────────────────────────────────────────────────────────────

    function isFrozen() external view override returns (bool) {
        return _frozen;
    }

    function getState() external view returns (EscrowState memory) {
        return EscrowState({
            dailyBalance:   dailyBalance,
            lastRefillTime: lastRefillTime,
            perTxMax:       perTxMax,
            frozen:         _frozen
        });
    }

    function timeUntilRefill() external view returns (uint256) {
        if (_frozen) return 0;
        uint256 nextRefill = lastRefillTime + 24 hours;
        if (block.timestamp >= nextRefill) return 0;
        return nextRefill - block.timestamp;
    }

    /// @notice Returns the current main pool balance (total balance minus daily bucket)
    function mainPoolBalance() external view returns (uint256) {
        uint256 total = token.balanceOf(address(this));
        return total > dailyBalance ? total - dailyBalance : 0;
    }
}
