// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/WindDownController.sol";
import "../contracts/RewardEscrow.sol";
import "../contracts/VestingWallet.sol";
import "../contracts/TreasuryTimelock.sol";
import "../contracts/LPLocker.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract Tok is ERC20, ERC20Burnable {
    string private _n;
    constructor(string memory n) ERC20(n, n) { _n = n; }
    function mint(address a, uint256 v) external { _mint(a, v); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/// Position manager stub: fixed liquidity, and collect() pays out whatever was set.
contract MockPM {
    struct P { address t0; address t1; uint128 liq; }
    mapping(uint256 => P) public pos;
    mapping(uint256 => uint256) public out0;
    mapping(uint256 => uint256) public out1;
    uint128 public lastDecrease;

    function setPos(uint256 id, address a, address b, uint128 l) external { pos[id] = P(a,b,l); }
    function setOut(uint256 id, uint256 a, uint256 b) external { out0[id]=a; out1[id]=b; }

    function positions(uint256 id) external view returns (
        uint96, address, address t0, address t1, uint24, int24, int24,
        uint128 liq, uint256, uint256, uint128, uint128
    ) { P memory p = pos[id]; return (0, address(0), p.t0, p.t1, 3000, 0, 0, p.liq, 0, 0, 0, 0); }

    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata p)
        external returns (uint256, uint256)
    { lastDecrease = p.liquidity; return (0, 0); }

    function collect(INonfungiblePositionManager.CollectParams calldata p)
        external returns (uint256 a0, uint256 a1)
    {
        a0 = out0[p.tokenId]; a1 = out1[p.tokenId];
        P memory q = pos[p.tokenId];
        if (a0 > 0) Tok(q.t0).mint(p.recipient, a0);
        if (a1 > 0) Tok(q.t1).mint(p.recipient, a1);
    }
    /// Consumes only `useRatio` of each desired amount, mimicking Uniswap bounding
    /// liquidity by whichever side is scarcer. The rest is dust.
    uint256 public useNum = 1;
    uint256 public useDen = 1;
    function setUse(uint256 n, uint256 d) external { useNum = n; useDen = d; }

    function increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams calldata p)
        external returns (uint128, uint256 used0, uint256 used1)
    {
        used0 = p.amount0Desired * useNum / useDen;
        used1 = p.amount1Desired * useNum / useDen;
        return (1, used0, used1);
    }
}

