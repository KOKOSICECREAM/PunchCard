// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/LPLocker.sol";
import "../contracts/beta/LPLockerBeta.sol";
import "../contracts/pilot/LPLockerPilot.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract PTok is ERC20, ERC20Burnable {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// Position manager that actually tracks liquidity, so a full drain is observable.
contract PilotPM {
    mapping(uint256 => uint128) public liq;
    address public tokenA; address public tokenB; address public tokenC;
    uint256 public payout;

    function seed(uint256 id, uint128 l) external { liq[id] = l; }
    function setTokens(address a, address b, address c) external { tokenA=a; tokenB=b; tokenC=c; }
    function setPayout(uint256 p) external { payout = p; }

    function positions(uint256 id) external view returns (
        uint96, address, address, address, uint24, int24, int24,
        uint128 liquidity, uint256, uint256, uint128, uint128
    ) {
        return (0, address(0), tokenA, id == 1 ? tokenB : tokenC, 3000, 0, 0, liq[id], 0, 0, 0, 0);
    }

    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata p)
        external returns (uint256, uint256)
    {
        require(liq[p.tokenId] >= p.liquidity, "too much");
        liq[p.tokenId] -= p.liquidity;
        return (0, 0);
    }

    function collect(INonfungiblePositionManager.CollectParams calldata p)
        external returns (uint256, uint256)
    {
        address pair = p.tokenId == 1 ? tokenB : tokenC;
        if (payout > 0) { PTok(tokenA).mint(p.recipient, payout); PTok(pair).mint(p.recipient, payout); }
        return (payout, payout);
    }
}

