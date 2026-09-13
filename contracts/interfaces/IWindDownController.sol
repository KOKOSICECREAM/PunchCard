// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IWindDownController {

    // ── STRUCTS ──────────────────────────────────────────────────────────────

    struct WindDownSuite {
        address rewardEscrow;
        address vestingWallet;
        address treasuryTimelock;
        address lpLocker;
        uint256 initiatedAt;
        uint256 expiryTime;
        bool escrowSettled;
        bool treasurySettled;
        bool vestingSettled;
        bool complete;
    }

    // ── EVENTS ───────────────────────────────────────────────────────────────

    event WindDownInitiated(
        address indexed merchantToken,
        uint256 expiryTime,
        uint256 timestamp
    );

    event EscrowBurned(
        address indexed merchantToken,
        uint256 amount,
        uint256 timestamp
    );

    event TreasuryBurned(
        address indexed merchantToken,
        uint256 amount,
        uint256 timestamp
    );

    event VestingSettled(
        address indexed merchantToken,
        uint256 vestedToTeam,
        uint256 burned,
        uint256 timestamp
    );

    /// @notice Emitted when LP positions are released at wind-down expiry
    /// @dev Both USDC and ETH positions settled independently.
    ///      merchantTokenBurned covers both positions combined.
    ///      USDC and WETH sent separately to merchant wallet.
    event LPReleased(
        address indexed merchantToken,
        uint256 usdcToMerchant,
        uint256 wethToMerchant,
        uint256 merchantTokenBurned,
        uint256 usdcPermanent,
        uint256 ethPermanent,
        uint256 timestamp
    );

    event WindDownComplete(
        address indexed merchantToken,
        uint256 timestamp
    );

    event SuiteRegistered(
        address indexed merchantToken,
        address rewardEscrow,
        address vestingWallet,
        address treasuryTimelock,
        address lpLocker,
        uint256 timestamp
    );

    // ── REGISTRATION ─────────────────────────────────────────────────────────

    /// @notice Called by factory as final step of merchant deployment
    /// @dev Reverts if merchantToken already registered — no overwrite ever
    function register(
        address merchantToken,
        address rewardEscrow,
        address vestingWallet,
        address treasuryTimelock,
        address lpLocker
    ) external;

    // ── INITIATION ───────────────────────────────────────────────────────────

    /// @notice Initiates wind-down for a merchant token
    /// @dev PunchCard multisig only. Freezes escrow, treasury, and LP immediately.
    ///      Starts 12-month on-chain timer.
    function initiate(address merchantToken) external;

    // ── EXPIRY STEPS — order-independent except onExpiryReleaseLP ────────────

    function onExpiryBurnEscrow(address merchantToken) external;
    function onExpiryBurnTreasury(address merchantToken) external;
    function onExpirySettleVesting(address merchantToken) external;

    /// @notice Releases both LP positions — 90% to merchant, 10% permanent each
    /// @dev Requires escrowSettled && treasurySettled && vestingSettled.
    function onExpiryReleaseLP(address merchantToken) external;

    // ── VIEWS ────────────────────────────────────────────────────────────────

    function getSuite(address merchantToken) external view returns (WindDownSuite memory);
    function isRegistered(address merchantToken) external view returns (bool);
    function isInitiated(address merchantToken) external view returns (bool);
    function isComplete(address merchantToken) external view returns (bool);
    function timeUntilExpiry(address merchantToken) external view returns (uint256);
}
