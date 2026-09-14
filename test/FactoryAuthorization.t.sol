// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/WindDownController.sol";

/// The staged rollout depends on one network spanning both stages: beta merchants and
/// production merchants must register into the SAME controller, or each stage gets its own
/// router and registry and merchants from different stages cannot swap against each other.
/// These tests pin that, and pin the limits of the power it introduces.
contract FactoryAuthorizationTest is Test {
    WindDownController wdc;

    address constant MULTISIG    = address(0xA11CE);
    address constant BETA_FACTORY= address(0xBE7A);
    address constant PROD_FACTORY= address(0x9200);
    address constant STRANGER    = address(0xBAD);

    address constant TOKEN_A = address(0xA1);
    address constant TOKEN_B = address(0xB1);
    address constant ESCROW  = address(0xE1);
    address constant VESTING = address(0xE2);
    address constant TREAS   = address(0xE3);
    address constant LOCKER  = address(0xE4);

    function setUp() public {
        wdc = new WindDownController(MULTISIG, BETA_FACTORY);
    }

    function test_constructorAuthorizesInitialFactory() public view {
        assertTrue(wdc.authorizedFactories(BETA_FACTORY), "beta factory authorised at construction");
        assertFalse(wdc.authorizedFactories(PROD_FACTORY), "nothing else is");
    }

    /// The point of the whole change: two factories, one network.
    function test_secondFactoryCanRegisterIntoTheSameNetwork() public {
        vm.prank(BETA_FACTORY);
        wdc.register(TOKEN_A, ESCROW, VESTING, TREAS, LOCKER);

        vm.startPrank(MULTISIG);
        wdc.proposeFactory(PROD_FACTORY, true);
        vm.warp(block.timestamp + wdc.FACTORY_TIMELOCK());
        wdc.executeFactory(PROD_FACTORY);
        vm.stopPrank();

        vm.prank(PROD_FACTORY);
        wdc.register(TOKEN_B, ESCROW, VESTING, TREAS, LOCKER);

        assertTrue(wdc.isRegistered(TOKEN_A), "beta merchant on the network");
        assertTrue(wdc.isRegistered(TOKEN_B), "production merchant on the SAME network");
    }

    function test_unauthorizedFactoryCannotRegister() public {
        vm.prank(PROD_FACTORY);
        vm.expectRevert("Not factory");
        wdc.register(TOKEN_B, ESCROW, VESTING, TREAS, LOCKER);
    }

    function test_timelockMustElapse() public {
        vm.startPrank(MULTISIG);
        wdc.proposeFactory(PROD_FACTORY, true);

        vm.expectRevert("Timelock not elapsed");
        wdc.executeFactory(PROD_FACTORY);

        vm.warp(block.timestamp + wdc.FACTORY_TIMELOCK() - 1);
        vm.expectRevert("Timelock not elapsed");
        wdc.executeFactory(PROD_FACTORY);
        vm.stopPrank();

        assertFalse(wdc.authorizedFactories(PROD_FACTORY));
    }

    function test_onlyMultisigMayProposeOrExecute() public {
        vm.prank(STRANGER);
        vm.expectRevert("Not multisig");
        wdc.proposeFactory(PROD_FACTORY, true);

        vm.prank(MULTISIG);
        wdc.proposeFactory(PROD_FACTORY, true);
        vm.warp(block.timestamp + wdc.FACTORY_TIMELOCK());

        vm.prank(STRANGER);
        vm.expectRevert("Not multisig");
        wdc.executeFactory(PROD_FACTORY);
    }

    function test_executeWithoutProposalReverts() public {
        vm.prank(MULTISIG);
        vm.expectRevert("No proposal");
        wdc.executeFactory(PROD_FACTORY);
    }

    /// Retiring the beta factory must stop NEW registrations without orphaning the
    /// merchants that already came through it.
    function test_disablingAFactoryDoesNotOrphanItsMerchants() public {
        vm.prank(BETA_FACTORY);
        wdc.register(TOKEN_A, ESCROW, VESTING, TREAS, LOCKER);

        vm.startPrank(MULTISIG);
        wdc.proposeFactory(BETA_FACTORY, false);
        vm.warp(block.timestamp + wdc.FACTORY_TIMELOCK());
        wdc.executeFactory(BETA_FACTORY);
        vm.stopPrank();

        assertFalse(wdc.authorizedFactories(BETA_FACTORY), "retired");
        assertTrue(wdc.isRegistered(TOKEN_A), "its merchant still on the network");

        vm.prank(BETA_FACTORY);
        vm.expectRevert("Not factory");
        wdc.register(TOKEN_B, ESCROW, VESTING, TREAS, LOCKER);
    }

    /// Governance power, not custody power. Authorising a factory must not let anyone
    /// re-register or otherwise reach an existing merchant's suite.
    function test_authorisationCannotTouchAnExistingSuite() public {
        vm.prank(BETA_FACTORY);
        wdc.register(TOKEN_A, ESCROW, VESTING, TREAS, LOCKER);

        vm.startPrank(MULTISIG);
        wdc.proposeFactory(PROD_FACTORY, true);
        vm.warp(block.timestamp + wdc.FACTORY_TIMELOCK());
        wdc.executeFactory(PROD_FACTORY);
        vm.stopPrank();

        // a newly blessed factory cannot overwrite a merchant registered by another
        vm.prank(PROD_FACTORY);
        vm.expectRevert("Already registered");
        wdc.register(TOKEN_A, address(0xDEAD), address(0xDEAD), address(0xDEAD), address(0xDEAD));

        IWindDownController.WindDownSuite memory s = wdc.getSuite(TOKEN_A);
        assertEq(s.lpLocker, LOCKER, "suite untouched");
    }

    function test_redundantProposalReverts() public {
        vm.prank(MULTISIG);
        vm.expectRevert("Already in that state");
        wdc.proposeFactory(BETA_FACTORY, true);
    }
}
