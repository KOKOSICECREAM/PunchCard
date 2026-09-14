// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../LPLocker.sol";

/// @title LPLockerRehearsal — REHEARSAL ONLY. NEVER DEPLOY FOR A REAL MERCHANT.
/// @notice An LPLocker with a temporary, self-expiring LP evacuation hatch.
///
/// @dev **This contract breaks the core PunchCard promise on purpose.** Production
///      `LPLocker` has no withdrawal path at all: liquidity goes in and only wind-down,
///      365 days later, takes any of it out. That is the guarantee a merchant's customers
///      rely on, and it is why the production contract must never inherit from this one.
///
///      The hatch exists for exactly one situation: the first live deployment of unaudited
///      code, operated by PunchCard, where an unseen bug could otherwise strand real value
///      for a year. Wind-down is the only existing exit and it is a sledgehammer — 365
///      days, burns undistributed escrow, and cannot be reversed. This is the fire alarm.
///
///      Four guardrails, all deliberate:
///
///      1. **It expires by itself.** A manually-closed hatch can be left open forever
///         through neglect or intent, which is the trapdoor this was supposed to avoid.
///         `EVACUATION_WINDOW` closes it regardless of whether anyone acts.
///      2. **It closes early on demand.** `lockLP()` is one-way; once testing passes, call
///         it and the contract becomes equivalent to production.
///      3. **Evacuation is all-or-nothing.** Partial withdrawal means recomputing
///         `_reserveTokens` against liquidity that moved, which is precisely the
///         accounting that produced a merchant-token drain bug in this contract before.
///         An escape hatch is one unambiguous action, not a knob.
///      4. **It is loud.** `LPEvacuated` carries everything moved, and the contract is
///         permanently dead afterwards.
contract LPLockerRehearsal is LPLocker {

    using SafeERC20 for IERC20;

    /// @notice How long after deployment the hatch stays open, at most.
    uint256 public constant EVACUATION_WINDOW = 30 days;

    /// @notice Hard deadline. After this, evacuation is impossible whatever anyone does.
    uint256 public immutable evacuationDeadline;

    /// @notice Set by lockLP() or by evacuating. One-way, never cleared.
    bool public lpPermanentlyLocked;

    /// @dev Loud on purpose. Anyone watching this merchant should be able to see it.
    event LPEvacuated(
        address indexed to,
        uint256 usdcTokenId,
        uint256 ethTokenId,
        uint256 merchantTokens,
        uint256 usdc,
        uint256 weth,
        uint256 timestamp
    );
    event LPPermanentlyLocked(address indexed by, uint256 timestamp);

    constructor(
        address _merchantToken,
        address _ownerWallet,
        address _windDownController,
        address _positionManager,
        address _factory,
        address _usdc,
        address _weth,
        address _punchcardFeeRecipient
    ) LPLocker(
        _merchantToken, _ownerWallet, _windDownController, _positionManager,
        _factory, _usdc, _weth, _punchcardFeeRecipient
    ) {
        // Derived, not passed. A constructor argument could be set to a far-future date,
        // which would turn a 30-day hatch into a permanent one without anything looking
        // different at the call site.
        evacuationDeadline = block.timestamp + EVACUATION_WINDOW;
    }

    /// @notice True while liquidity can still be pulled. The dapp reads this to disclose
    ///         the state to buyers — an unlocked locker must never be presented as locked.
    function evacuationOpen() public view returns (bool) {
        return !lpPermanentlyLocked && block.timestamp < evacuationDeadline;
    }

    /// @notice Close the hatch early and permanently. One-way.
    /// @dev Callable by the merchant or by PunchCard's controller. Either may close it;
    ///      neither can reopen it.
    function lockLP() external {
        require(msg.sender == ownerWallet || msg.sender == windDownController, "Not authorised");
        require(!lpPermanentlyLocked, "Already locked");
        lpPermanentlyLocked = true;
        emit LPPermanentlyLocked(msg.sender, block.timestamp);
    }

    /// @notice Evacuate everything to ownerWallet and permanently brick this locker.
    /// @dev Withdraws all liquidity from both positions, collects everything owed, and
    ///      sends every token this contract holds to the merchant. The locker is dead
    ///      afterwards: `lpPermanentlyLocked` and `_frozen` are both set, so no further
    ///      liquidity can be added, no fees collected, and wind-down release is disabled.
    ///      There is no partial form and no undo.
    function evacuateLP() external nonReentrant {
        require(msg.sender == ownerWallet, "Not owner");
        require(evacuationOpen(), "Evacuation window closed");
        require(_usdcPosition.initialized, "Not initialized");
        require(!_usdcPosition.released,   "Already released");

        // CEI — dead before any external call.
        lpPermanentlyLocked   = true;
        _frozen               = true;
        _usdcPosition.released = true;
        _ethPosition.released  = true;

        INonfungiblePositionManager pm = INonfungiblePositionManager(positionManager);
        _drain(pm, _usdcPosition.tokenId);
        _drain(pm, _ethPosition.tokenId);

        uint256 tokenBal = IERC20(merchantToken).balanceOf(address(this));
        uint256 usdcBal  = IERC20(usdcAddress).balanceOf(address(this));
        uint256 wethBal  = IERC20(wethAddress).balanceOf(address(this));

        _reserveTokens = 0;

        if (tokenBal > 0) IERC20(merchantToken).safeTransfer(ownerWallet, tokenBal);
        if (usdcBal  > 0) IERC20(usdcAddress).safeTransfer(ownerWallet, usdcBal);
        if (wethBal  > 0) IERC20(wethAddress).safeTransfer(ownerWallet, wethBal);

        emit LPEvacuated(
            ownerWallet, _usdcPosition.tokenId, _ethPosition.tokenId,
            tokenBal, usdcBal, wethBal, block.timestamp
        );
    }

    /// @dev Pull 100% of a position's liquidity and sweep everything owed on it.
    function _drain(INonfungiblePositionManager pm, uint256 tokenId) private {
        (,,,,,,,uint128 liq,,,,) = pm.positions(tokenId);
        if (liq > 0) {
            pm.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId, liquidity: liq,
                    amount0Min: 0, amount1Min: 0, deadline: block.timestamp
                })
            );
        }
        pm.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: address(this),
                amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
    }
}
