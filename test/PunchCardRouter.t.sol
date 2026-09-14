// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/PunchCardRouter.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Tok is ERC20 {
    uint8 private _d;
    constructor(string memory n, uint8 d) ERC20(n, n) { _d = d; }
    function decimals() public view override returns (uint8) { return _d; }
    function mint(address a, uint256 v) external { _mint(a, v); }
}

contract MockWETH is Tok {
    constructor() Tok("WETH", 18) {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
}

/// Prices every swap off a fixed rate table, so the test controls the exchange rate.
contract MockSwapRouter {
    mapping(address => mapping(address => uint256)) public rateNum;
    mapping(address => mapping(address => uint256)) public rateDen;

    function setRate(address i, address o, uint256 n, uint256 d) external {
        rateNum[i][o] = n; rateDen[i][o] = d;
    }

    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata p)
        external returns (uint256 amountOut)
    {
        ERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        amountOut = (p.amountIn * rateNum[p.tokenIn][p.tokenOut]) / rateDen[p.tokenIn][p.tokenOut];
        require(amountOut >= p.amountOutMinimum, "Too little received");
        Tok(p.tokenOut).mint(p.recipient, amountOut);
    }
}

contract MockLocker {
    function usdcFeeTier() external pure returns (uint24) { return 3000; }
    function ethFeeTier()  external pure returns (uint24) { return 3000; }
}

contract MockWDC {
    mapping(address => bool) public registered;
    address public locker;
    constructor() { locker = address(new MockLocker()); }
    function setRegistered(address t, bool v) external { registered[t] = v; }
    function isRegistered(address t) external view returns (bool) { return registered[t]; }
    // Both were hardcoded false, so neither wind-down state was ever exercised — the
    // router's wind-down policy passed every test without a single one reaching it.
    mapping(address => bool) public complete;
    mapping(address => bool) public initiated;
    function setComplete(address t, bool v)  external { complete[t] = v; }
    function setInitiated(address t, bool v) external { initiated[t] = v; }
    function isComplete(address t) external view returns (bool) { return complete[t]; }
    function isInitiated(address t) external view returns (bool) { return initiated[t]; }

    /// The router reads fee tiers via getSuite(token).lpLocker
    function getSuite(address) external view returns (IWindDownController.WindDownSuite memory s) {
        s.lpLocker = locker;
    }
}

