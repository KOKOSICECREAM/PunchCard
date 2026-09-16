// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IRewardEscrow.sol";
import "./Activatable.sol";

/// @title RewardEscrow
/// @notice Holds a merchant's reward pool and meters it out through two independent
///         limits: a long-run emission schedule, and a per-kiosk till.
///
/// @dev Two limits, two different jobs.
///
///      **Emission — protects the supply.** The allocation unlocks continuously over
///      EMISSION_PERIOD. Only unlocked tokens can be spent, and what is spendable at any
///      instant is capped at BUFFER_DAYS of emission. A merchant who underspends does not
///      forfeit anything: the unspent remainder stays claimable and simply extends the
///      programme past the nominal period. A merchant who wants to spend faster cannot.
///
///      That is also the answer to token price moving. If the token appreciates, fewer
///      tokens are needed per reward, the merchant underspends, and the programme runs
///      longer — automatically, with no oracle. If it falls, they hit the ceiling and must
///      reward less generously, which is the protocol protecting the supply. Pricing the
///      reward in USD on-chain was the alternative and is unsafe here: launch pools are
///      $5,000, thin enough that a TWAP of the merchant's own token can be pushed cheaply
///      by anyone who wants more tokens per dollar of reward.
///
///      **Drawers — cap theft.** Each kiosk is a separate operator with its own till,
///      replenishing continuously up to a daily allowance. A leaked point-of-sale key
///      costs at most one drawer per day until the merchant removes it, exactly like a
///      cash drawer. There is no shared pot for one compromised till to drain.
///
///      Everything the owner can do is rate-limiting or halting. No function here moves
///      tokens to an address the caller chooses except distributeReward, which is bounded
///      by both limits above.
contract RewardEscrow is IRewardEscrow, Activatable, ReentrancyGuard {

    using SafeERC20 for IERC20;

    // ── SCHEDULE CONSTANTS ────────────────────────────────────────────────────

    /// @notice Reward allocation unlocks over five years
    uint256 public constant EMISSION_PERIOD = 1825 days;

    /// @notice Most that can be spendable at once, in days of emission.
    /// @dev Lets a quiet month bank capacity for a busy one without letting the whole
    ///      allocation become drainable.
    uint256 public constant BUFFER_DAYS = 30;

    /// @notice Default kiosk till at deploy, in days of emission
    uint256 public constant DEFAULT_DRAWER_DAYS = 2;

    /// @notice Ceiling on any single till, in days of emission.
    /// @dev Defence in depth: a compromised owner key still cannot open an unlimited till.
    uint256 public constant MAX_DRAWER_DAYS = 14;

    /// @notice A pause lapses on its own after this long unless renewed.
    /// @dev So a lost owner key cannot brick a programme permanently.
    uint256 public constant MAX_PAUSE = 7 days;

    // ── IMMUTABLES ────────────────────────────────────────────────────────────

    IERC20  public immutable token;
    address public immutable override ownerWallet;
    address public immutable windDownController;

    /// @notice Total rewards allocation this schedule emits
    uint256 public immutable REWARDS_ALLOCATION;

    /// @notice Emission per day, and the derived ceilings
    uint256 public immutable emissionPerDay;
    uint256 public immutable bufferCap;
    uint256 public immutable maxDrawer;

    // ── STATE ─────────────────────────────────────────────────────────────────

    uint256 public override totalDistributed;
    uint256 public perTxFloor;
    uint256 public perTxMax;
    uint256 public override pausedUntil;
    uint256 public lowThreshold;

    mapping(address => Drawer) private _drawers;

    bool private _frozen;

    // ── CONSTRUCTOR ───────────────────────────────────────────────────────────

    constructor(
        address _token,
        address _initialOperator,
        address _ownerWallet,
        address _windDownController,
        uint256 _rewardsAllocation,
        uint256 _perTxFloor,
        uint256 _perTxMax,
        address _activator
    ) Activatable(_activator) {
        require(_token              != address(0), "Invalid token");
        require(_initialOperator    != address(0), "Invalid operator");
        require(_ownerWallet        != address(0), "Invalid owner");
        require(_windDownController != address(0), "Invalid controller");
        require(_rewardsAllocation   > 0,          "Invalid allocation");

        token              = IERC20(_token);
        ownerWallet        = _ownerWallet;
        windDownController = _windDownController;
        REWARDS_ALLOCATION = _rewardsAllocation;
        // Emission starts at activate(), not here — see Activatable.

        uint256 perDay = (_rewardsAllocation * 1 days) / EMISSION_PERIOD;
        // Drawer bookkeeping is uint128. The bound holds comfortably for any sane
        // allocation, but assert it rather than reason about it — a silent truncation in
        // `spent` would hand an operator an unbounded till.
        require(perDay * MAX_DRAWER_DAYS <= type(uint128).max, "Drawer ceiling exceeds uint128");
        emissionPerDay = perDay;
        bufferCap      = perDay * BUFFER_DAYS;
        maxDrawer      = perDay * MAX_DRAWER_DAYS;

        require(_perTxFloor > 0,                "Invalid floor");
        require(_perTxMax  >= _perTxFloor,      "Max below floor");
        require(_perTxMax  <= perDay * MAX_DRAWER_DAYS, "Max above drawer ceiling");
        perTxFloor = _perTxFloor;
        perTxMax   = _perTxMax;

        lowThreshold = _rewardsAllocation / 10;

        // The first kiosk, so onboarding stays a single transaction.
        _drawers[_initialOperator] = Drawer({
            dailyAllowance: uint128(perDay * DEFAULT_DRAWER_DAYS),
            spent:          0,
            lastDraw:       uint64(block.timestamp),
            active:         true
        });
        emit OperatorAdded(_initialOperator, perDay * DEFAULT_DRAWER_DAYS, block.timestamp);
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
        require(!_frozen, "Frozen");
        _;
    }

    modifier active() {
        require(activatedAt != 0,                "Not activated");
        require(!_frozen,                        "Frozen");
        require(block.timestamp >= pausedUntil,  "Paused");
        _;
    }

    // ── EMISSION ──────────────────────────────────────────────────────────────

    /// @notice When emission began: the instant the merchant went live, or 0 while staged.
    /// @dev Kept as an accessor because it was a public immutable before staging existed,
    ///      so anything reading it off-chain keeps working.
    function emissionStart() public view returns (uint256) {
        return activatedAt;
    }

    /// @inheritdoc IRewardEscrow
    /// @dev Zero until activation. A suite that sat staged for a month must not open with a
    ///      month of rewards already unlocked — bufferCap is 30 days of emission, so that
    ///      would have opened the escrow at its full spendable ceiling on day one.
    function emitted() public view override returns (uint256) {
        if (activatedAt == 0) return 0;
        uint256 elapsed = block.timestamp - activatedAt;
        if (elapsed >= EMISSION_PERIOD) return REWARDS_ALLOCATION;
        return (REWARDS_ALLOCATION * elapsed) / EMISSION_PERIOD;
    }

    /// @inheritdoc IRewardEscrow
    /// @dev Unspent emission is never forfeited — it stays in this figure and keeps the
    ///      programme running past EMISSION_PERIOD. The buffer only rate-limits it.
    function spendable() public view override returns (uint256) {
        uint256 unspent = emitted() - totalDistributed;
        uint256 capped  = unspent < bufferCap ? unspent : bufferCap;
        uint256 held    = token.balanceOf(address(this));
        return capped < held ? capped : held;
    }

    // ── DRAWERS ───────────────────────────────────────────────────────────────

    /// @inheritdoc IRewardEscrow
    function drawerAvailable(address operator) public view override returns (uint256) {
        Drawer memory d = _drawers[operator];
        if (!d.active) return 0;
        uint256 outstanding = _outstanding(d);
        return d.dailyAllowance > outstanding ? d.dailyAllowance - outstanding : 0;
    }

    /// @dev Spend decays linearly back to zero over a day — a continuously refilling till
    ///      rather than a midnight reset, so there is no boundary to game.
    function _outstanding(Drawer memory d) private view returns (uint256) {
        uint256 elapsed     = block.timestamp - d.lastDraw;
        uint256 replenished = (elapsed * d.dailyAllowance) / 1 days;
        return d.spent > replenished ? d.spent - replenished : 0;
    }

    // ── DISTRIBUTION ──────────────────────────────────────────────────────────

    /// @inheritdoc IRewardEscrow
    function distributeReward(address recipient, uint256 amount)
        external
        override
        active
        nonReentrant
    {
        Drawer storage d = _drawers[msg.sender];
        require(d.active,                "Not an operator");
        require(recipient != address(0), "Invalid recipient");
        require(amount >= perTxFloor,    "Below floor");
        require(amount <= perTxMax,      "Exceeds per-tx max");

        uint256 outstanding = _outstanding(d);
        require(outstanding + amount <= d.dailyAllowance, "Drawer empty");
        require(amount <= spendable(),                    "Emission limit");

        d.spent    = uint128(outstanding + amount);
        d.lastDraw = uint64(block.timestamp);
        totalDistributed += amount;

        token.safeTransfer(recipient, amount);
        emit RewardDistributed(address(token), msg.sender, recipient, amount, block.timestamp);

        uint256 remaining = REWARDS_ALLOCATION - totalDistributed;
        if (lowThreshold > 0 && remaining <= lowThreshold) {
            emit RewardPoolLow(address(token), remaining, lowThreshold, block.timestamp);
        }
    }

    // ── OWNER CONTROLS ────────────────────────────────────────────────────────
    // Every one of these rate-limits or halts. None of them moves a token.

    /// @inheritdoc IRewardEscrow
    function addOperator(address operator, uint256 dailyAllowance) external override onlyOwner notFrozen {
        require(operator != address(0),          "Invalid operator");
        require(!_drawers[operator].active,      "Already an operator");
        require(dailyAllowance > 0,              "Invalid allowance");
        require(dailyAllowance <= maxDrawer,     "Above drawer ceiling");

        _drawers[operator] = Drawer({
            dailyAllowance: uint128(dailyAllowance),
            spent:          0,
            lastDraw:       uint64(block.timestamp),
            active:         true
        });
        emit OperatorAdded(operator, dailyAllowance, block.timestamp);
    }

    /// @inheritdoc IRewardEscrow
    /// @dev The response to a leaked kiosk key. Takes effect immediately.
    function removeOperator(address operator) external override onlyOwner {
        require(_drawers[operator].active, "Not an operator");
        delete _drawers[operator];
        emit OperatorRemoved(operator, block.timestamp);
    }

    /// @inheritdoc IRewardEscrow
    /// @dev Raising an allowance does not refill a till that is already drawn down —
    ///      `spent` is untouched, so this cannot be used to bypass the current day.
    function setDrawerAllowance(address operator, uint256 dailyAllowance) external override onlyOwner notFrozen {
        require(_drawers[operator].active,   "Not an operator");
        require(dailyAllowance > 0,          "Invalid allowance");
        require(dailyAllowance <= maxDrawer, "Above drawer ceiling");

        Drawer storage d = _drawers[operator];
        d.spent    = uint128(_outstanding(d));
        d.lastDraw = uint64(block.timestamp);
        d.dailyAllowance = uint128(dailyAllowance);
        emit DrawerAllowanceSet(operator, dailyAllowance, block.timestamp);
    }

    /// @inheritdoc IRewardEscrow
    /// @dev Both bounds are adjustable because both are denominated in tokens, and what a
    ///      token is worth moves. A fixed floor set at launch becomes a $1 minimum reward
    ///      if the token appreciates a hundredfold.
    function setPerTxBounds(uint256 floor_, uint256 max_) external override onlyOwner notFrozen {
        require(floor_ > 0,          "Invalid floor");
        require(max_  >= floor_,     "Max below floor");
        require(max_  <= maxDrawer,  "Max above drawer ceiling");
        perTxFloor = floor_;
        perTxMax   = max_;
        emit PerTxBoundsSet(floor_, max_, block.timestamp);
    }

    /// @inheritdoc IRewardEscrow
    /// @dev Halt-only, and it lapses by itself. Nothing here can redirect a token.
    function pause() external override onlyOwner {
        pausedUntil = block.timestamp + MAX_PAUSE;
        emit EscrowPaused(pausedUntil, block.timestamp);
    }

    /// @inheritdoc IRewardEscrow
    function unpause() external override onlyOwner {
        pausedUntil = 0;
        emit EscrowUnpaused(block.timestamp);
    }

    function setLowThreshold(uint256 newThreshold) external onlyOwner {
        lowThreshold = newThreshold;
    }

    // ── WIND-DOWN ─────────────────────────────────────────────────────────────

    /// @inheritdoc IRewardEscrow
    function freeze() external override onlyWindDown {
        _frozen = true;
        emit EscrowFrozen(address(token), block.timestamp);
    }

    /// @inheritdoc IRewardEscrow
    function burnRemaining() external override onlyWindDown {
        uint256 bal = token.balanceOf(address(this));
        if (bal > 0) {
            ERC20Burnable(address(token)).burn(bal);
            emit EscrowBurned(address(token), bal, block.timestamp);
        }
    }

    /// @inheritdoc IRewardEscrow
    function isFrozen() external view override returns (bool) {
        return _frozen;
    }

    // ── VIEWS ─────────────────────────────────────────────────────────────────

    /// @inheritdoc IRewardEscrow
    function getDrawer(address operator) external view override returns (Drawer memory) {
        return _drawers[operator];
    }
}
