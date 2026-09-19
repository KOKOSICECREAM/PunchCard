// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/RewardEscrow.sol";
import "../contracts/VestingWallet.sol";
import "../contracts/TreasuryTimelock.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract ATok is ERC20, ERC20Burnable {
    constructor() ERC20("A", "A") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// @title A staged suite carries no elapsed time
///
/// @notice `deploy()` is 17,011,396 gas against Base's 16,777,216 per-transaction ceiling,
///         so deployment has to be staged and construction stops coinciding with going
///         live. Every schedule in a merchant suite used to start in its constructor, which
///         was only ever correct because those were the same instant.
///
///         Left alone, a suite staged on Monday and activated on Friday would open with
///         four days of emission already accrued and four days served against the team
///         cliff. Nobody would have decided that — it is what the old code does in a world
///         it was not written for. These tests are what stops it coming back.
contract ActivationTest is Test {
    ATok token;
    RewardEscrow     escrow;
    VestingWallet    vesting;
    TreasuryTimelock treasury;

    address constant OWNER = address(0xB1);
    address constant TEAM  = address(0xB2);
    address constant OP    = address(0xB3);
    address constant WDC   = address(0xDD);

    uint256 constant REWARDS = 45_000_000 * 1e6;
    uint256 constant TEAM_AL = 15_000_000 * 1e6;
    uint256 constant TREAS   = 10_000_000 * 1e6;

    function setUp() public {
        token    = new ATok();
        escrow   = new RewardEscrow(address(token), OP, OWNER, WDC, REWARDS, 1e6, 20_000 * 1e6, address(this));
        vesting  = new VestingWallet(address(token), TEAM, WDC, 30 days, 730 days, address(this));
        treasury = new TreasuryTimelock(address(token), OWNER, WDC, 90 days, address(this));

        token.mint(address(escrow),   REWARDS);
        token.mint(address(vesting),  TEAM_AL);
        token.mint(address(treasury), TREAS);
    }

    // ── staged: inert ─────────────────────────────────────────────────────────

    function test_aStagedSuiteHasNoClocksRunning() public view {
        assertFalse(escrow.isActivated(),   "escrow inert");
        assertFalse(vesting.isActivated(),  "vesting inert");
        assertFalse(treasury.isActivated(), "treasury inert");

        assertEq(escrow.emissionStart(), 0, "no emission start");
        assertEq(escrow.emitted(),       0, "nothing emitted");
        assertEq(escrow.spendable(),     0, "nothing spendable");

        assertEq(vesting.vestingStart(), 0, "no vesting start");
        assertEq(vesting.cliffTime(),    0, "no cliff");
        assertEq(vesting.vestingEnd(),   0, "no end");
        assertEq(vesting.totalVested(),  0, "nothing vested");
        assertFalse(vesting.cliffReached(), "cliff not reached while inert");
    }

    /// The whole point. Time passing before activation must accrue nothing at all.
    function test_timeBeforeActivationAccruesNothing() public {
        vm.warp(block.timestamp + 365 days);

        assertEq(escrow.emitted(),      0, "a year staged emits nothing");
        assertEq(escrow.spendable(),    0, "and nothing is spendable");
        assertEq(vesting.totalVested(), 0, "a year staged vests nothing");
        assertFalse(vesting.cliffReached(), "and does not reach a cliff that has not started");
    }

    function test_aStagedSuiteCannotBeOperated() public {
        vm.prank(OP);
        vm.expectRevert("Not activated");
        escrow.distributeReward(address(0xCAFE), 1_000 * 1e6);

        vm.prank(OWNER);
        vm.expectRevert("Not activated");
        treasury.submitRelease(1_000 * 1e6);

        // release() is a silent no-op rather than a revert, matching its behaviour before
        // the cliff — a caller polling it should not have to special-case staging.
        vesting.release();
        assertEq(token.balanceOf(TEAM), 0, "no team tokens from an inert suite");
    }

    // ── activation starts the clocks HERE, not at construction ────────────────

    /// The regression in one test. Stage, wait a month, activate: the merchant must open
    /// with nothing accrued. bufferCap is 30 days of emission, so under the old
    /// constructor-time clock this suite would have gone live at its full spendable
    /// ceiling — a month of rewards unlocked on day one that nobody issued.
    function test_amonthStagedStillOpensAtZero() public {
        vm.warp(block.timestamp + 30 days);

        escrow.activate();
        vesting.activate();
        treasury.activate();

        assertEq(escrow.emitted(),      0, "emission starts at activation, not construction");
        assertEq(escrow.spendable(),    0, "so nothing is spendable on day one");
        assertEq(vesting.totalVested(), 0, "vesting likewise");
        // Assert against the contract's own start, not against `block.timestamp + 30 days`.
        // The warp above uses that exact expression, and under via_ir the compiler folds two
        // identical block.timestamp reads into one — so the assertion would compare the real
        // cliff against a PRE-warp value. It only shows when the two expressions match
        // textually, which is why this passed at 180 days and broke at 30.
        uint256 start = vesting.vestingStart();
        assertEq(start, vm.getBlockTimestamp(), "vesting starts now");
        assertEq(vesting.cliffTime(), start + 30 days,  "full cliff still ahead");
        assertEq(vesting.vestingEnd(), start + 760 days, "full schedule still ahead");
    }

    function test_schedulesRunNormallyOnceActivated() public {
        vm.warp(block.timestamp + 30 days);
        escrow.activate();
        vesting.activate();
        uint256 live = block.timestamp;

        vm.warp(live + 1 days);
        assertApproxEqRel(escrow.emitted(), REWARDS / 1825, 0.01e18, "one day of emission after going live");

        vm.prank(OP);
        escrow.distributeReward(address(0xCAFE), 1_000 * 1e6);
        assertEq(token.balanceOf(address(0xCAFE)), 1_000 * 1e6, "kiosk works once live");

        // Cliff measured from activation: nothing at 29 days after going live.
        vm.warp(vesting.cliffTime() - 1 days);
        vesting.release();
        assertEq(token.balanceOf(TEAM), 0, "still pre-cliff the day before it lands");

        // Zero AT the cliff too — accrual starts there, it does not unlock a chunk.
        vm.warp(vesting.cliffTime());
        assertEq(vesting.totalVested(), 0, "nothing unlocks at the cliff itself");

        vm.warp(vesting.cliffTime() + 365 days);
        vesting.release();
        assertApproxEqRel(token.balanceOf(TEAM), TEAM_AL / 2, 0.001e18, "half vested at the midpoint of 730 days");

        vm.warp(vesting.vestingEnd());
        vesting.release();
        assertEq(token.balanceOf(TEAM), TEAM_AL, "fully vested at day 760");
    }

    // ── activation is once, and factory-only ──────────────────────────────────

    function test_onlyTheActivatorMayActivate() public {
        vm.prank(address(0xBAD));
        vm.expectRevert("Not activator");
        escrow.activate();
    }

    function test_activationIsOneWayAndOnce() public {
        escrow.activate();
        vm.expectRevert("Already activated");
        escrow.activate();

        // No deactivate exists. A schedule that can be stopped and restarted is one the
        // merchant cannot rely on.
        (bool ok,) = address(escrow).call(abi.encodeWithSignature("deactivate()"));
        assertFalse(ok, "there must be no way to unwind activation");
    }
}
