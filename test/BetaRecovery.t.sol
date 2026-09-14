// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/LPLocker.sol";
import "../contracts/beta/LPLockerBeta.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract MTok is ERC20, ERC20Burnable {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// Position manager that actually tracks liquidity, so a full drain is observable.
contract DrainPM {
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
        if (payout > 0) { MTok(tokenA).mint(p.recipient, payout); MTok(pair).mint(p.recipient, payout); }
        return (payout, payout);
    }
}

contract BetaRecoveryTest is Test {
    MTok merchant; MTok usdc; MTok weth;
    DrainPM pm;
    LPLockerBeta locker;

    address constant OWNER     = address(0xA11CE);
    address constant PUNCHCARD = address(0xB0B);
    address constant WINDDOWN  = address(0xDEAD);
    address constant FACTORY   = address(0xFAC7);
    uint256 constant RESERVE   = 27_000_000 * 1e6;

    function setUp() public {
        merchant = new MTok("Merchant", "MERCH");
        usdc     = new MTok("USDC", "USDC");
        weth     = new MTok("WETH", "WETH");
        pm       = new DrainPM();
        pm.setTokens(address(merchant), address(usdc), address(weth));
        pm.seed(1, 1e18); pm.seed(2, 1e18);
        pm.setPayout(100 * 1e6);

        locker = new LPLockerBeta(
            address(merchant), OWNER, WINDDOWN, address(pm), FACTORY,
            address(usdc), address(weth), PUNCHCARD
        );
        vm.prank(FACTORY);
        locker.initializeLP(1, 2, 3000, 3000);
        merchant.mint(address(locker), RESERVE);
    }

    // ── the hatch works while open ────────────────────────────────────────────

    function test_ownerCanEvacuateDuringWindow() public {
        assertTrue(locker.evacuationOpen(), "open at deployment");

        vm.prank(OWNER);
        locker.evacuateLP();

        assertEq(pm.liq(1), 0, "USDC position fully drained");
        assertEq(pm.liq(2), 0, "ETH position fully drained");
        assertEq(merchant.balanceOf(address(locker)), 0, "no merchant tokens left behind");
        assertEq(usdc.balanceOf(address(locker)),     0, "no USDC left behind");
        assertEq(weth.balanceOf(address(locker)),     0, "no WETH left behind");
        assertGe(merchant.balanceOf(OWNER), RESERVE, "reserve reached the merchant");
        assertTrue(locker.lpPermanentlyLocked(), "locker dead after evacuating");
    }

    /// Evacuating must brick the locker, not merely empty it.
    function test_evacuationIsTerminal() public {
        vm.prank(OWNER);
        locker.evacuateLP();

        assertFalse(locker.evacuationOpen(), "cannot evacuate twice");
        vm.prank(OWNER);
        vm.expectRevert("Evacuation window closed");
        locker.evacuateLP();

        vm.expectRevert("Frozen");
        locker.collectFees();
    }

    // ── the hatch closes, both ways ───────────────────────────────────────────

    /// The guardrail that matters most: a hatch nobody closes must close itself.
    function test_windowExpiresOnItsOwn() public {
        vm.warp(block.timestamp + locker.EVACUATION_WINDOW());
        assertFalse(locker.evacuationOpen(), "shut at the deadline");

        vm.prank(OWNER);
        vm.expectRevert("Evacuation window closed");
        locker.evacuateLP();

        assertEq(pm.liq(1), 1e18, "liquidity untouched");
    }

    function test_lockLPClosesItEarlyAndForever() public {
        vm.prank(OWNER);
        locker.lockLP();

        assertTrue(locker.lpPermanentlyLocked());
        assertFalse(locker.evacuationOpen());

        vm.prank(OWNER);
        vm.expectRevert("Evacuation window closed");
        locker.evacuateLP();

        // one-way: no path back, by anyone
        vm.prank(OWNER);
        vm.expectRevert("Already locked");
        locker.lockLP();
    }

    function test_punchcardCanAlsoLockButNotEvacuate() public {
        vm.prank(WINDDOWN);
        locker.lockLP();
        assertTrue(locker.lpPermanentlyLocked(), "controller may close the hatch");
    }

    // ── access control ────────────────────────────────────────────────────────

    function test_onlyOwnerMayEvacuate() public {
        vm.prank(PUNCHCARD);
        vm.expectRevert("Not owner");
        locker.evacuateLP();

        vm.prank(WINDDOWN);
        vm.expectRevert("Not owner");
        locker.evacuateLP();

        vm.prank(address(0xBAD));
        vm.expectRevert("Not owner");
        locker.evacuateLP();
    }

    function test_strangerCannotLock() public {
        vm.prank(address(0xBAD));
        vm.expectRevert("Not authorised");
        locker.lockLP();
    }

    // ── production must be untouched ──────────────────────────────────────────

    /// The point of the whole separation. Production LPLocker must have no evacuation
    /// path at all — not a closed one, not a guarded one. None.
    function test_productionLockerHasNoEvacuationPath() public {
        LPLocker prod = new LPLocker(
            address(merchant), OWNER, WINDDOWN, address(pm), FACTORY,
            address(usdc), address(weth), PUNCHCARD
        );

        (bool okEvac,) = address(prod).call(abi.encodeWithSignature("evacuateLP()"));
        assertFalse(okEvac, "production must not expose evacuateLP");

        (bool okLock,) = address(prod).call(abi.encodeWithSignature("lockLP()"));
        assertFalse(okLock, "production must not expose lockLP");

        (bool okOpen,) = address(prod).call(abi.encodeWithSignature("evacuationOpen()"));
        assertFalse(okOpen, "production must not expose evacuationOpen");
    }
}
