// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/WindDownController.sol";
import "../contracts/MerchantToken.sol";
import "../contracts/RewardEscrow.sol";
import "../contracts/VestingWallet.sol";
import "../contracts/TreasuryTimelock.sol";
import "../contracts/LPLocker.sol";
import "../contracts/pilot/LPLockerPilot.sol";

/// A token that looks like a merchant token and can mint more of itself.
contract FakeToken is MerchantToken {
    constructor(address to) MerchantToken("Fake", "FAKE", 100_000_000 * 1e6, to, keccak256("x")) {}
    function mintMore(address to, uint256 amount) external { _mint(to, amount); }
}

/// @title The manual admission path, and what it refuses
///
/// @notice The factory path proves a suite was CREATED by known code. The manual path
///         cannot — a registrar admits contracts that already exist — so it proves the next
///         best thing: that the code is known NOW, by comparing every contract's runtime
///         codehash against an implementation the multisig approved.
///
///         Without that, a registrar's signature would mean "trust me", and the network's
///         promise would be a person rather than a property. These tests are what stop the
///         check being quietly dropped.
contract ManualRegistrationTest is Test {
    WindDownController wdc;

    address constant MULTISIG  = address(0xA1);
    address constant REGISTRAR = address(0xA2);
    address constant FACTORY   = address(0xFAC7);
    address constant OWNER     = address(0xB1);
    address constant TEAM      = address(0xB2);
    address constant OP        = address(0xB3);
    address constant PM        = address(0xDEAD);
    address constant USDC      = address(0x5DC);
    address constant WETHA     = address(0x3E7);
    address constant FEE       = address(0xFEE);

    MerchantToken    token;
    RewardEscrow     escrow;
    VestingWallet    vesting;
    TreasuryTimelock treasury;
    LPLocker         locker;

    function setUp() public {
        wdc = new WindDownController(MULTISIG, FACTORY);

        token    = new MerchantToken("Manual", "MANU", 100_000_000 * 1e6, address(this), keccak256("m"));
        escrow   = new RewardEscrow(address(token), OP, OWNER, address(wdc), 45_000_000 * 1e6, 1e6, 20_000 * 1e6, address(this));
        vesting  = new VestingWallet(address(token), TEAM, address(wdc), 30 days, 730 days, address(this));
        treasury = new TreasuryTimelock(address(token), OWNER, address(wdc), 90 days, address(this));
        locker   = new LPLocker(address(token), OWNER, address(wdc), PM, address(this), USDC, WETHA, FEE);

        vm.startPrank(MULTISIG);
        wdc.setRegistrar(REGISTRAR, true);
        wdc.setApprovedCode(wdc.ROLE_TOKEN(),    address(token).codehash,    true);
        wdc.setApprovedCode(wdc.ROLE_ESCROW(),   address(escrow).codehash,   true);
        wdc.setApprovedCode(wdc.ROLE_VESTING(),  address(vesting).codehash,  true);
        wdc.setApprovedCode(wdc.ROLE_TREASURY(), address(treasury).codehash, true);
        wdc.setApprovedCode(wdc.ROLE_LOCKER(),   address(locker).codehash,   true);
        vm.stopPrank();
    }

    function _register() internal {
        vm.prank(REGISTRAR);
        wdc.registerManual(address(token), address(escrow), address(vesting), address(treasury), address(locker));
    }

    // ── the happy path ────────────────────────────────────────────────────────

    function test_anApprovedSuiteIsAdmittedAndLooksLikeAnyOtherMerchant() public {
        _register();
        assertTrue(wdc.isRegistered(address(token)), "registered");

        // Identical to a factory registration. The router cannot tell them apart, on
        // purpose: a merchant is a merchant.
        IWindDownController.WindDownSuite memory s = wdc.getSuite(address(token));
        assertEq(s.rewardEscrow,     address(escrow),   "escrow recorded");
        assertEq(s.vestingWallet,    address(vesting),  "vesting recorded");
        assertEq(s.treasuryTimelock, address(treasury), "treasury recorded");
        assertEq(s.lpLocker,         address(locker),   "locker recorded");
        assertFalse(wdc.isInitiated(address(token)), "not winding down");
    }

    // ── what it refuses ───────────────────────────────────────────────────────

    /// The attack the codehash check exists for. A token that can mint more of itself
    /// passes every shape-based check — it has code, the right interface, the right
    /// supply — and is a different promise entirely.
    function test_aTokenThatCanMintMoreIsRefused() public {
        FakeToken fake = new FakeToken(address(this));
        assertTrue(address(fake).code.length > 0, "the fake has code, like any real token");

        vm.prank(REGISTRAR);
        vm.expectRevert("Unapproved token code");
        wdc.registerManual(address(fake), address(escrow), address(vesting), address(treasury), address(locker));
    }

    /// Every role is checked, not just the token — a real token with a tampered locker is
    /// the same class of problem.
    function test_everyRoleIsChecked() public {
        LPLocker other = new LPLockerPilot(address(token), OWNER, address(wdc), PM, address(this), USDC, WETHA, FEE);

        vm.startPrank(REGISTRAR);
        vm.expectRevert("Unapproved locker code");
        wdc.registerManual(address(token), address(escrow), address(vesting), address(treasury), address(other));
        vm.stopPrank();

        // ...and approving that lineage admits it. Several lockers are legitimate: the
        // production, beta and pilot lineages are all real and differ on purpose.
        vm.startPrank(MULTISIG);
        wdc.setApprovedCode(wdc.ROLE_LOCKER(), address(other).codehash, true);
        vm.stopPrank();

        vm.startPrank(REGISTRAR);
        wdc.registerManual(address(token), address(escrow), address(vesting), address(treasury), address(other));
        vm.stopPrank();
        assertTrue(wdc.isRegistered(address(token)), "admitted once the lineage is approved");
    }

    function test_anEOAisRefused() public {
        vm.prank(REGISTRAR);
        vm.expectRevert("No code at escrow");
        wdc.registerManual(address(token), address(0xBEEF), address(vesting), address(treasury), address(locker));
    }

    function test_onlyARegistrarMayAdmit() public {
        vm.prank(address(0xBAD));
        vm.expectRevert("Not registrar");
        wdc.registerManual(address(token), address(escrow), address(vesting), address(treasury), address(locker));
    }

    function test_theMultisigControlsBothLists() public {
        bytes32 roleToken = wdc.ROLE_TOKEN();   // read outside the prank

        vm.startPrank(address(0xBAD));
        vm.expectRevert("Not multisig");
        wdc.setRegistrar(address(0xBAD), true);
        vm.expectRevert("Not multisig");
        wdc.setApprovedCode(roleToken, bytes32(uint256(1)), true);
        vm.stopPrank();

        // And a registrar can be removed the moment it stops being trusted. That is the
        // lever the manual path depends on: a registrar is a person, and people change.
        vm.startPrank(MULTISIG);
        wdc.setRegistrar(REGISTRAR, false);
        vm.stopPrank();

        vm.startPrank(REGISTRAR);
        vm.expectRevert("Not registrar");
        wdc.registerManual(address(token), address(escrow), address(vesting), address(treasury), address(locker));
        vm.stopPrank();
    }

    /// Approval is per DEPLOYMENT, not per implementation — and that shapes the whole
    /// operational model, so it is pinned here rather than left to be rediscovered.
    ///
    /// Solidity writes immutables into runtime bytecode, so two escrows compiled from the
    /// same source with different owner wallets have different codehashes. The multisig
    /// therefore cannot approve "the RewardEscrow" once and cover every merchant; it
    /// approves the exact contracts of one suite, after checking they are what they claim.
    ///
    /// That is why source verification is load-bearing rather than cosmetic. Approving the
    /// codehash of a contract nobody has verified is a rubber stamp; approving one whose
    /// source is published and matches is an attestation.
    function test_approvalIsPerDeploymentBecauseImmutablesAreInTheBytecode() public {
        RewardEscrow other = new RewardEscrow(
            address(token), OP, address(0xB9), address(wdc), 45_000_000 * 1e6, 1e6, 20_000 * 1e6, address(this)
        );
        assertTrue(
            address(other).codehash != address(escrow).codehash,
            "same source, different owner wallet, different codehash"
        );

        // So the approval for one escrow does not admit the other.
        vm.startPrank(REGISTRAR);
        vm.expectRevert("Unapproved escrow code");
        wdc.registerManual(address(token), address(other), address(vesting), address(treasury), address(locker));
        vm.stopPrank();
    }

    function test_registrationIsStillOnce() public {
        _register();
        vm.prank(REGISTRAR);
        vm.expectRevert("Already registered");
        wdc.registerManual(address(token), address(escrow), address(vesting), address(treasury), address(locker));
    }

    /// A registrar cannot reach the factory path, and an unauthorised factory cannot reach
    /// the registry at all. The two doors stay separate.
    function test_theTwoPathsDoNotLeakIntoEachOther() public {
        vm.prank(REGISTRAR);
        vm.expectRevert("Not factory");
        wdc.register(address(token), address(escrow), address(vesting), address(treasury), address(locker));
    }
}
