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
///      Registration is restricted to AUTHORIZED FACTORIES. PunchCard multisig is the sole
///      initiator of wind-down.
///      Wind-down state machine — four independent expiry steps,
///      LP release is the terminal gate requiring all three prior steps complete.
///      At initiation: escrow, treasury, and LP all frozen immediately.
///      LP freeze prevents further liquidity additions during wind-down period.
contract WindDownController is IWindDownController {

    uint256 public constant WIND_DOWN_DURATION = 365 days;

    /// @notice How long a proposed factory change must wait before it can be executed.
    uint256 public constant FACTORY_TIMELOCK = 48 hours;

    address public immutable multisig;

    /// @notice The factory set at construction. Kept for provenance; authorisation is read
    ///         from `authorizedFactories`, which this address starts out in.
    address public immutable factory;

    /// @notice Deployment paths allowed to register merchants into this network.
    /// @dev More than one on purpose. A staged rollout deploys early merchants through a
    ///      factory with an LP recovery window and later merchants through a strict one;
    ///      if each needed its own controller, each would get its own router and registry,
    ///      and merchants from different stages could not swap against one another. That
    ///      would split the network exactly where the network effect is being proven.
    ///
    ///      This is a GOVERNANCE power, not a custody power. Authorising a factory adds a
    ///      future deployment path. It cannot touch an existing merchant's suite, terms,
    ///      liquidity or tokens — there is no function here that mutates a registered
    ///      suite, and `register()` refuses a token that is already registered.
    mapping(address => bool) public authorizedFactories;

    /// @notice Timestamp a proposed authorisation change becomes executable. 0 = none.
    mapping(address => uint256) public factoryProposedAt;
    mapping(address => bool)    public factoryProposalIsAuthorize;

    // ── MANUAL ADMISSION ──────────────────────────────────────────────────────

    /// @notice Addresses permitted to admit a hand-assembled merchant.
    /// @dev The factory path is the standard and this is the exception. It exists because a
    ///      merchant may be assembled outside a factory — the network's own first token,
    ///      launched by hand so its liquidity and allocations stay movable while unaudited
    ///      code is proven — and because bending the factory to allow that would put
    ///      exceptions inside the thing whose whole value is having none.
    ///
    ///      **This is weaker than the factory path and must stay rarer.** A factory
    ///      guarantees a suite was CREATED by known code. This guarantees only that the
    ///      code is known NOW, which `registerManual` enforces by comparing every
    ///      contract's `codehash` against an implementation the multisig has approved.
    ///      Without that comparison it would be a signature saying "trust me", which is not
    ///      a guarantee at all.
    mapping(address => bool) public registrars;

    /// @notice Runtime code hashes the multisig accepts for each suite role.
    /// @dev `keccak256(role) => codehash => allowed`. Several may be allowed per role: a
    ///      locker lineage differs between production, beta and pilot, and all three are
    ///      legitimate for different merchants.
    mapping(bytes32 => mapping(bytes32 => bool)) public approvedCode;

    bytes32 public constant ROLE_TOKEN    = keccak256("MERCHANT_TOKEN");
    bytes32 public constant ROLE_ESCROW   = keccak256("REWARD_ESCROW");
    bytes32 public constant ROLE_VESTING  = keccak256("VESTING_WALLET");
    bytes32 public constant ROLE_TREASURY = keccak256("TREASURY_TIMELOCK");
    bytes32 public constant ROLE_LOCKER   = keccak256("LP_LOCKER");

    event RegistrarSet(address indexed registrar, bool allowed, uint256 timestamp);
    event CodeApproved(bytes32 indexed role, bytes32 indexed codehash, bool allowed, uint256 timestamp);
    event ManualSuiteRegistered(address indexed merchantToken, address indexed registrar, uint256 timestamp);

    mapping(address => WindDownSuite) private _suites;
    mapping(address => bool) private _registered;

    event FactoryProposed(address indexed factory, bool authorize, uint256 executableAt);
    event FactoryAuthorized(address indexed factory, uint256 timestamp);
    event FactoryDisabled(address indexed factory, uint256 timestamp);

    constructor(address _multisig, address _factory) {
        require(_multisig != address(0), "Invalid multisig");
        require(_factory  != address(0), "Invalid factory");
        multisig = _multisig;
        factory  = _factory;
        authorizedFactories[_factory] = true;
        emit FactoryAuthorized(_factory, block.timestamp);
    }

    // ── FACTORY AUTHORISATION ─────────────────────────────────────────────────

    /// @notice Propose authorising or disabling a deployment path. Multisig only.
    /// @dev Timelocked for the same reason the router's parameter changes are: the power
    ///      to add a deployment path should be visible before it takes effect.
    function proposeFactory(address newFactory, bool authorize) external onlyMultisig {
        require(newFactory != address(0), "Invalid factory");
        require(authorizedFactories[newFactory] != authorize, "Already in that state");
        factoryProposedAt[newFactory]          = block.timestamp + FACTORY_TIMELOCK;
        factoryProposalIsAuthorize[newFactory] = authorize;
        emit FactoryProposed(newFactory, authorize, block.timestamp + FACTORY_TIMELOCK);
    }

    /// @notice Execute a proposal once its timelock has elapsed. Multisig only.
    /// @dev Disabling a factory stops it registering NEW merchants. Merchants it already
    ///      registered are untouched and keep working — retiring a deployment path must
    ///      never orphan the merchants that came through it.
    function executeFactory(address newFactory) external onlyMultisig {
        uint256 at = factoryProposedAt[newFactory];
        require(at != 0,                "No proposal");
        require(block.timestamp >= at,  "Timelock not elapsed");

        bool authorize = factoryProposalIsAuthorize[newFactory];
        authorizedFactories[newFactory] = authorize;
        factoryProposedAt[newFactory]   = 0;

        if (authorize) emit FactoryAuthorized(newFactory, block.timestamp);
        else           emit FactoryDisabled(newFactory, block.timestamp);
    }

    modifier onlyMultisig() {
        require(msg.sender == multisig, "Not multisig");
        _;
    }

    // ── MANUAL ADMISSION ──────────────────────────────────────────────────────

    function setRegistrar(address who, bool allowed) external onlyMultisig {
        require(who != address(0), "Invalid registrar");
        registrars[who] = allowed;
        emit RegistrarSet(who, allowed, block.timestamp);
    }

    /// @notice Approve a runtime code hash for one suite role. Multisig only.
    /// @dev Approving code is the whole security of the manual path. A registrar can admit
    ///      any suite built from approved code and nothing else, so this is the list that
    ///      decides what "a PunchCard merchant" can be made of.
    function setApprovedCode(bytes32 role, bytes32 codehash, bool allowed) external onlyMultisig {
        require(codehash != bytes32(0), "Invalid codehash");
        approvedCode[role][codehash] = allowed;
        emit CodeApproved(role, codehash, allowed, block.timestamp);
    }

    /// @notice Admit a hand-assembled merchant whose contracts are all approved code.
    /// @dev Deliberately does NOT check balances, pools or liquidity. Those are the
    ///      registrar's job, done off-chain with a verification script, and encoding them
    ///      here would rebuild the factory inside the controller — which is the thing this
    ///      path exists to avoid. What it does check is the one thing a human review cannot
    ///      do reliably by eye: that every contract is bytecode nobody has altered.
    function registerManual(
        address merchantToken,
        address rewardEscrow,
        address vestingWallet,
        address treasuryTimelock,
        address lpLocker
    ) external {
        require(registrars[msg.sender], "Not registrar");
        require(!_registered[merchantToken], "Already registered");

        _requireApproved(ROLE_TOKEN,    merchantToken,    "token");
        _requireApproved(ROLE_ESCROW,   rewardEscrow,     "escrow");
        _requireApproved(ROLE_VESTING,  vestingWallet,    "vesting");
        _requireApproved(ROLE_TREASURY, treasuryTimelock, "treasury");
        _requireApproved(ROLE_LOCKER,   lpLocker,         "locker");

        _record(merchantToken, rewardEscrow, vestingWallet, treasuryTimelock, lpLocker);
        emit ManualSuiteRegistered(merchantToken, msg.sender, block.timestamp);
    }

    /// @dev Reverts naming the role, because "not approved code" on its own would leave an
    ///      operator diffing five addresses to find which one.
    function _requireApproved(bytes32 role, address target, string memory what) private view {
        require(target != address(0), string.concat("Invalid ", what));
        require(target.code.length > 0, string.concat("No code at ", what));
        require(approvedCode[role][target.codehash], string.concat("Unapproved ", what, " code"));
    }

    modifier onlyFactory() {
        require(authorizedFactories[msg.sender], "Not factory");
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

        _record(merchantToken, rewardEscrow, vestingWallet, treasuryTimelock, lpLocker);
    }

    /// @dev The registry write itself, shared by both admission paths so they cannot come to
    ///      mean different things. Everything above it differs — a factory proves how a
    ///      suite was built, a registrar proves what its code is now — but what lands in the
    ///      registry is identical, and the router cannot tell the two apart. That is
    ///      deliberate: a merchant is a merchant.
    function _record(
        address merchantToken,
        address rewardEscrow,
        address vestingWallet,
        address treasuryTimelock,
        address lpLocker
    ) private {
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