contract PunchCardRouterTest is Test {
    Tok skoop; Tok frothy; Tok usdc; Tok weth;
    MockSwapRouter uni; MockWDC wdc; PunchCardRouter router;

    address constant MULTISIG = address(0x0451);
    address constant FEES     = address(0xFEE5);
    address constant USER     = address(0x5E12);

    function setUp() public {
        skoop  = new Tok("SKOOP", 6);
        frothy = new Tok("FROTHY", 6);
        usdc   = new Tok("USDC", 6);
        weth   = new MockWETH();
        uni    = new MockSwapRouter();
        wdc    = new MockWDC();

        router = new PunchCardRouter(MULTISIG, address(wdc), address(uni), address(usdc), address(weth), 30, FEES);

        wdc.setRegistered(address(skoop), true);
        wdc.setRegistered(address(frothy), true);

        // 1 SKOOP = $0.002, 1 FROTHY = $0.004
        uni.setRate(address(skoop), address(usdc), 2, 1000);
        uni.setRate(address(usdc), address(frothy), 1000, 4);
        uni.setRate(address(skoop), address(weth), 667_000, 1);   // $0.002/SKOOP at $3k ETH

        skoop.mint(USER, 1_000_000 * 1e6);
        vm.prank(USER);
        skoop.approve(address(router), type(uint256).max);
    }

    function _p(address i, address o, uint256 amt, uint256 m1, uint256 m2)
        internal view returns (PunchCardRouter.SwapParams memory)
    {
        return _p(i, o, amt, m1, m2, address(usdc));
    }

    function _p(address i, address o, uint256 amt, uint256 m1, uint256 m2, address mid)
        internal view returns (PunchCardRouter.SwapParams memory)
    {
        return PunchCardRouter.SwapParams({
            tokenIn: i, tokenOut: o, amountIn: amt,
            amountOutMinimumHop1: m1, amountOutMinimumHop2: m2,
            midToken: mid, recipient: USER, deadline: block.timestamp + 1
        });
    }

    /// The headline feature: SKOOP -> FROTHY in one call. This reverted unconditionally
    /// under the old price-impact guard.
    function test_crossMerchantSwapWorks() public {
        uint256 amountIn = 100_000 * 1e6;          // 100k SKOOP = $200
        vm.prank(USER);
        router.swap(_p(address(skoop), address(frothy), amountIn, 0, 0));

        // $200 -> 30bps fee -> $199.40 -> FROTHY at $0.004
        assertEq(usdc.balanceOf(FEES), 600_000, "PunchCard takes 30bps of the midpoint");
        assertEq(frothy.balanceOf(USER), 49_850 * 1e6, "user receives FROTHY");
    }

    /// WETH is 18dp against a 6dp merchant token — the case the old guard broke hardest.
    function test_tokenToWethWorks() public {
        vm.prank(USER);
        router.swap(_p(address(skoop), address(weth), 1_000 * 1e6, 0, 0));
        assertGt(weth.balanceOf(USER), 0, "decimals mismatch must not block the swap");
    }

    /// The minimum must hold against what is actually delivered, not the pre-fee amount.
    function test_minimumIsEnforcedAfterFee() public {
        uint256 amountIn = 100_000 * 1e6;           // -> $200 gross, $199.40 net
        vm.prank(USER);
        vm.expectRevert("Below minimum after fee");
        router.swap(_p(address(skoop), address(usdc), amountIn, 200 * 1e6, 0));

        vm.prank(USER);
        router.swap(_p(address(skoop), address(usdc), amountIn, 199 * 1e6, 0));
        assertEq(usdc.balanceOf(USER), 199_400_000, "net of the 30bps fee");
    }

    /// Only tokens PunchCard deployed may route.
    function test_unregisteredTokenRejected() public {
        Tok rogue = new Tok("ROGUE", 6);
        rogue.mint(USER, 1e12);
        vm.startPrank(USER);
        rogue.approve(address(router), type(uint256).max);
        vm.expectRevert("Token not on network");
        router.swap(_p(address(rogue), address(frothy), 1e6, 0, 0));
        vm.stopPrank();
    }

    /// The point of best execution: the ETH pool must be able to carry network flow too.
    /// Routing was previously hardcoded to USDC, so every merchant's ETH seed was capital
    /// that structurally could not earn from cross-merchant swaps.
    function test_crossMerchantSwapCanRouteViaWeth() public {
        uni.setRate(address(weth), address(frothy), 1, 1_334_000);   // back out to $0.004 FROTHY

        uint256 amountIn = 1_000 * 1e6;
        vm.prank(USER);
        router.swap(_p(address(skoop), address(frothy), amountIn, 0, 0, address(weth)));

        assertGt(frothy.balanceOf(USER), 0, "swap routed through the ETH pool");
        assertGt(weth.balanceOf(FEES), 0, "and PunchCard's fee is taken in WETH");
        assertEq(usdc.balanceOf(FEES), 0, "the USDC pool was not touched");
    }

    /// Both routes must work, so an interface can quote and pick.
    function test_bothRoutesAvailable() public {
        uni.setRate(address(weth), address(frothy), 1, 1_334_000);

        uint256 before_ = frothy.balanceOf(USER);
        vm.prank(USER);
        router.swap(_p(address(skoop), address(frothy), 1_000 * 1e6, 0, 0, address(usdc)));
        uint256 viaUsdc = frothy.balanceOf(USER) - before_;

        before_ = frothy.balanceOf(USER);
        vm.prank(USER);
        router.swap(_p(address(skoop), address(frothy), 1_000 * 1e6, 0, 0, address(weth)));
        uint256 viaWeth = frothy.balanceOf(USER) - before_;

        assertGt(viaUsdc, 0, "USDC route delivers");
        assertGt(viaWeth, 0, "WETH route delivers");
        // Both are live, so an interface can quote each and send the better one.
    }

    function test_rejectsBogusMidToken() public {
        vm.prank(USER);
        vm.expectRevert("Invalid mid token");
        router.swap(_p(address(skoop), address(frothy), 1_000 * 1e6, 0, 0, address(skoop)));
    }

    // ── failure cases: every path's minimum must actually bind ───────────────

    /// stable -> token: the fee is taken from amountIn BEFORE the swap, so
    /// amountOutMinimumHop1 bounds what the recipient actually receives.
    function test_stableToToken_minimumBinds() public {
        usdc.mint(USER, 10 * 1e6);
        vm.prank(USER);
        usdc.approve(address(router), type(uint256).max);

        // 1 USDC in, 30bps fee -> 0.997 swapped, FROTHY at $0.004 -> 249.25 FROTHY
        uint256 amountIn = 1e6;
        uint256 expected = 249_250_000;

        vm.prank(USER);
        vm.expectRevert("Too little received");
        router.swap(_p(address(usdc), address(frothy), amountIn, expected + 1, 0));

        vm.prank(USER);
        router.swap(_p(address(usdc), address(frothy), amountIn, expected, 0));
        assertEq(frothy.balanceOf(USER), expected, "exactly the boundary still executes");
    }

    /// token -> token: hop1's minimum bounds the midpoint, hop2's bounds the final output.
    /// They must be enforced independently — a generous hop1 must not mask a failing hop2.
    function test_tokenToToken_hop2MinimumBinds() public {
        uint256 amountIn = 100_000 * 1e6;   // $200 of SKOOP
        uint256 expected = 49_850 * 1e6;    // after the 30bps midpoint skim

        vm.prank(USER);
        vm.expectRevert("Too little received");
        router.swap(_p(address(skoop), address(frothy), amountIn, 0, expected + 1));

        vm.prank(USER);
        router.swap(_p(address(skoop), address(frothy), amountIn, 0, expected));
        assertEq(frothy.balanceOf(USER), expected, "hop2 minimum binds at the boundary");
    }

    /// ...and hop1's minimum binds on the midpoint, before the fee is skimmed.
    function test_tokenToToken_hop1MinimumBindsOnMidpoint() public {
        uint256 amountIn = 100_000 * 1e6;
        uint256 midpoint = 200 * 1e6;       // $200 gross, pre-fee

        vm.prank(USER);
        vm.expectRevert("Too little received");
        router.swap(_p(address(skoop), address(frothy), amountIn, midpoint + 1, 0));
    }

    /// Routing via WETH must skim the fee in WETH, at the midpoint, at the configured rate.
    /// The decimals differ across the hop (6dp token -> 18dp WETH -> 6dp token), which is
    /// where a units error would hide.
    function test_wethMidpointFeeMath() public {
        uni.setRate(address(weth), address(frothy), 1, 1_334_000);

        uint256 amountIn = 1_000 * 1e6;                 // 1,000 SKOOP
        uint256 midOut   = amountIn * 667_000;          // -> wei, per the fixture rate
        uint256 expFee   = midOut * 30 / 10_000;        // 30 bps, in WETH

        vm.prank(USER);
        router.swap(_p(address(skoop), address(frothy), amountIn, 0, 0, address(weth)));

        assertEq(weth.balanceOf(FEES), expFee, "fee skimmed in WETH at the midpoint");
        assertEq(usdc.balanceOf(FEES), 0,      "USDC pool untouched on a WETH route");
        assertEq(frothy.balanceOf(USER), (midOut - expFee) / 1_334_000, "output is net of the fee");
    }

    /// The same trade routed either way must differ only by the route, never by the rate.
    function test_feeRateIsIdenticalAcrossRoutes() public {
        uni.setRate(address(weth), address(frothy), 1, 1_334_000);
        uint256 amountIn = 100_000 * 1e6;

        vm.prank(USER);
        router.swap(_p(address(skoop), address(frothy), amountIn, 0, 0, address(usdc)));
        uint256 usdcFee = usdc.balanceOf(FEES);

        vm.prank(USER);
        router.swap(_p(address(skoop), address(frothy), amountIn, 0, 0, address(weth)));
        uint256 wethFee = weth.balanceOf(FEES);

        // both are 30bps of their own midpoint; compare as a rate, not an amount
        assertEq(usdcFee * 10_000 / (amountIn * 2 / 1000), 30, "USDC route charges 30bps");
        assertEq(wethFee * 10_000 / (amountIn * 667_000),  30, "WETH route charges 30bps");
    }

    // ── where the money goes on each real-world flow ─────────────────────────

    /// Coffee -> Pizza. Two hops through USDC, and PunchCard's router fee is skimmed once,
    /// at the midpoint, in USDC. Neither merchant token is ever taken.
    function test_crossMerchantSwap_feeTakenOnceInPairAsset() public {
        uint256 amountIn = 100_000 * 1e6;
        vm.prank(USER);
        router.swap(_p(address(skoop), address(frothy), amountIn, 0, 0));

        // $200 midpoint, 30bps
        assertEq(usdc.balanceOf(FEES), 600_000, "router fee taken once, in USDC");
        assertEq(skoop.balanceOf(FEES),  0, "PunchCard never holds the origin merchant token");
        assertEq(frothy.balanceOf(FEES), 0, "nor the destination merchant token");
    }

    /// A customer buying a merchant token with USDC. The fee comes off the USDC input
    /// before the swap, so PunchCard is paid in the pair asset and the customer receives
    /// the token net of it.
    function test_customerBuysWithUsdc_feeInUsdc() public {
        usdc.mint(USER, 10 * 1e6);
        vm.prank(USER);
        usdc.approve(address(router), type(uint256).max);

        vm.prank(USER);
        router.swap(_p(address(usdc), address(frothy), 1e6, 0, 0));

        assertEq(usdc.balanceOf(FEES), 3_000, "30bps of the USDC input");
        assertEq(frothy.balanceOf(FEES), 0,   "PunchCard holds none of the merchant token");
        assertEq(frothy.balanceOf(USER), 249_250_000, "customer receives the rest");
    }

    /// A customer paying with native ETH should not need a separate wrap and approve. The
    /// router accepts ETH only when the input is WETH, wraps it, skims the WETH fee, and
    /// swaps the remainder.
    function test_customerBuysWithNativeEth_wrapsAndSwaps() public {
        uni.setRate(address(weth), address(frothy), 750_000 * 1e6, 1 ether);
        vm.deal(USER, 1 ether);

        vm.prank(USER);
        router.swap{value: 1 ether}(_p(address(weth), address(frothy), 1 ether, 747_750 * 1e6, 0));

        assertEq(weth.balanceOf(FEES), 0.003 ether, "30bps of the ETH input, held as WETH");
        assertEq(frothy.balanceOf(USER), 747_750 * 1e6, "customer receives the WETH route output");
        assertEq(weth.balanceOf(address(router)), 0, "no wrapped ETH stranded in the router");
        assertEq(address(router).balance, 0, "no native ETH stranded in the router");
    }

    function test_customerBuysWithAlreadyWrappedEth_stillWorks() public {
        uni.setRate(address(weth), address(frothy), 750_000 * 1e6, 1 ether);
        weth.mint(USER, 1 ether);
        vm.prank(USER);
        weth.approve(address(router), type(uint256).max);

        vm.prank(USER);
        router.swap(_p(address(weth), address(frothy), 1 ether, 747_750 * 1e6, 0));

        assertEq(weth.balanceOf(FEES), 0.003 ether, "30bps of the WETH input");
        assertEq(frothy.balanceOf(USER), 747_750 * 1e6, "same output as native ETH path");
        assertEq(weth.balanceOf(address(router)), 0, "no WETH stranded");
    }

    function test_nativeEthRequiresWethInput() public {
        vm.deal(USER, 1 ether);

        vm.prank(USER);
        vm.expectRevert("ETH only for WETH input");
        router.swap{value: 1 ether}(_p(address(usdc), address(frothy), 1 ether, 0, 0));

        assertEq(address(router).balance, 0, "reverted ETH is not stranded");
        assertEq(weth.balanceOf(address(router)), 0, "no WETH minted before rejection");
    }

    function test_nativeEthMustMatchAmountIn() public {
        vm.deal(USER, 1 ether);

        vm.prank(USER);
        vm.expectRevert("ETH amount mismatch");
        router.swap{value: 1 ether}(_p(address(weth), address(frothy), 0.5 ether, 0, 0));

        assertEq(address(router).balance, 0, "mismatched ETH is not stranded");
        assertEq(weth.balanceOf(address(router)), 0, "no WETH minted before rejection");
    }

    // ── WIND-DOWN POLICY: the router gates membership, not health ─────────────

    /// A merchant winding down is still a merchant. initiate() is onlyMultisig, so
    /// blocking buys here would have let PunchCard make a token unbuyable on the official
    /// route by fiat — a kill switch over someone else's market. Wind-down is disclosed in
    /// the interface instead. The trade was never actually preventable: these are ordinary
    /// Uniswap pools.
    function test_windDownInitiated_doesNotBlockBuying() public {
        wdc.setInitiated(address(frothy), true);
        uni.setRate(address(usdc), address(frothy), 1_000_000, 1);
        usdc.mint(USER, 100e6);
        vm.prank(USER);
        usdc.approve(address(router), type(uint256).max);

        vm.prank(USER);
        router.swap(_p(address(usdc), address(frothy), 100e6, 0, 0));

        assertGt(frothy.balanceOf(USER), 0, "a token in wind-down is still buyable");
    }

    /// And selling out of one must never be blocked — that is the holder's exit.
    function test_windDownInitiated_doesNotBlockSelling() public {
        wdc.setInitiated(address(frothy), true);
        uni.setRate(address(frothy), address(usdc), 1, 1_000_000);
        frothy.mint(USER, 100_000_000e6);
        vm.prank(USER);
        frothy.approve(address(router), type(uint256).max);

        vm.prank(USER);
        router.swap(_p(address(frothy), address(usdc), 100_000_000e6, 0, 0));

        assertGt(usdc.balanceOf(USER), 0, "holders can always exit a winding-down token");
    }

    /// Completion is a membership question, not a health one: the suite has settled and
    /// there is no PunchCard merchant left to route for. Uniswap stays open — 10% of
    /// liquidity remains in the pool permanently — so this scopes the router, it does not
    /// strand anyone.
    function test_windDownComplete_isRejectedBothWays() public {
        wdc.setComplete(address(frothy), true);
        usdc.mint(USER, 100e6);
        frothy.mint(USER, 100e6);
        vm.startPrank(USER);
        usdc.approve(address(router), type(uint256).max);
        frothy.approve(address(router), type(uint256).max);

        vm.expectRevert("Token wind-down complete");
        router.swap(_p(address(usdc), address(frothy), 100e6, 0, 0));

        vm.expectRevert("Token wind-down complete");
        router.swap(_p(address(frothy), address(usdc), 100e6, 0, 0));
        vm.stopPrank();
    }

    /// A customer cashing out. The fee is taken from the USDC proceeds, never from the
    /// merchant token being sold.
    function test_customerSellsForUsdc_feeStillInUsdc() public {
        vm.prank(USER);
        router.swap(_p(address(skoop), address(usdc), 100_000 * 1e6, 0, 0));

        assertEq(usdc.balanceOf(FEES), 600_000, "fee in USDC, off the proceeds");
        assertEq(skoop.balanceOf(FEES), 0, "the token sold is never taken");
    }

    function test_feeRateCeiling() public {
        PunchCardRouter.RouterParams memory bad = PunchCardRouter.RouterParams({
            feeRate: 101, feeRecipient: FEES
        });
        vm.prank(MULTISIG);
        vm.expectRevert("Fee exceeds ceiling");
        router.proposeChange(bad);
    }
}
