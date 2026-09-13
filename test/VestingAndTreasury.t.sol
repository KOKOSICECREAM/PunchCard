// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/VestingWallet.sol";
import "../contracts/TreasuryTimelock.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract Tok is ERC20, ERC20Burnable {
    constructor() ERC20("M","M") {}
    function mint(address a, uint256 v) external { _mint(a, v); }
    function decimals() public pure override returns (uint8) { return 6; }
}

contract VestingWalletTest is Test {
    Tok token; VestingWallet v;
    address constant TEAM = address(0x7EA3);
    address constant WDC  = address(0xDEAD);
    address constant RAND = address(0x4A4D);

    uint256 constant ALLOC = 15_000_000 * 1e6;
    uint256 constant CLIFF = 180 days;
    uint256 constant VEST  = 1080 days;

    uint256 start;

    function setUp() public {
        token = new Tok();
        v = new VestingWallet(address(token), TEAM, WDC, CLIFF, VEST);
        token.mint(address(v), ALLOC);
        start = block.timestamp;
    }

    // ── nothing escapes before the cliff ─────────────────────────────────────

    function test_nothingVestsBeforeCliff() public {
        vm.warp(start + CLIFF - 1);
        assertEq(v.totalVested(), 0, "zero the second before the cliff");
        v.release();
        assertEq(token.balanceOf(TEAM), 0, "release is a no-op before the cliff");
    }

    /// The schedule is cliff + duration, so it completes at day 1,260 — not 1,080.
    function test_fullyVestedAtCliffPlusDuration() public {
        vm.warp(start + CLIFF + VEST);
        assertEq(v.totalVested(), ALLOC, "fully vested at day 1,260");
        v.release();
        assertEq(token.balanceOf(TEAM), ALLOC);
    }

    /// No jump at the end — the boundary is where a discontinuity would hide.
    function test_scheduleIsContinuousAtTheEnd() public {
        vm.warp(start + CLIFF + VEST - 1);
        uint256 justBefore = v.totalVested();
        assertApproxEqRel(justBefore, ALLOC, 1e12, "within 0.0001% one second before");
    }

    function test_halfwayIsHalf() public {
        vm.warp(start + CLIFF + VEST / 2);
        assertApproxEqRel(v.totalVested(), ALLOC / 2, 1e12);
    }

    /// Releasing repeatedly must not pay twice.
    function test_releaseIsNotRepeatable() public {
        vm.warp(start + CLIFF + VEST / 2);
        v.release();
        uint256 paid = token.balanceOf(TEAM);
        v.release();
        assertEq(token.balanceOf(TEAM), paid, "second release in the same block pays nothing");
        assertEq(v.released(), paid);
    }

    /// release() is permissionless but can only ever pay teamWallet.
    function test_anyoneMayReleaseButOnlyTeamIsPaid() public {
        vm.warp(start + CLIFF + VEST);
        vm.prank(RAND);
        v.release();
        assertEq(token.balanceOf(TEAM), ALLOC, "team paid");
        assertEq(token.balanceOf(RAND), 0,     "caller gets nothing");
    }

    function test_onlyWindDownCanSettle() public {
        vm.prank(RAND);
        vm.expectRevert("Not controller");
        v.settleAndBurn();
    }

    /// Wind-down pays what is vested and burns the rest — nothing is stranded.
    function test_settleAndBurnPaysVestedBurnsRest() public {
        vm.warp(start + CLIFF + VEST / 2);
        uint256 vested = v.totalVested();
        uint256 supplyBefore = token.totalSupply();

        vm.prank(WDC);
        v.settleAndBurn();

        assertEq(token.balanceOf(TEAM), vested, "team keeps what vested");
        assertEq(token.balanceOf(address(v)), 0, "nothing stranded in the wallet");
        assertEq(supplyBefore - token.totalSupply(), ALLOC - vested, "unvested burned");
    }
}

contract TreasuryTimelockTest is Test {
    Tok token; TreasuryTimelock t;
    address constant OWNER = address(0x0B1);
    address constant WDC   = address(0xDEAD);
    address constant RAND  = address(0x4A4D);

    uint256 constant ALLOC = 10_000_000 * 1e6;
    uint256 constant DELAY = 90 days;

    function setUp() public {
        token = new Tok();
        t = new TreasuryTimelock(address(token), OWNER, WDC, DELAY);
        token.mint(address(t), ALLOC);
    }

    function test_onlyOwnerSubmits() public {
        vm.prank(RAND);
        vm.expectRevert("Not owner");
        t.submitRelease(1e6);
    }

    function test_cannotExecuteEarly() public {
        vm.prank(OWNER);
        t.submitRelease(1_000 * 1e6);

        vm.warp(block.timestamp + DELAY - 1);
        vm.expectRevert("Timelock active");
        t.executeRelease();
    }

    function test_executesAfterDelayToOwnerOnly() public {
        vm.prank(OWNER);
        t.submitRelease(1_000 * 1e6);
        vm.warp(block.timestamp + DELAY);

        // permissionless to execute, but it can only ever pay ownerWallet
        vm.prank(RAND);
        t.executeRelease();
        assertEq(token.balanceOf(OWNER), 1_000 * 1e6, "owner paid");
        assertEq(token.balanceOf(RAND), 0, "caller gets nothing");
    }

    /// One at a time — no stacking releases to escape the delay.
    function test_onlyOnePendingAtATime() public {
        vm.startPrank(OWNER);
        t.submitRelease(1_000 * 1e6);
        vm.expectRevert("Release pending");
        t.submitRelease(1_000 * 1e6);
        vm.stopPrank();
    }

    function test_cannotSubmitMoreThanBalance() public {
        vm.prank(OWNER);
        vm.expectRevert("Insufficient balance");
        t.submitRelease(ALLOC + 1);
    }

    /// Cancelling must clear the slot so the treasury is not bricked.
    function test_cancelUnblocksTheQueue() public {
        vm.startPrank(OWNER);
        t.submitRelease(1_000 * 1e6);
        t.cancelRelease();
        assertFalse(t.hasPendingRelease(), "slot cleared");
        t.submitRelease(2_000 * 1e6);   // must not revert
        vm.stopPrank();
        assertTrue(t.hasPendingRelease());
    }

    function test_executeIsNotRepeatable() public {
        vm.prank(OWNER);
        t.submitRelease(1_000 * 1e6);
        vm.warp(block.timestamp + DELAY);
        t.executeRelease();
        vm.expectRevert("No pending release");
        t.executeRelease();
    }

    /// A frozen treasury pays nobody, even with a matured release queued.
    function test_freezeBlocksAMaturedRelease() public {
        vm.prank(OWNER);
        t.submitRelease(1_000 * 1e6);
        vm.warp(block.timestamp + DELAY);

        vm.prank(WDC);
        t.freeze();

        vm.expectRevert("Frozen");
        t.executeRelease();
        assertEq(token.balanceOf(OWNER), 0);
    }

    function test_onlyWindDownFreezesAndBurns() public {
        vm.startPrank(RAND);
        vm.expectRevert("Not controller");
        t.freeze();
        vm.expectRevert("Not controller");
        t.burnUnclaimed();
        vm.stopPrank();
    }
}
