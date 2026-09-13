// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/LPLocker.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract MockToken is ERC20, ERC20Burnable {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// Minimal position manager: reports fixed positions, and pays out fixed fees on collect.
contract MockPM {
    address public t0Usdc; address public t1Usdc;
    address public t0Eth;  address public t1Eth;
    uint256 public f0Usdc; uint256 public f1Usdc;
    uint256 public f0Eth;  uint256 public f1Eth;

    function setUsdc(address a, address b, uint256 x, uint256 y) external { t0Usdc=a; t1Usdc=b; f0Usdc=x; f1Usdc=y; }
    function setEth(address a, address b, uint256 x, uint256 y) external { t0Eth=a; t1Eth=b; f0Eth=x; f1Eth=y; }

    function positions(uint256 tokenId) external view returns (
        uint96, address, address token0, address token1, uint24, int24, int24,
        uint128 liquidity, uint256, uint256, uint128, uint128
    ) {
        if (tokenId == 1) return (0, address(0), t0Usdc, t1Usdc, 3000, 0, 0, 1e18, 0, 0, 0, 0);
        return (0, address(0), t0Eth, t1Eth, 3000, 0, 0, 1e18, 0, 0, 0, 0);
    }

    function collect(INonfungiblePositionManager.CollectParams calldata p)
        external returns (uint256 amount0, uint256 amount1)
    {
        (address a, address b, uint256 x, uint256 y) = p.tokenId == 1
            ? (t0Usdc, t1Usdc, f0Usdc, f1Usdc)
            : (t0Eth,  t1Eth,  f0Eth,  f1Eth);
        if (x > 0) MockToken(a).mint(p.recipient, x);
        if (y > 0) MockToken(b).mint(p.recipient, y);
        return (x, y);
    }
}

contract LPLockerFeesTest is Test {
    MockToken merchant; MockToken usdc; MockToken weth;
    MockPM pm; LPLocker locker;

    address constant OWNER     = address(0xA11CE);
    address constant PUNCHCARD = address(0xB0B);
    address constant WINDDOWN  = address(0xDEAD);
    address constant FACTORY   = address(0xFAC7);

    uint256 constant RESERVE = 27_000_000 * 1e6;

    function setUp() public {
        merchant = new MockToken("Merchant", "MERCH");
        usdc     = new MockToken("USDC", "USDC");
        weth     = new MockToken("WETH", "WETH");
        pm       = new MockPM();

        locker = new LPLocker(
            address(merchant), OWNER, WINDDOWN, address(pm), FACTORY,
            address(usdc), address(weth), PUNCHCARD
        );

        // merchant token is token0 in both pools for this fixture
        pm.setUsdc(address(merchant), address(usdc), 1_000 * 1e6, 500 * 1e6);
        pm.setEth(address(merchant), address(weth),   400 * 1e6, 2 ether);

        vm.prank(FACTORY);
        locker.initializeLP(1, 2, 3000, 3000);

        // the 27M reserve lives in the locker alongside any collected fees
        merchant.mint(address(locker), RESERVE);
    }

    /// The invariant: fees come from collect()'s return values, so the reserve is untouched.
    function test_reserveIsNeverBurned() public {
        assertEq(merchant.balanceOf(address(locker)), RESERVE);
        locker.collectFees();
        assertEq(
            merchant.balanceOf(address(locker)), RESERVE,
            "collectFees must not touch the LP reserve"
        );
    }

    function test_splitsPairTokens80_20() public {
        locker.collectFees();
        // USDC fees 500, ETH-pool WETH fees 2e18
        assertEq(usdc.balanceOf(PUNCHCARD), 100 * 1e6,  "PunchCard 20% of USDC");
        assertEq(usdc.balanceOf(OWNER),     400 * 1e6,  "merchant 80% of USDC");
        assertEq(weth.balanceOf(PUNCHCARD), 0.4 ether,  "PunchCard 20% of WETH");
        assertEq(weth.balanceOf(OWNER),     1.6 ether,  "merchant 80% of WETH");
    }

    /// Merchant-token fees are burned, never shared — PunchCard stays off the cap table.
    /// @dev The mock mints fee tokens on collect() (a real pool pays them out of existing
    ///      supply), so the check here is that every token the collect produced was burned:
    ///      net supply change of zero, and nothing left stranded in the locker.
    function test_merchantTokenFeesAreBurned() public {
        uint256 supplyBefore = merchant.totalSupply();
        (,, uint256 burned) = locker.collectFees();

        assertEq(burned, 1_400 * 1e6, "1000 + 400 merchant-token fees");
        assertEq(merchant.totalSupply(), supplyBefore, "every collected fee token was burned");
        assertEq(merchant.balanceOf(address(locker)), RESERVE, "nothing stranded in the locker");
        assertEq(merchant.balanceOf(PUNCHCARD), 0, "PunchCard never receives merchant tokens");
        assertEq(merchant.balanceOf(OWNER), 0, "merchant-token fees are burned, not paid out");
    }

    function test_frozenBlocksCollection() public {
        vm.prank(WINDDOWN);
        locker.freeze();
        vm.expectRevert("Frozen");
        locker.collectFees();
    }
}
