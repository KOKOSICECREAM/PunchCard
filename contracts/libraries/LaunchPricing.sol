// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title LaunchPricing
/// @notice Derives the launch token split and Uniswap v3 initial prices from whatever
///         seed capital a merchant, investor or PunchCard actually supplies.
/// @dev The seed is a *minimum*, not a fixed amount — anyone may seed more. That makes a
///      hardcoded token split unsafe: with fixed token amounts and variable cash, the two
///      pools land on different prices and the first trade arbitrages the difference.
///
///      So the token side is derived instead. Both pools are given tokens in proportion
///      to the USD value seeded into them, which makes the implied price identical in
///      both by construction:
///
///          price = totalSeedUsd / LAUNCH_LP_ALLOC        (same for both pools)
///
///      Seed $2k USDC + $3k ETH and the USDC pool gets 40% of the launch tokens and the
///      ETH pool 60%. Seed $50k + $50k and it is 50/50. Either way, one price.
library LaunchPricing {

    /// @notice Splits a fixed launch token allocation in proportion to seeded USD value.
    /// @param launchAlloc  Total tokens to seed across both pools
    /// @param usdcValueUsd USD value seeded into the USDC pool, 8dp
    /// @param ethValueUsd  USD value seeded into the ETH pool, 8dp
    /// @return tokensToUsdcPool Tokens for the USDC pool
    /// @return tokensToEthPool  Tokens for the ETH pool — the remainder, so no dust is lost
    function deriveTokenSplit(
        uint256 launchAlloc,
        uint256 usdcValueUsd,
        uint256 ethValueUsd
    ) internal pure returns (uint256 tokensToUsdcPool, uint256 tokensToEthPool) {
        uint256 totalUsd = usdcValueUsd + ethValueUsd;
        require(totalUsd > 0, "Zero seed value");

        tokensToUsdcPool = (launchAlloc * usdcValueUsd) / totalUsd;
        // Remainder rather than a second multiply — guarantees the two sum to launchAlloc
        // exactly, so the factory's reserve assertion cannot drift by a rounding unit.
        tokensToEthPool  = launchAlloc - tokensToUsdcPool;
    }

    /// @notice Uniswap v3 initial price for a pool, as sqrt(token1/token0) * 2**96.
    /// @dev Computed from the raw amounts the pool is about to receive, so the initial
    ///      price and the minted position agree and no liquidity is left as dust.
    ///
    ///      Done as sqrt((amount1 << 96) / amount0) << 48 rather than the textbook
    ///      sqrt(amount1 * 2**192 / amount0): the latter overflows for realistic token
    ///      amounts, while `amount1 << 96` stays far inside uint256 for any plausible
    ///      seed and keeps ~26 significant digits of precision.
    function encodeSqrtPriceX96(uint256 amount0, uint256 amount1)
        internal pure returns (uint160)
    {
        require(amount0 > 0 && amount1 > 0, "Zero amount");
        uint256 ratioX96 = (amount1 << 96) / amount0;
        uint256 sqrtX48  = sqrt(ratioX96);
        uint256 result   = sqrtX48 << 48;
        require(result <= type(uint160).max, "Price overflow");
        return uint160(result);
    }

    /// @notice Integer square root, Babylonian method.
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
