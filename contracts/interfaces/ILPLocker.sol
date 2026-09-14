// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILPLocker {

    // ── STRUCTS ──────────────────────────────────────────────────────────────

    struct LPPosition {
        uint256 tokenId;
        uint24  feeTier;
        uint128 initialLiquidity;
        bool    merchantIsToken0;
        bool    initialized;
        bool    released;
    }

    struct DualPosition {
        LPPosition usdc;
        LPPosition eth;
        uint256    reserveTokens; // merchant tokens held in reserve, not yet in pools
    }

    // ── EVENTS ────────────────────────────────────────────────────────────────

    event FeesCollected(
        address indexed merchantToken,
        uint256 usdcToMerchant,
        uint256 usdcToPunchcard,
        uint256 wethToMerchant,
        uint256 wethToPunchcard,
        uint256 merchantBurned,
        uint256 timestamp
    );

    event LPInitialized(
        address indexed merchantToken,
        uint256 usdcTokenId,
        uint256 ethTokenId,
        uint128 usdcLiquidity,
        uint128 ethLiquidity,
        uint256 reserveTokens,
        uint256 timestamp
    );

    event LiquidityAdded(
        address indexed merchantToken,
        uint256 usdcTokenAmount,
        uint256 ethTokenAmount,
        uint128 usdcLiquidityAdded,
        uint128 ethLiquidityAdded,
        uint256 reserveRemaining,
        uint256 timestamp
    );

    event LPReleased(
        address indexed merchantToken,
        uint256 usdcToMerchant,
        uint256 wethToMerchant,
        uint256 merchantTokenBurned,
        uint256 usdcPermanent,
        uint256 ethPermanent,
        uint256 timestamp
    );

    event LPFrozen(
        address indexed merchantToken,
        uint256 timestamp
    );

    // ── INITIALIZATION ────────────────────────────────────────────────────────

    /// @notice Initializes both LP positions and loads reserve
    /// @dev Factory only. Called once after both NFTs minted and transferred.
    ///      reserveTokens = total LP allocation - launch tokens already in pools.
    /// @param usdcTokenId  NFT id of the USDC pool position
    /// @param ethTokenId   NFT id of the ETH pool position
    /// @param usdcFeeTier  Fee tier of the USDC pool
    /// @param ethFeeTier   Fee tier of the ETH pool
    function initializeLP(
        uint256 usdcTokenId,
        uint256 ethTokenId,
        uint24  usdcFeeTier,
        uint24  ethFeeTier
    ) external;

    // ── LIQUIDITY MANAGEMENT ──────────────────────────────────────────────────

    /// @notice Adds liquidity from reserve into existing pool positions
    /// @dev ownerWallet only. Reverts if frozen.
    ///      usdcTokenAmount + ethTokenAmount must not exceed reserveTokens.
    ///      Tokens sourced from reserve held in this contract.
    ///      Caller provides pair tokens (USDC + WETH) — must approve LPLocker first.
    ///      Goes into same NFT positions — no new positions created.
    /// @param usdcTokenAmount  Merchant tokens to add to USDC pool (from reserve)
    /// @param ethTokenAmount   Merchant tokens to add to ETH pool (from reserve)
    /// @param usdcPairAmount   USDC to pair — pulled from ownerWallet
    /// @param ethPairAmount    WETH to pair — pulled from ownerWallet
    function addLiquidity(
        uint256 usdcTokenAmount,
        uint256 ethTokenAmount,
        uint256 usdcPairAmount,
        uint256 ethPairAmount,
        uint256 usdcTokenMin,
        uint256 usdcPairMin,
        uint256 ethTokenMin,
        uint256 ethPairMin
    ) external;

    // ── WIND-DOWN ─────────────────────────────────────────────────────────────

    /// @notice Freezes LP — prevents further addLiquidity calls
    /// @dev WindDownController only. Called at wind-down initiation.
    function freeze() external;

    /// @notice Executes 90/10 split on both positions at expiry
    /// @dev WindDownController only. Requires !released.
    ///      CEI: released = true before all external calls.
    ///      Each position settled independently.
    ///      All merchant token amounts (both positions + reserve) burned.
    ///      USDC sent to ownerWallet. WETH sent to ownerWallet.
    ///      10% of each position stays permanently — NFTs held forever.
    function release() external;

    // ── VIEWS ─────────────────────────────────────────────────────────────────

    function getPositions() external view returns (DualPosition memory);
    function isInitialized() external view returns (bool);
    function isReleased() external view returns (bool);
    function isFrozen() external view returns (bool);
    function reserveTokens() external view returns (uint256);
    function currentUsdcLiquidity() external view returns (uint128);
    function currentEthLiquidity() external view returns (uint128);
    function ownerWallet() external view returns (address);
    function positionManager() external view returns (address);
    function usdcAddress() external view returns (address);
    function wethAddress() external view returns (address);
    function usdcFeeTier() external view returns (uint24);
    function ethFeeTier() external view returns (uint24);
}
