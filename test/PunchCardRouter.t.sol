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
    function isComplete(address) external pure returns (bool) { return false; }
    function isInitiated(address) external pure returns (bool) { return false; }

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
        weth   = new Tok("WETH", 18);
        uni    = new MockSwapRouter();
        wdc    = new MockWDC();

        router = new PunchCardRouter(MULTISIG, address(wdc), address(uni), address(usdc), address(weth), 30, FEES);

        wdc.setRegistered(address(skoop), true);
        wdc.setRegistered(address(frothy), true);

        // 1 SKOOP = $0.002, 1 FROTHY = $0.004
        uni.setRate(address(skoop), address(usdc), 2, 1000);
        uni.setRate(address(usdc), address(frothy), 1000, 4);
        uni.setRate(address(skoop), address(weth), 1, 1_000_000_000);

        skoop.mint(USER, 1_000_000 * 1e6);
        vm.prank(USER);
        skoop.approve(address(router), type(uint256).max);
    }

    function _p(address i, address o, uint256 amt, uint256 m1, uint256 m2)
        internal view returns (PunchCardRouter.SwapParams memory)
    {
        return PunchCardRouter.SwapParams({
            tokenIn: i, tokenOut: o, amountIn: amt,
            amountOutMinimumHop1: m1, amountOutMinimumHop2: m2,
            recipient: USER, deadline: block.timestamp + 1
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

    function test_feeRateCeiling() public {
        PunchCardRouter.RouterParams memory bad = PunchCardRouter.RouterParams({
            feeRate: 101, feeRecipient: FEES
        });
        vm.prank(MULTISIG);
        vm.expectRevert("Fee exceeds ceiling");
        router.proposeChange(bad);
    }
}