/// @title The open-ended pilot hatch — and the wall between it and every merchant
///
/// @notice LPLockerPilot deletes LPLockerBeta's first guardrail on purpose: the hatch no
///         longer closes by itself. That is defensible for exactly one deployment — KOKOS
///         testing PunchCard's machine with PunchCard's own money, on a schedule set by the
///         work rather than by a constant.
///
///         It is indefensible for a merchant, so most of this file is not about the pilot
///         working. It is about the other two lineages being unable to become it.
contract PilotRecoveryTest is Test {
    PTok merchant; PTok usdc; PTok weth;
    PilotPM pm;
    LPLockerPilot pilot;
    LPLockerBeta  beta;

    address constant OWNER     = address(0xA11CE);
    address constant PUNCHCARD = address(0xB0B);
    address constant WINDDOWN  = address(0xDEAD);
    address constant FACTORY   = address(0xFAC7);
    uint256 constant RESERVE   = 27_000_000 * 1e6;

    function setUp() public {
        merchant = new PTok("Merchant", "MERCH");
        usdc     = new PTok("USDC", "USDC");
        weth     = new PTok("WETH", "WETH");
        pm       = new PilotPM();
        pm.setTokens(address(merchant), address(usdc), address(weth));
        pm.seed(1, 1e18); pm.seed(2, 1e18);
        pm.setPayout(100 * 1e6);

        pilot = new LPLockerPilot(
            address(merchant), OWNER, WINDDOWN, address(pm), FACTORY,
            address(usdc), address(weth), PUNCHCARD
        );
        beta = new LPLockerBeta(
            address(merchant), OWNER, WINDDOWN, address(pm), FACTORY,
            address(usdc), address(weth), PUNCHCARD
        );

        vm.startPrank(FACTORY);
        pilot.initializeLP(1, 2, 3000, 3000);
        beta.initializeLP(1, 2, 3000, 3000);
        vm.stopPrank();

        merchant.mint(address(pilot), RESERVE);
    }

    // ── the hatch stays open ─────────────────────────────────────────────────

    /// The whole point. A pilot that runs long is the expected case, not the failure case.
    function test_hatchStillOpenLongAfterTheBetaWindowWouldHaveClosed() public {
        assertTrue(pilot.evacuationOpen(), "open at deploy");

        vm.warp(block.timestamp + 31 days);
        assertTrue(pilot.evacuationOpen(), "still open past the 30-day beta window");
        assertFalse(beta.evacuationOpen(), "the beta locker HAS closed by now");

        vm.warp(block.timestamp + 365 days);
        assertTrue(pilot.evacuationOpen(), "still open after a year");

        vm.warp(block.timestamp + 3650 days);
        assertTrue(pilot.evacuationOpen(), "still open after a decade");
    }

    /// The inherited immutable still reads deploy+30d and does not apply. Anything reading
    /// a deadline must get the pilot's real answer.
    function test_inheritedDeadlineIsNotTheRealDeadline() public {
        uint256 stale = pilot.evacuationDeadline();
        assertEq(stale, block.timestamp + 30 days, "inherited value is still the beta one");
        assertEq(pilot.evacuationExpiresAt(), type(uint256).max, "the real answer is: never");

        vm.warp(stale + 1);
        assertTrue(pilot.evacuationOpen(), "the stale deadline does not close the hatch");
    }

    /// Evacuation after a year must behave exactly as it does on day one.
    function test_evacuationWorksAfterAYear() public {
        vm.warp(block.timestamp + 365 days);

        vm.prank(OWNER);
        pilot.evacuateLP();

        // Two positions, so the mock pays merchant-token fees twice.
        assertEq(merchant.balanceOf(OWNER), RESERVE + 200 * 1e6, "reserve and both positions' fees returned");
        assertEq(merchant.balanceOf(address(pilot)), 0, "locker emptied");
        assertEq(pm.liq(1), 0, "USDC position drained");
        assertEq(pm.liq(2), 0, "ETH position drained");
        assertTrue(pilot.lpPermanentlyLocked(), "bricked afterwards");
        assertFalse(pilot.evacuationOpen(), "and the hatch is shut for good");
    }

    // ── closing it is a deliberate act, and irreversible ─────────────────────

    /// "If we decide to manually lock LP after testing, that can be our call" — this is
    /// that call, and it must not be revocable by the same people who made it.
    function test_lockLPIsTheOnlyWayItEverCloses() public {
        vm.warp(block.timestamp + 200 days);
        assertTrue(pilot.evacuationOpen(), "still open before the decision");

        vm.prank(OWNER);
        pilot.lockLP();

        assertFalse(pilot.evacuationOpen(), "closed by decision");
        assertTrue(pilot.lpPermanentlyLocked(), "permanently");

        vm.prank(OWNER);
        vm.expectRevert("Evacuation window closed");
        pilot.evacuateLP();

        // And no amount of waiting, or of being the owner, reopens it.
        vm.warp(block.timestamp + 3650 days);
        vm.prank(OWNER);
        vm.expectRevert("Already locked");
        pilot.lockLP();
        assertFalse(pilot.evacuationOpen(), "still closed a decade later");
    }

    /// After locking, the pilot must be indistinguishable from production in behaviour.
    /// That is what makes "lock it when testing ends" a real graduation rather than a label.
    function test_afterLockingItBehavesLikeProduction() public {
        vm.prank(OWNER);
        pilot.lockLP();

        vm.prank(OWNER);
        vm.expectRevert("Evacuation window closed");
        pilot.evacuateLP();

        vm.warp(block.timestamp + 3650 days);
        vm.prank(OWNER);
        vm.expectRevert("Evacuation window closed");
        pilot.evacuateLP();
    }

    function test_onlyOwnerMayEvacuateOrLock() public {
        vm.prank(PUNCHCARD);
        vm.expectRevert("Not owner");
        pilot.evacuateLP();

        vm.prank(address(0xBAD));
        vm.expectRevert("Not authorised");
        pilot.lockLP();

        // PunchCard's controller may close it but may never empty it — unchanged from beta.
        vm.prank(WINDDOWN);
        pilot.lockLP();
        assertTrue(pilot.lpPermanentlyLocked(), "controller may close the hatch");
    }

    // ── the wall: no merchant lineage can become this ────────────────────────

    /// The guarantee a merchant is owed. LPLockerBeta's window must still close by itself,
    /// because the pilot removing that guardrail must not have removed it for anyone else.
    function test_betaWindowStillSelfCloses() public {
        assertTrue(beta.evacuationOpen(), "beta open at deploy");
        vm.warp(block.timestamp + 30 days);
        assertFalse(beta.evacuationOpen(), "beta closes on its own at 30 days");

        vm.prank(OWNER);
        vm.expectRevert("Evacuation window closed");
        beta.evacuateLP();
    }

    /// Production must have no hatch at all — not a closed one, not an open-ended one.
    function test_productionLockerHasNeitherMarkerNorHatch() public {
        LPLocker prod = new LPLocker(
            address(merchant), OWNER, WINDDOWN, address(pm), FACTORY,
            address(usdc), address(weth), PUNCHCARD
        );

        (bool okRecovery,) = address(prod).call(abi.encodeWithSignature("HAS_LP_RECOVERY()"));
        assertFalse(okRecovery, "production must not answer HAS_LP_RECOVERY");

        (bool okUnlimited,) = address(prod).call(abi.encodeWithSignature("HAS_UNLIMITED_LP_RECOVERY()"));
        assertFalse(okUnlimited, "production must not answer HAS_UNLIMITED_LP_RECOVERY");

        (bool okEvac,) = address(prod).call(abi.encodeWithSignature("evacuateLP()"));
        assertFalse(okEvac, "production must have no evacuation path");
    }

    /// The three locker lineages must be told apart on-chain by anyone, without a doc.
    /// LPLockerBeta carries no marker constant, so which calls ANSWER is the discriminator.
    function test_theThreeLockerLineagesAreDistinguishableOnChain() public {
        LPLocker prod = new LPLocker(
            address(merchant), OWNER, WINDDOWN, address(pm), FACTORY,
            address(usdc), address(weth), PUNCHCARD
        );

        bytes memory openSig    = abi.encodeWithSignature("evacuationOpen()");
        bytes memory expiresSig = abi.encodeWithSignature("evacuationExpiresAt()");

        (bool prodOpen,)  = address(prod).staticcall(openSig);
        (bool betaOpen,)  = address(beta).staticcall(openSig);
        (bool pilotOpen,) = address(pilot).staticcall(openSig);
        assertFalse(prodOpen, "production has no evacuationOpen()");
        assertTrue(betaOpen,  "beta answers evacuationOpen()");
        assertTrue(pilotOpen, "pilot answers evacuationOpen()");

        (bool prodExp,)  = address(prod).staticcall(expiresSig);
        (bool betaExp,)  = address(beta).staticcall(expiresSig);
        (bool pilotExp,) = address(pilot).staticcall(expiresSig);
        assertFalse(prodExp, "production has no evacuationExpiresAt()");
        assertFalse(betaExp, "beta must NOT answer evacuationExpiresAt() - its deadline is real");
        assertTrue(pilotExp, "only the pilot answers evacuationExpiresAt()");

        assertTrue(pilot.HAS_UNLIMITED_LP_RECOVERY(), "pilot carries the marker constant");
    }

    /// A pilot locker's liquidity is NOT locked, and nothing may present it as locked.
    /// staged-rollout.md already requires the dapp to read state rather than assert it;
    /// this is that state being readable and honest for the whole life of the pilot.
    function test_openHatchIsAlwaysDisclosable() public {
        assertTrue(pilot.evacuationOpen(), "disclosable as UNLOCKED at deploy");
        vm.warp(block.timestamp + 500 days);
        assertTrue(pilot.evacuationOpen(), "still UNLOCKED, and still says so");

        vm.prank(OWNER);
        pilot.lockLP();
        assertFalse(pilot.evacuationOpen(), "only now may it be presented as locked");
    }
}
