// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/RewardEscrow.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract MockToken is ERC20, ERC20Burnable {
    constructor() ERC20("M","M") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
    function decimals() public pure override returns (uint8) { return 6; }
}

contract RewardEscrowTest is Test {
    MockToken token;
    RewardEscrow escrow;

    address constant OWNER    = address(0xA11CE);
    address constant KIOSK_1  = address(0x1051);
    address constant KIOSK_2  = address(0x1052);
    address constant WINDDOWN = address(0xDEAD);
    address constant CUSTOMER = address(0xC057E);

    uint256 constant ALLOC = 45_000_000 * 1e6;

    function setUp() public {
        token  = new MockToken();
        escrow = new RewardEscrow(address(token), KIOSK_1, OWNER, WINDDOWN, ALLOC, 1e6, 20_000 * 1e6);
        token.mint(address(escrow), ALLOC);
        vm.warp(block.timestamp + 60 days);   // let some emission accrue
    }

    /// Drain an operator's till completely, respecting perTxMax. Returns the total.
    function _drainDrawer(address kiosk) internal returns (uint256 drained) {
        uint256 max_ = escrow.perTxMax();
        vm.startPrank(kiosk);
        for (uint256 i = 0; i < 200; i++) {
            uint256 left = escrow.drawerAvailable(kiosk);
            if (left == 0) break;
            uint256 amt = left > max_ ? max_ : left;
            escrow.distributeReward(CUSTOMER, amt);
            drained += amt;
        }
        vm.stopPrank();
    }

    // ── DRAWERS: theft is capped ─────────────────────────────────────────────

    /// The whole point: a leaked kiosk key cannot drain more than its own till.
    function test_leakedKioskKeyCappedAtOneDrawer() public {
        uint256 drawer = escrow.drawerAvailable(KIOSK_1);
        assertGt(drawer, 0);

        // Attacker with the kiosk key takes everything it can reach.
        uint256 stolen = _drainDrawer(KIOSK_1);

        vm.prank(KIOSK_1);
        vm.expectRevert("Drawer empty");
        escrow.distributeReward(CUSTOMER, 1e6);

        assertEq(stolen, drawer, "cannot exceed one drawer");
        assertGt(escrow.spendable(), 0, "the buffer behind it is untouched");
        assertLt(stolen, escrow.bufferCap(), "a till is far smaller than the buffer");
    }

    /// One compromised till must not touch another's.
    function test_drawersAreIndependent() public {
        uint256 allowance2 = escrow.emissionPerDay() * 2;   // read BEFORE the prank —
        vm.prank(OWNER);                                    // a view call would consume it
        escrow.addOperator(KIOSK_2, allowance2);

        uint256 before2 = escrow.drawerAvailable(KIOSK_2);
        vm.prank(KIOSK_1);
        escrow.distributeReward(CUSTOMER, 20_000 * 1e6);
        assertEq(escrow.drawerAvailable(KIOSK_2), before2, "kiosk 2 unaffected");
    }

    /// Removing an operator is the response to a leak, and it is immediate.
    function test_removedOperatorCannotDistribute() public {
        vm.prank(OWNER);
        escrow.removeOperator(KIOSK_1);
        vm.prank(KIOSK_1);
        vm.expectRevert("Not an operator");
        escrow.distributeReward(CUSTOMER, 1e6);
    }

    /// Tills refill continuously, not at a midnight boundary.
    function test_drawerReplenishesContinuously() public {
        uint256 allowance = escrow.getDrawer(KIOSK_1).dailyAllowance;
        _drainDrawer(KIOSK_1);
        assertEq(escrow.drawerAvailable(KIOSK_1), 0);

        // Warp to absolute times. Under via_ir a cached `block.timestamp` local can be
        // folded back into a fresh timestamp read across vm.warp(), turning absolute warps
        // into relative ones. Read through the cheatcode so the 24h boundary below is really
        // 24h after the drawer was drained, not 36h.
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 12 hours);
        assertApproxEqRel(escrow.drawerAvailable(KIOSK_1), allowance / 2, 1e15, "half back after 12h");
        vm.warp(t0 + 24 hours);
        assertEq(escrow.drawerAvailable(KIOSK_1), allowance, "fully back after 24h");
    }

    /// A compromised owner key still cannot open an unlimited till.
    function test_drawerCeilingEnforced() public {
        uint256 tooBig = escrow.maxDrawer() + 1;            // read BEFORE the prank
        vm.prank(OWNER);
        vm.expectRevert("Above drawer ceiling");
        escrow.addOperator(KIOSK_2, tooBig);
    }

    /// Raising an allowance must not refill a till already drawn down today.
    function test_raisingAllowanceDoesNotRefill() public {
        uint256 allowance = escrow.getDrawer(KIOSK_1).dailyAllowance;
        _drainDrawer(KIOSK_1);
        assertEq(escrow.drawerAvailable(KIOSK_1), 0);

        vm.prank(OWNER);
        escrow.setDrawerAllowance(KIOSK_1, allowance * 2);
        assertEq(escrow.drawerAvailable(KIOSK_1), allowance, "only the increase is available");
    }

    // ── EMISSION: the five-year runway ───────────────────────────────────────

    /// Spend is limited by the schedule, not just by tills.
    function test_emissionCapsSpendRegardlessOfDrawers() public {
        assertLe(escrow.spendable(), escrow.bufferCap(), "never more than the buffer");
        // 60 days in, at most 30 days of emission is reachable
        assertApproxEqRel(escrow.spendable(), escrow.emissionPerDay() * 30, 1e16);
    }

    /// Underspending is not forfeited — it extends the programme.
    function test_unspentEmissionIsNotForfeited() public {
        vm.warp(escrow.emissionStart() + 1825 days);
        assertEq(escrow.emitted(), ALLOC, "fully emitted after five years");
        // still rate-limited, but the whole allocation remains claimable over time
        assertEq(escrow.spendable(), escrow.bufferCap());
        assertEq(escrow.totalDistributed(), 0);
    }

    /// Sanity: the schedule really does span five years.
    function test_fiveYearSchedule() public view {
        // emissionPerDay = ALLOC * 1 days / EMISSION_PERIOD, so 1825 days of it lands
        // one token short of the allocation through integer truncation.
        assertEq(escrow.emissionPerDay() * 1825 / 1e6, 44_999_999, "~45M over 1825 days");
    }

    // ── EMERGENCY: halt only, never redirect ─────────────────────────────────

    function test_pauseHaltsDistribution() public {
        vm.prank(OWNER);
        escrow.pause();
        vm.prank(KIOSK_1);
        vm.expectRevert("Paused");
        escrow.distributeReward(CUSTOMER, 1e6);
    }

    /// A lost owner key must not brick the programme forever.
    function test_pauseAutoExpires() public {
        vm.prank(OWNER);
        escrow.pause();
        vm.warp(block.timestamp + 7 days + 1);   // single warp — safe
        vm.prank(KIOSK_1);
        escrow.distributeReward(CUSTOMER, 1e6);   // works again
        assertEq(token.balanceOf(CUSTOMER), 1e6);
    }

    function test_onlyOwnerControls() public {
        vm.startPrank(KIOSK_1);
        vm.expectRevert("Not owner");
        escrow.addOperator(KIOSK_2, 1e6);
        vm.expectRevert("Not owner");
        escrow.pause();
        vm.stopPrank();
    }
}
