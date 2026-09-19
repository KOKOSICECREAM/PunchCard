// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The one call a factory makes to start a staged suite's clocks.
interface IActivatable {
    function activate() external;
    function activatedAt() external view returns (uint256);
    function isActivated() external view returns (bool);
}

/// @title Activatable — a suite contract's clock starts when the merchant goes live
///
/// @notice Every schedule in a merchant suite used to start in its constructor, which was
///         correct only because construction and going live were the same instant:
///         `TokenFactory.deploy()` did everything in one transaction.
///
///         That transaction no longer fits on Base — 17,011,396 gas against a 16,777,216
///         ceiling — so deployment has to be staged, and construction stops coinciding with
///         activation. Left alone, a suite staged on Monday and activated on Friday would
///         open with four days of emission already accrued and four days already served
///         against the team cliff. Nobody would have decided that; it would simply be what
///         the old code did in a world it was not written for.
///
///         So the clock is explicit. A suite is deployed **inert**, and `activate()` — the
///         last step of going live — starts everything at the same instant:
///
///             merchant goes live -> rewards begin
///             merchant goes live -> team cliff begins
///             merchant goes live -> treasury clock begins
///
/// @dev One-way and callable once, by the factory that built the suite. There is no
///      deactivate: a schedule that could be stopped and restarted is a schedule the
///      merchant cannot rely on, which is the opposite of what these contracts are for.
abstract contract Activatable {

    /// @notice The factory that staged this suite, and the only address that may start it.
    address public immutable activator;

    /// @notice Timestamp the merchant went live. Zero until then — every schedule in the
    ///         suite is measured from this, so zero means "no time has passed yet".
    uint256 public activatedAt;

    event Activated(address indexed by, uint256 timestamp);

    constructor(address _activator) {
        require(_activator != address(0), "Invalid activator");
        activator = _activator;
    }

    modifier onlyActivator() {
        require(msg.sender == activator, "Not activator");
        _;
    }

    /// @dev For the operations that must not work on a staged-but-not-live suite. Reads
    ///      state rather than calling out to anything, so an inert suite cannot be bricked
    ///      by whatever happens to the factory afterwards.
    modifier whenActivated() {
        require(activatedAt != 0, "Not activated");
        _;
    }

    /// @notice Start every schedule in this contract. One-way, once, factory only.
    function activate() external onlyActivator {
        require(activatedAt == 0, "Already activated");
        activatedAt = block.timestamp;
        emit Activated(msg.sender, block.timestamp);
    }

    function isActivated() public view returns (bool) {
        return activatedAt != 0;
    }
}