contract WindDownTest is Test {
    Tok token; Tok usdc; Tok weth;
    MockPM pm;
    WindDownController wdc;
    RewardEscrow escrow; VestingWallet vesting; TreasuryTimelock treasury; LPLocker locker;

    address constant MULTISIG = address(0xA1);
    address constant FACTORY  = address(0xFAC7);
    address constant OWNER    = address(0x0B1);
    address constant TEAM     = address(0x7EA3);
    address constant OP       = address(0x0B3);
    address constant PCFEE    = address(0xFEE5);
    address constant RAND     = address(0x4A4D);

    uint256 constant REWARDS  = 45_000_000 * 1e6;
    uint256 constant TEAM_A   = 15_000_000 * 1e6;
    uint256 constant TREAS_A  = 10_000_000 * 1e6;
    uint256 constant RESERVE  = 27_000_000 * 1e6;

    function setUp() public {
        token = new Tok("MERCH"); usdc = new Tok("USDC"); weth = new Tok("WETH");
        pm = new MockPM();
        wdc = new WindDownController(MULTISIG, FACTORY);

        escrow   = new RewardEscrow(address(token), OP, OWNER, address(wdc), REWARDS, 1e6, 20_000*1e6);
        vesting  = new VestingWallet(address(token), TEAM, address(wdc), 180 days, 1080 days);
        treasury = new TreasuryTimelock(address(token), OWNER, address(wdc), 90 days);
        locker   = new LPLocker(address(token), OWNER, address(wdc), address(pm), FACTORY,
                                address(usdc), address(weth), PCFEE);

        token.mint(address(escrow), REWARDS);
        token.mint(address(vesting), TEAM_A);
        token.mint(address(treasury), TREAS_A);
        token.mint(address(locker), RESERVE);

        // merchant token is token0 in the USDC pool, token1 in the ETH pool
        pm.setPos(1, address(token), address(usdc), 1_000_000);
        pm.setPos(2, address(weth), address(token), 1_000_000);
        vm.prank(FACTORY);
        locker.initializeLP(1, 2, 3000, 3000);

        vm.prank(FACTORY);
        wdc.register(address(token), address(escrow), address(vesting), address(treasury), address(locker));
    }

    // ── access control ───────────────────────────────────────────────────────

    function test_onlyFactoryRegisters() public {
        vm.prank(RAND);
        vm.expectRevert("Not factory");
        wdc.register(address(0x1), address(0x2), address(0x3), address(0x4), address(0x5));
    }

    function test_onlyMultisigInitiates() public {
        vm.prank(RAND);
        vm.expectRevert("Not multisig");
        wdc.initiate(address(token));

        vm.prank(OWNER);   // not even the merchant
        vm.expectRevert("Not multisig");
        wdc.initiate(address(token));
    }

    function test_cannotRegisterTwice() public {
        vm.prank(FACTORY);
        vm.expectRevert("Already registered");
        wdc.register(address(token), address(escrow), address(vesting), address(treasury), address(locker));
    }

    function test_unregisteredTokenRejected() public {
        vm.prank(MULTISIG);
        vm.expectRevert("Not registered");
        wdc.initiate(address(0xBEEF));
    }

    function test_cannotInitiateTwice() public {
        vm.startPrank(MULTISIG);
        wdc.initiate(address(token));
        vm.expectRevert("Already initiated");
        wdc.initiate(address(token));
        vm.stopPrank();
    }

    // ── initiation freezes everything at once ────────────────────────────────

    function test_initiateFreezesAllThree() public {
        vm.prank(MULTISIG);
        wdc.initiate(address(token));

        assertTrue(escrow.isFrozen(), "escrow frozen");
        assertTrue(locker.isFrozen(), "locker frozen");

        vm.prank(OP);
        vm.expectRevert("Frozen");
        escrow.distributeReward(RAND, 1e6);

        vm.prank(OWNER);
        vm.expectRevert("Frozen");
        treasury.submitRelease(1e6);
    }

    // ── the timer cannot be skipped ──────────────────────────────────────────

    function test_cannotSettleBeforeExpiry() public {
        vm.prank(MULTISIG);
        wdc.initiate(address(token));
        vm.warp(block.timestamp + 365 days - 1);

        vm.expectRevert("Not expired");
        wdc.onExpiryBurnEscrow(address(token));
        vm.expectRevert("Not expired");
        wdc.onExpiryBurnTreasury(address(token));
        vm.expectRevert("Not expired");
        wdc.onExpirySettleVesting(address(token));
    }

    function test_cannotSettleBeforeInitiation() public {
        vm.expectRevert("Not initiated");
        wdc.onExpiryBurnEscrow(address(token));
    }

    // ── LP release is gated on all three, in any order ───────────────────────

    function test_lpReleaseRequiresAllThreeSteps() public {
        _initiateAndExpire();
        wdc.onExpiryBurnEscrow(address(token));
        wdc.onExpiryBurnTreasury(address(token));

        vm.expectRevert("Settle other steps first");
        wdc.onExpiryReleaseLP(address(token));

        wdc.onExpirySettleVesting(address(token));
        wdc.onExpiryReleaseLP(address(token));   // now allowed
        assertTrue(wdc.isComplete(address(token)));
    }

    /// Order must not matter, or an operator could brick a wind-down by sequencing.
    function test_stepsAreOrderIndependent() public {
        _initiateAndExpire();
        wdc.onExpirySettleVesting(address(token));
        wdc.onExpiryBurnTreasury(address(token));
        wdc.onExpiryBurnEscrow(address(token));
        wdc.onExpiryReleaseLP(address(token));
        assertTrue(wdc.isComplete(address(token)));
    }

    function test_stepsAreNotRepeatable() public {
        _initiateAndExpire();
        wdc.onExpiryBurnEscrow(address(token));
        vm.expectRevert("Already settled");
        wdc.onExpiryBurnEscrow(address(token));

        wdc.onExpiryBurnTreasury(address(token));
        wdc.onExpirySettleVesting(address(token));
        wdc.onExpiryReleaseLP(address(token));
        vm.expectRevert("Already complete");
        wdc.onExpiryReleaseLP(address(token));
    }

    /// Settlement is permissionless once expired — nobody can hold a merchant hostage.
    function test_settlementIsPermissionless() public {
        _initiateAndExpire();
        vm.startPrank(RAND);
        wdc.onExpiryBurnEscrow(address(token));
        wdc.onExpiryBurnTreasury(address(token));
        wdc.onExpirySettleVesting(address(token));
        wdc.onExpiryReleaseLP(address(token));
        vm.stopPrank();
        assertTrue(wdc.isComplete(address(token)));
    }

    // ── the money actually moves correctly ───────────────────────────────────

    function test_escrowAndTreasuryAreBurned() public {
        _initiateAndExpire();
        uint256 before_ = token.totalSupply();
        wdc.onExpiryBurnEscrow(address(token));
        wdc.onExpiryBurnTreasury(address(token));
        assertEq(token.balanceOf(address(escrow)), 0, "escrow emptied");
        assertEq(token.balanceOf(address(treasury)), 0, "treasury emptied");
        assertEq(before_ - token.totalSupply(), REWARDS + TREAS_A, "both burned, not moved");
    }

    /// 90% of liquidity out, 10% left permanently; merchant tokens burned, pair assets paid.
    function test_lpReleaseSplitsAndBurns() public {
        _initiateAndExpire();
        pm.setOut(1, 500 * 1e6, 900 * 1e6);      // token0=MERCH, token1=USDC
        pm.setOut(2, 3 * 1e6,   400 * 1e6);      // token0=WETH,  token1=MERCH

        wdc.onExpiryBurnEscrow(address(token));
        wdc.onExpiryBurnTreasury(address(token));
        wdc.onExpirySettleVesting(address(token));

        uint256 supplyBefore = token.totalSupply();
        wdc.onExpiryReleaseLP(address(token));

        assertEq(pm.lastDecrease(), 900_000, "90% of liquidity withdrawn, 10% left");
        assertEq(usdc.balanceOf(OWNER), 900 * 1e6, "USDC to the merchant");
        assertEq(weth.balanceOf(OWNER), 3 * 1e6,   "WETH to the merchant");

        // The 27M reserve AND the 900 of collected merchant-token fees are burned. The mock
        // mints collected fees on collect() (a real pool pays them from existing supply), so
        // the net supply change here is the reserve alone — the 900 was minted then burned.
        assertEq(supplyBefore - token.totalSupply(), RESERVE, "reserve burned, fees minted-then-burned");
        assertEq(token.balanceOf(address(locker)), 0, "every merchant token in the locker is gone");
        assertEq(token.balanceOf(OWNER), 0, "merchant receives pair assets, never tokens");
    }

    /// A wind-down must complete even when every contract is already empty —
    /// otherwise an unused merchant could brick at the LP gate forever.
    function test_windDownCompletesOnAnEmptySuite() public {
        Tok t2 = new Tok("EMPTY");
        RewardEscrow e2  = new RewardEscrow(address(t2), OP, OWNER, address(wdc), REWARDS, 1e6, 20_000*1e6);
        VestingWallet v2 = new VestingWallet(address(t2), TEAM, address(wdc), 180 days, 1080 days);
        TreasuryTimelock r2 = new TreasuryTimelock(address(t2), OWNER, address(wdc), 90 days);
        LPLocker l2 = new LPLocker(address(t2), OWNER, address(wdc), address(pm), FACTORY,
                                   address(usdc), address(weth), PCFEE);
        pm.setPos(3, address(t2), address(usdc), 0);   // zero liquidity
        pm.setPos(4, address(weth), address(t2), 0);
        vm.prank(FACTORY); l2.initializeLP(3, 4, 3000, 3000);
        vm.prank(FACTORY); wdc.register(address(t2), address(e2), address(v2), address(r2), address(l2));

        vm.prank(MULTISIG); wdc.initiate(address(t2));
        vm.warp(block.timestamp + 365 days);

        wdc.onExpiryBurnEscrow(address(t2));
        wdc.onExpiryBurnTreasury(address(t2));
        wdc.onExpirySettleVesting(address(t2));
        wdc.onExpiryReleaseLP(address(t2));
        assertTrue(wdc.isComplete(address(t2)), "empty suite still completes");
    }

    // ── regressions from the external review (2026-09-13) ────────────────────

    /// addLiquidity(X, 0, 0, 0) added no liquidity — both mint branches need BOTH halves —
    /// yet still decremented _reserveTokens, stranding X tokens permanently: they stayed in
    /// the locker balance, could never be deployed again, and burned at wind-down.
    function test_addLiquidityRejectsHalfASide() public {
        uint256 before_ = locker.reserveTokens();

        vm.prank(OWNER);
        vm.expectRevert("USDC side needs both amounts");
        locker.addLiquidity(1_000_000, 0, 0, 0, 0, 0, 0, 0);

        vm.prank(OWNER);
        vm.expectRevert("ETH side needs both amounts");
        locker.addLiquidity(0, 1_000_000, 0, 0, 0, 0, 0, 0);

        assertEq(locker.reserveTokens(), before_, "reserve must be untouched by a rejected call");
    }

    /// Only the merchant may deploy reserve.
    function test_addLiquidityIsOwnerOnly() public {
        vm.prank(RAND);
        vm.expectRevert("Not owner");
        locker.addLiquidity(1_000_000, 0, 1_000_000, 0, 0, 0, 0, 0);
    }

    /// Reserve is a hard ceiling.
    function test_addLiquidityCannotExceedReserve() public {
        vm.prank(OWNER);
        vm.expectRevert("Exceeds reserve");
        locker.addLiquidity(RESERVE + 1, 0, 1_000_000, 0, 0, 0, 0, 0);
    }

    /// The LP lock must survive a deliberately off-ratio add.
    ///
    /// Supplying a large token amount against a trivial pair amount makes Uniswap consume
    /// almost none of the tokens. The unused remainder used to be transferred to
    /// ownerWallet as "dust" while the reserve was decremented by the DESIRED amount — so
    /// a merchant could drain the whole 27M reserve into their own wallet in one call, with
    /// the accounting left looking consistent.
    function test_addLiquidityCannotDrainReserveAsDust() public {
        pm.setUse(1, 1000);          // Uniswap consumes 0.1% of what was offered
        usdc.mint(OWNER, 1_000_000);
        vm.prank(OWNER);
        usdc.approve(address(locker), type(uint256).max);

        uint256 ownerTokensBefore = token.balanceOf(OWNER);
        uint256 lockerBefore      = token.balanceOf(address(locker));
        uint256 reserveBefore     = locker.reserveTokens();

        uint256 offered = 10_000_000 * 1e6;
        vm.prank(OWNER);
        locker.addLiquidity(offered, 0, 1_000_000, 0, 0, 0, 0, 0);

        assertEq(token.balanceOf(OWNER), ownerTokensBefore,
            "merchant must receive NO merchant tokens back as dust");
        assertEq(token.balanceOf(address(locker)), lockerBefore,
            "unused merchant tokens stay in the locker");

        // reserve falls only by what Uniswap actually consumed, not by what was offered
        uint256 consumed = offered / 1000;
        assertEq(reserveBefore - locker.reserveTokens(), consumed,
            "reserve decrements by actual usage, not the desired amount");
        assertEq(token.balanceOf(address(locker)), locker.reserveTokens() + consumed,
            "balance and reserve accounting stay consistent");
    }

    /// The merchant's own pair capital is still returned.
    function test_addLiquidityReturnsPairDustToMerchant() public {
        pm.setUse(1, 2);
        usdc.mint(OWNER, 1_000_000);
        vm.prank(OWNER);
        usdc.approve(address(locker), type(uint256).max);

        uint256 usdcBefore = usdc.balanceOf(OWNER);
        vm.prank(OWNER);
        locker.addLiquidity(1_000_000 * 1e6, 0, 1_000_000, 0, 0, 0, 0, 0);

        // supplied 1,000,000 USDC, half consumed, half returned
        assertEq(usdcBefore - usdc.balanceOf(OWNER), 500_000, "unused USDC came back");
    }

    function _initiateAndExpire() internal {
        vm.prank(MULTISIG);
        wdc.initiate(address(token));
        vm.warp(block.timestamp + 365 days);
    }
}
