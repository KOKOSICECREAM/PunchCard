// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IEthUsdOracle
/// @notice Chainlink AggregatorV3 — the subset needed to value an ETH seed in USD.
/// @dev The feed address is a constructor argument rather than a hardcoded constant, so
///      the same factory source deploys against mainnet, a testnet or a mock. Record the
///      address used in deploy/network/<network>.json and verify it before deploying.
interface IEthUsdOracle {
    function decimals() external view returns (uint8);

    function latestRoundData() external view returns (
        uint80  roundId,
        int256  answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80  answeredInRound
    );
}
