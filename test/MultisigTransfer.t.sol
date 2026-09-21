// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/WindDownController.sol";
import "../contracts/PunchCardRouter.sol";

/// @title Governance can move to a Safe without redeploying the network
///
/// @notice `multisig` was immutable on both contracts, so whichever address signed on deploy
///         day governed the network forever. A beta launched from an EOA — which is exactly
///         what SKOOP's admin address is — could only reach a Safe by redeploying the
///         controller, and a new controller is a new network: the router binds to one
///         registry, so every merchant registered under the old one is orphaned.
///
///         These tests pin the replacement. The transfer is two-step and timelocked, and
///         both halves are load-bearing:
///
///         - acceptance, so a transfer to a typo or an undeployed Safe cannot brick
///           governance — the failure this change exists to prevent
///         - the delay, because an immutable compromised key is SHARED, while an instantly
///           transferable one becomes EXCLUSIVE in a single transaction
contract MultisigTransferTest is Test {

    address constant OLD     = address(0xA11CE);
    address constant NEW     = address(0xB0B);
    address constant STRANGER= address(0xBAD);
    address constant FACTORY = address(0xF);

    WindDownController wdc;
    PunchCardRouter    router;

    function setUp() public {
        wdc = new WindDownController(OLD, FACTORY);
        router = new PunchCardRouter(
            OLD, address(wdc), address(0x1234), address(0xAAAA), address(0xBBBB), 30, address(0xFEE)
        );
    }

    // ── the happy path, and the point of the whole change ─────────────────────

    function test_governanceMovesToANewAddressWithoutRedeploying() public {
        assertEq(wdc.multisig(), OLD, "starts with the deploy-day address");

        vm.prank(OLD);
        wdc.proposeMultisig(NEW);

        // Nothing has moved yet. This is the window.
        assertEq(wdc.multisig(),        OLD, "old still governs during the timelock");
        assertEq(wdc.pendingMultisig(), NEW, "new is pending only");

        vm.warp(wdc.multisigAcceptableAt());
        vm.prank(NEW);
        wdc.acceptMultisig();

        assertEq(wdc.multisig(),        NEW,           "new governs");
        assertEq(wdc.pendingMultisig(), address(0),    "pending cleared");
        assertEq(wdc.multisigAcceptableAt(), 0,        "clock cleared");
    }

    /// The two assertions the whole change is for: power actually leaves, and actually arrives.
    function test_theOldMultisigLosesEveryPowerAndTheNewOneGainsThem() public {
        _handover();

        // Read the role BEFORE arming expectRevert. `wdc.ROLE_TOKEN()` is itself an
        // external call, so leaving it inline consumes the expectRevert that was meant for
        // setApprovedCode — which then passes for the wrong reason.
        bytes32 roleToken = wdc.ROLE_TOKEN();

        // The old address is now a stranger to every gated call.
        vm.startPrank(OLD);
        vm.expectRevert("Not multisig");
        wdc.setRegistrar(address(0x1), true);
        vm.expectRevert("Not multisig");
        wdc.setApprovedCode(roleToken, bytes32(uint256(1)), true);
        vm.expectRevert("Not multisig");
        wdc.proposeFactory(address(0x2), true);
        vm.expectRevert("Not multisig");
        wdc.proposeMultisig(STRANGER);
        vm.stopPrank();

        // And the new one holds them.
        vm.startPrank(NEW);
        wdc.setRegistrar(address(0x1), true);
        wdc.setApprovedCode(roleToken, bytes32(uint256(1)), true);
        wdc.proposeFactory(address(0x2), true);
        vm.stopPrank();

        assertTrue(wdc.registrars(address(0x1)), "new multisig can set a registrar");
        assertTrue(wdc.approvedCode(roleToken, bytes32(uint256(1))), "and approve a codehash");
    }

    // ── acceptance: the guard against bricking governance ─────────────────────

    /// A transfer to an address nobody controls must not take effect. This is the failure
    /// mode a one-step transferMultisig(addr) would have reintroduced.
    function test_anUnacceptedProposalNeverMovesPower() public {
        vm.prank(OLD);
        wdc.proposeMultisig(NEW);

        vm.warp(block.timestamp + 3650 days); // a decade later, still unaccepted
        assertEq(wdc.multisig(), OLD, "power stays put until the new key proves it exists");

        vm.prank(OLD);
        wdc.setRegistrar(address(0x9), true);
        assertTrue(wdc.registrars(address(0x9)), "and the old multisig still works throughout");
    }

    function test_onlyTheProposedAddressMayAccept() public {
        vm.prank(OLD);
        wdc.proposeMultisig(NEW);
        vm.warp(wdc.multisigAcceptableAt());

        vm.prank(STRANGER);
        vm.expectRevert("Not pending multisig");
        wdc.acceptMultisig();

        vm.prank(OLD);
        vm.expectRevert("Not pending multisig");
        wdc.acceptMultisig();
    }

    // ── the delay: the window to notice a stolen key ──────────────────────────

    function test_acceptanceIsRefusedBeforeTheTimelockElapses() public {
        vm.prank(OLD);
        wdc.proposeMultisig(NEW);

        vm.warp(wdc.multisigAcceptableAt() - 1);
        vm.prank(NEW);
        vm.expectRevert("Timelock active");
        wdc.acceptMultisig();
    }

    function test_aProposalCanBeCancelledInsideTheWindow() public {
        vm.prank(OLD);
        wdc.proposeMultisig(STRANGER);

        vm.prank(OLD);
        wdc.cancelMultisigTransfer();
        assertEq(wdc.pendingMultisig(), address(0), "proposal gone");
        assertEq(wdc.multisigAcceptableAt(), 0,     "clock gone");

        vm.warp(block.timestamp + 365 days);
        vm.prank(STRANGER);
        // Reverts on the sender check, not the clock: cancelling zeroes pendingMultisig, so
        // nobody matches it. Asserting the exact string keeps the guard order pinned.
        vm.expectRevert("Not pending multisig");
        wdc.acceptMultisig();

        assertEq(wdc.multisig(), OLD, "governance never moved");
    }

    function test_acceptingWithNothingPendingReverts() public {
        vm.prank(NEW);
        vm.expectRevert("Not pending multisig");
        wdc.acceptMultisig();
    }

    // ── guards ────────────────────────────────────────────────────────────────

    function test_zeroAddressIsRefused() public {
        vm.prank(OLD);
        vm.expectRevert("Invalid multisig");
        wdc.proposeMultisig(address(0));
    }

    function test_proposingTheCurrentMultisigIsRefused() public {
        vm.prank(OLD);
        vm.expectRevert("Already the multisig");
        wdc.proposeMultisig(OLD);
    }

    function test_onlyTheMultisigMayPropose() public {
        vm.prank(STRANGER);
        vm.expectRevert("Not multisig");
        wdc.proposeMultisig(NEW);
    }

    function test_reproposingRestartsTheClockAndReplacesTheTarget() public {
        vm.prank(OLD);
        wdc.proposeMultisig(STRANGER);
        uint256 first = wdc.multisigAcceptableAt();

        vm.warp(block.timestamp + 1 hours);
        vm.prank(OLD);
        wdc.proposeMultisig(NEW);

        assertEq(wdc.pendingMultisig(), NEW, "target replaced");
        assertGt(wdc.multisigAcceptableAt(), first, "clock restarted");

        vm.warp(wdc.multisigAcceptableAt());
        vm.prank(STRANGER);
        vm.expectRevert("Not pending multisig");
        wdc.acceptMultisig();
    }

    // ── the router moves the same way ─────────────────────────────────────────

    function test_theRouterTransfersOnTheSameTerms() public {
        vm.prank(OLD);
        router.proposeMultisig(NEW);

        vm.prank(NEW);
        vm.expectRevert("Timelock active");
        router.acceptMultisig();

        vm.warp(router.multisigAcceptableAt());
        vm.prank(NEW);
        router.acceptMultisig();

        assertEq(router.multisig(), NEW, "router governance moved");

        PunchCardRouter.RouterParams memory p =
            PunchCardRouter.RouterParams({ feeRate: 20, feeRecipient: address(0xFEE2) });

        vm.prank(OLD);
        vm.expectRevert("Not multisig");
        router.proposeChange(p);

        vm.prank(NEW);
        router.proposeChange(p);
    }

    /// A parameter proposal outlives the handover, so the incoming multisig inherits it
    /// rather than finding it silently dropped. Worth pinning: the alternative — clearing
    /// it — would look tidier and would hide a pending fee change from whoever takes over.
    function test_aPendingParameterChangeSurvivesTheHandover() public {
        PunchCardRouter.RouterParams memory p =
            PunchCardRouter.RouterParams({ feeRate: 20, feeRecipient: address(0xFEE2) });

        vm.prank(OLD);
        router.proposeChange(p);

        vm.prank(OLD);
        router.proposeMultisig(NEW);
        vm.warp(router.multisigAcceptableAt());
        vm.prank(NEW);
        router.acceptMultisig();

        // Inherited, executable, and cancellable by the new holder.
        vm.prank(NEW);
        router.cancelChange();
    }

    function _handover() private {
        vm.prank(OLD);
        wdc.proposeMultisig(NEW);
        vm.warp(wdc.multisigAcceptableAt());
        vm.prank(NEW);
        wdc.acceptMultisig();
    }
}
