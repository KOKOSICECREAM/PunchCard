// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/libraries/LaunchPricing.sol";

contract LaunchPricingTest is Test {
    uint256 constant LAUNCH_ALLOC = 3_000_000 * 1e6;

    /// The whole point: whatever is seeded, both pools must imply the same price.
    function test_bothPoolsPriceIdentically() public pure {
        uint256 usdcUsd = 2_000 * 1e8;   // $2,000
        uint256 ethUsd  = 3_000 * 1e8;   // $3,000
        (uint256 tU, uint256 tE) =
            LaunchPricing.deriveTokenSplit(LAUNCH_ALLOC, usdcUsd, ethUsd);

        assertEq(tU, 1_200_000 * 1e6, "USDC pool should get 40%");
        assertEq(tE, 1_800_000 * 1e6, "ETH pool should get 60%");

        // price = value / tokens, scaled up to compare without integer truncation
        uint256 pU = (usdcUsd * 1e18) / tU;
        uint256 pE = (ethUsd  * 1e18) / tE;
        assertEq(pU, pE, "pools must imply the same launch price");
    }

    /// The split must track the money, not a hardcoded ratio.
    function test_splitFollowsSeedRatio() public pure {
        (uint256 a,) = LaunchPricing.deriveTokenSplit(LAUNCH_ALLOC, 50_000e8, 50_000e8);
        assertEq(a, 1_500_000 * 1e6, "equal seed -> 50/50");

        (uint256 b,) = LaunchPricing.deriveTokenSplit(LAUNCH_ALLOC, 9_000e8, 1_000e8);
        assertEq(b, 2_700_000 * 1e6, "90/10 seed -> 90/10 tokens");
    }

    /// Never lose a token to rounding — the reserve assertion depends on this.
    function testFuzz_splitAlwaysSumsToAllocation(uint128 u, uint128 e) public pure {
        vm.assume(u > 0 && e > 0);
        (uint256 tU, uint256 tE) = LaunchPricing.deriveTokenSplit(LAUNCH_ALLOC, u, e);
        assertEq(tU + tE, LAUNCH_ALLOC, "split must sum to the allocation exactly");
    }

    /// price of 1 -> exactly 2**96
    function test_sqrtPriceX96_unity() public pure {
        assertEq(LaunchPricing.encodeSqrtPriceX96(1e18, 1e18), 79228162514264337593543950336);
    }

    /// price of 4 -> sqrt(4) * 2**96 = 2 * 2**96
    function test_sqrtPriceX96_knownRatio() public pure {
        assertEq(
            LaunchPricing.encodeSqrtPriceX96(1e18, 4e18),
            2 * 79228162514264337593543950336
        );
    }

    /// Recovering the price from sqrtPriceX96 must match the amounts that produced it.
    function test_sqrtPriceX96_roundTrips() public pure {
        uint256 amt0 = 1_200_000 * 1e6;   // tokens
        uint256 amt1 = 2_000 * 1e6;       // USDC
        uint160 s = LaunchPricing.encodeSqrtPriceX96(amt0, amt1);

        // price = (s / 2**96)**2, compared in 1e18 fixed point
        uint256 recovered = (uint256(s) * uint256(s) * 1e18) >> 192;
        uint256 expected  = (amt1 * 1e18) / amt0;
        assertApproxEqRel(recovered, expected, 1e12, "round-trip within 0.0001%");
    }
}
