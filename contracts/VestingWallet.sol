// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IVestingWallet.sol";

/// @title VestingWallet
/// @notice Linear vesting for team allocation with cliff.
/// @dev Deployed per merchant by factory. All addresses immutable after deploy.
///      release() stays live through wind-down — team retains access to vested tokens.
///      settleAndBurn() is terminal — called by WindDownController at expiry.
///      totalAllocation derived as balanceOf(this) + released — never stored,
///      more accurate than a constant if any unexpected token movement occurred.
///      CEI pattern enforced on all fund movements.
contract VestingWallet is IVestingWallet, ReentrancyGuard {

    // ── IMMUTABLES ────────────────────────────────────────────────────────────

    IERC20 public immutable token;

    /// @notice Team wallet — receives vested tokens on release() and settleAndBurn()
    /// @dev Immutable forever. No update function.
    ///      An updatable team wallet is an attack surface — a compromised multisig
    ///      could redirect vested tokens. Deployment errors caught in factory review.
    address public immutable override teamWallet;

    /// @notice WindDownController — sole caller of settleAndBurn()
    address public immutable windDownController;

    uint256 public immutable override CLIFF_DURATION;
    uint256 public immutable override VEST_DURATION;
    uint256 public immutable override vestingStart;
    uint256 public immutable override cliffTime;
    uint256 public immutable override vestingEnd;

    // ── STATE ─────────────────────────────────────────────────────────────────

    /// @notice Total tokens transferred to teamWallet across all release() calls
    uint256 public override released;

    // ── CONSTRUCTOR ───────────────────────────────────────────────────────────

    constructor(
        address _token,
        address _teamWallet,
        address _windDownController,
        uint256 _cliffDuration,
        uint256 _vestDuration
    ) {
        require(_token              != address(0), "Invalid token");
        require(_teamWallet         != address(0), "Invalid team wallet");
        require(_windDownController != address(0), "Invalid controller");
        require(_cliffDuration       > 0,          "Invalid cliff");
        require(_vestDuration        > 0,          "Invalid vest duration");

        token              = IERC20(_token);
        teamWallet         = _teamWallet;
        windDownController = _windDownController;
        CLIFF_DURATION     = _cliffDuration;
        VEST_DURATION      = _vestDuration;
        vestingStart       = block.timestamp;
        cliffTime          = block.timestamp + _cliffDuration;
        vestingEnd         = block.timestamp + _cliffDuration + _vestDuration;
    }

    // ── MODIFIERS ─────────────────────────────────────────────────────────────

    modifier onlyWindDown() {
        require(msg.sender == windDownController, "Not controller");
        _;
    }

    // ── OPERATIONAL ───────────────────────────────────────────────────────────

    /// @inheritdoc IVestingWallet
    /// @dev Callable by anyone. Silent no-op before cliff or when nothing newly vested.
    ///      Zero emissions suppressed — event only emits on meaningful transfer.
    ///      CEI: released updated before transfer.
    function release() external nonReentrant {
        if (block.timestamp < cliffTime) return;

        uint256 vested = totalVested();
        uint256 amount = vested - released;

        if (amount == 0) return;

        // CEI — update state before transfer
        released += amount;

        token.transfer(teamWallet, amount);
        emit TokensReleased(address(token), teamWallet, amount, block.timestamp);
    }

    // ── WIND-DOWN ─────────────────────────────────────────────────────────────

    /// @inheritdoc IVestingWallet
    /// @dev WindDownController only. Terminal.
    ///      totalHeld = balanceOf(this) — actual balance is source of truth over vesting math.
    ///      vestedToTeam = totalVested() - released (may be 0 if fully claimed or pre-cliff).
    ///      burned = totalHeld - vestedToTeam (everything not earned).
    ///      CEI: released updated before any transfer.
    ///      Emits VestingSettled with both amounts — zeros are valid and informative.
    function settleAndBurn() external onlyWindDown nonReentrant {
        uint256 totalHeld    = token.balanceOf(address(this));
        uint256 vestedToTeam = totalVested() - released;
        uint256 burned       = totalHeld - vestedToTeam;

        // CEI — update released before any transfer
        released += vestedToTeam;

        if (vestedToTeam > 0) {
            token.transfer(teamWallet, vestedToTeam);
        }

        if (burned > 0) {
            ERC20Burnable(address(token)).burn(burned);
        }

        emit VestingSettled(address(token), vestedToTeam, burned, block.timestamp);
    }

    // ── VIEWS ─────────────────────────────────────────────────────────────────

    /// @inheritdoc IVestingWallet
    /// @dev totalAllocation derived as balanceOf(this) + released — never stored.
    ///      Returns 0 before cliff. Linear from cliff to vestingEnd. Caps at total allocation.
    function totalVested() public view override returns (uint256) {
        if (block.timestamp < cliffTime) return 0;

        uint256 totalAllocation = token.balanceOf(address(this)) + released;

        if (block.timestamp >= vestingEnd) return totalAllocation;

        uint256 elapsed = block.timestamp - cliffTime;
        return (totalAllocation * elapsed) / VEST_DURATION;
    }

    /// @inheritdoc IVestingWallet
    /// @dev Returns tokens not yet earned (totalAllocation - totalVested()).
    ///      NOT the same as releasable (earned but unclaimed).
    ///      Releasable = totalVested() - released.
    function unvested() external view override returns (uint256) {
        uint256 totalAllocation = token.balanceOf(address(this)) + released;
        return totalAllocation - totalVested();
    }

    function cliffReached() external view override returns (bool) {
        return block.timestamp >= cliffTime;
    }
}
