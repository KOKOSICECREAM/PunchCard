// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IWindDownController.sol";
import "./interfaces/IRewardEscrow.sol";
import "./interfaces/ITreasuryTimelock.sol";
import "./interfaces/IVestingWallet.sol";
import "./interfaces/ILPLocker.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title WindDownController
/// @notice Coordinates merchant token wind-down across all suite contracts.
/// @dev Deployed once by PunchCard at network launch. Immutable after deploy.
///      Factory is the sole registrar. PunchCard multisig is the sole initiator.
///      Wind-down state machine — four independent expiry steps,
///      LP release is the terminal gate requiring all three prior steps complete.
///      At initiation: escrow, treasury, and LP all frozen immediately.
///      LP freeze prevents further liquidity additions during wind-down period.
contract WindDownController is IWindDownController {

    uint256 public constant WIND_DOWN_DURATION = 365 days;

    address public immutable multisig;
    address public immutable factory;

    mapping(address => WindDownSuite) private _suites;
    mapping(address => bool) private _registered;

    constructor(address _multisig, address _factory) {
        require(_multisig != address(0), "Invalid multisig");
        require(_factory  != address(0), "Invalid factory");
        multisig = _multisig;
        factory  = _factory;
    }

    modifier onlyMultisig() {
        require(msg.sender == multisig, "Not multisig");
        _;
    }

    modifier onlyFactory() {
        require(msg.sender == factory, "Not factory");
        _;
    }

    modifier onlyRegistered(address merchantToken) {
        require(_registered[merchantToken], "Not registered");
        _;
    }

    function register(
        address merchantToken,
        address rewardEscrow,
        address vestingWallet,
        address treasuryTimelock,
        address lpLocker
    ) external onlyFactory {
        require(!_registered[merchantToken], "Already registered");
        require(merchantToken    != address(0), "Invalid token");
        require(rewardEscrow     != address(0), "Invalid escrow");
        require(vestingWallet    != address(0), "Invalid vesting");
        require(treasuryTimelock != address(0), "Invalid treasury");
        require(lpLocker         != address(0), "Invalid locker");

        _registered[merchantToken] = true;
        _suites[merchantToken] = WindDownSuite({
            rewardEscrow:     rewardEscrow,
            vestingWallet:    vestingWallet,
            treasuryTimelock: treasuryTimelock,
            lpLocker:         lpLocker,
            initiatedAt:      0,
            expiryTime:       0,
            escrowSettled:    false,
            treasurySettled:  false,
            vestingSettled:   false,
            complete:         false
        });

        emit SuiteRegistered(
            merchantToken,
            rewardEscrow,
            vestingWallet,
            treasuryTimelock,
            lpLocker,
            block.timestamp
        );
    }

    function initiate(address merchantToken)
        external
        onlyMultisig
        onlyRegistered(merchantToken)
    {
        WindDownSuite storage suite = _suites[merchantToken];
        require(suite.initiatedAt == 0, "Already initiated");

        suite.initiatedAt = block.timestamp;
        suite.expiryTime  = block.timestamp + WIND_DOWN_DURATION;

        // Freeze escrow — no rewards after this point
        IRewardEscrow(suite.rewardEscrow).freeze();

        // Freeze treasury — cancels any pending release silently
        ITreasuryTimelock(suite.treasuryTimelock).freeze();

        // Freeze LP — no further liquidity additions during wind-down
        // LP stays liquid for customer swaps — only addLiquidity() is blocked
        ILPLocker(suite.lpLocker).freeze();

        emit WindDownInitiated(merchantToken, suite.expiryTime, block.timestamp);
    }

    function onExpiryBurnEscrow(address merchantToken)
        external
        onlyRegistered(merchantToken)
    {
        WindDownSuite storage suite = _suites[merchantToken];
        require(suite.initiatedAt != 0,              "Not initiated");
        require(block.timestamp >= suite.expiryTime, "Not expired");
        require(!suite.escrowSettled,                "Already settled");

        suite.escrowSettled = true;

        uint256 balance = IERC20(merchantToken).balanceOf(suite.rewardEscrow);
        if (balance > 0) {
            IRewardEscrow(suite.rewardEscrow).burnRemaining();
        }

        emit EscrowBurned(merchantToken, balance, block.timestamp);
    }

    function onExpiryBurnTreasury(address merchantToken)
        external
        onlyRegistered(merchantToken)
    {
        WindDownSuite storage suite = _suites[merchantToken];
        require(suite.initiatedAt != 0,              "Not initiated");
        require(block.timestamp >= suite.expiryTime, "Not expired");
        require(!suite.treasurySettled,              "Already settled");

        suite.treasurySettled = true;

        uint256 balance = ITreasuryTimelock(suite.treasuryTimelock).balance();
        if (balance > 0) {
            ITreasuryTimelock(suite.treasuryTimelock).burnUnclaimed();
        }

        emit TreasuryBurned(merchantToken, balance, block.timestamp);
    }

    function onExpirySettleVesting(address merchantToken)
        external
        onlyRegistered(merchantToken)
    {
        WindDownSuite storage suite = _suites[merchantToken];
        require(suite.initiatedAt != 0,              "Not initiated");
        require(block.timestamp >= suite.expiryTime, "Not expired");
        require(!suite.vestingSettled,               "Already settled");

        suite.vestingSettled = true;

        IVestingWallet vesting   = IVestingWallet(suite.vestingWallet);
        uint256 vestedToTeam     = vesting.totalVested() - vesting.released();
        uint256 totalHeld        = IERC20(merchantToken).balanceOf(suite.vestingWallet);
        uint256 burned           = totalHeld - vestedToTeam;

        vesting.settleAndBurn();

        emit VestingSettled(merchantToken, vestedToTeam, burned, block.timestamp);
    }

    function onExpiryReleaseLP(address merchantToken)
        external
        onlyRegistered(merchantToken)
    {
        WindDownSuite storage suite = _suites[merchantToken];
        require(!suite.complete,                     "Already complete");
        require(suite.initiatedAt != 0,              "Not initiated");
        require(block.timestamp >= suite.expiryTime, "Not expired");
        require(
            suite.escrowSettled &&
            suite.treasurySettled &&
            suite.vestingSettled,
            "Settle other steps first"
        );

        suite.complete = true;

        // LPLocker.release() emits LPReleased with full dual-position detail
        ILPLocker(suite.lpLocker).release();

        emit WindDownComplete(merchantToken, block.timestamp);
    }

    function getSuite(address merchantToken)
        external view returns (WindDownSuite memory)
    {
        return _suites[merchantToken];
    }

    function isRegistered(address merchantToken) external view returns (bool) {
        return _registered[merchantToken];
    }

    function isInitiated(address merchantToken) external view returns (bool) {
        return _suites[merchantToken].initiatedAt != 0;
    }

    function isComplete(address merchantToken) external view returns (bool) {
        return _suites[merchantToken].complete;
    }

    function timeUntilExpiry(address merchantToken) external view returns (uint256) {
        WindDownSuite storage suite = _suites[merchantToken];
        if (suite.initiatedAt == 0) return 0;
        if (block.timestamp >= suite.expiryTime) return 0;
        return suite.expiryTime - block.timestamp;
    }
}
