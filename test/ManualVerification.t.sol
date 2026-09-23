// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../script/VerifyManualSuite.s.sol";
import "../contracts/WindDownController.sol";
import "../contracts/StagedTokenFactory.sol";
import "../contracts/deployers/SuiteDeployer.sol";
import "../contracts/pilot/LockerDeployerPilot.sol";
import "../contracts/MerchantToken.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IERC721Min721 { function transferFrom(address, address, uint256) external; }

contract MintableToken is MerchantToken {
    constructor(address to) MerchantToken("Fake", "FAKE", 100_000_000 * 1e6, to, keccak256("f")) {}
    function mintMore(address to, uint256 a) external { _mint(to, a); }
}

/// @title The registrar's homework, and proof it can fail
///
/// @notice `registerManual` checks codehashes and nothing else, on purpose. Everything a
///         person cannot check by eye — allocations, pools, prices, wallets — lives in
///         `VerifyManualSuite`, which makes that script the whole difference between the
///         manual path being flexible and being careless.
///
///         So the thing most worth testing is that it FAILS. A verification script that
///         prints FAIL and exits zero produces a signed-off feeling with no signature, and
///         an earlier draft of this one did exactly that: every check was `view`, so the
///         counter it reverted on could never be incremented.
///
/// @dev Runs against a Base fork, because the price checks read real Uniswap pools.
contract ManualVerificationTest is Test {
    address constant POSITION_MANAGER = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address constant USDC             = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH             = 0x4200000000000000000000000000000000000006;
    address constant ETH_USD_FEED     = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant UNI_FACTORY      = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;

    address constant MULTISIG = address(0x9101);
    address constant DEPLOYER = address(0x9102);
    address constant FEERECIP = address(0x9103);
    address constant OWNER    = address(0x9104);
    address constant TEAM     = address(0x9105);
    address constant OPERATOR = address(0x9106);

    uint256 constant USDC_SEED = 5 * 1e6;
    uint256 constant ETH_SEED  = 0.0025 ether;

    VerifyManualSuite  v;
    WindDownController wdc;      // the controller the factory built against
    WindDownController target;   // the network the suite is asking to join
    StagedTokenFactory f;
    address token; address escrow; address vesting; address treasury; address locker;
    bool forked;

    function setUp() public {
        if (block.chainid != 8453) return;
        forked = true;
        v = new VerifyManualSuite();

        // Build a real, correct suite through the factory. The manual path admits
        // hand-assembled suites, but a factory-built one is the cleanest reference for
        // "correct", and what the script must pass on.
        SuiteDeployer       sd = new SuiteDeployer();
        LockerDeployerPilot ld = new LockerDeployerPilot();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        wdc = new WindDownController(MULTISIG, predicted);
        f = new StagedTokenFactory(
            MULTISIG, address(this), address(wdc), POSITION_MANAGER, USDC, WETH,
            ETH_USD_FEED, FEERECIP, address(sd), address(ld), 1, 1
        );

        token = f.stageSuite(StagedTokenFactory.StageParams({
            name: "Manual Verify", symbol: "MVFY", ipfsHash: keccak256("mv"),
            ownerWallet: OWNER, teamWallet: TEAM, operator: OPERATOR,
            perTxFloor: 1e6, perTxMax: 20_000 * 1e6
        }));
        (, , , , escrow, vesting, treasury, locker,,,,,,,) = f.suites(token);

        deal(USDC, OWNER, USDC_SEED);
        vm.prank(OWNER);
        IERC20(USDC).approve(address(f), USDC_SEED);
        vm.deal(address(this), ETH_SEED);
        f.fundAndMintLP{value: ETH_SEED}(StagedTokenFactory.FundParams({
            token: token, usdcFeeTier: 3000, ethFeeTier: 3000,
            usdcPairAmount: USDC_SEED, ethPairAmount: ETH_SEED
        }));

        // Hand the LP to the locker the way activation would, without registering — that is
        // the state a hand-assembled suite is in when the registrar inspects it.
        f.activateMerchant(token);

        // A hand-assembled suite is inspected against the controller it is ASKING to join,
        // which has never seen it. Using the one the factory registered into would make
        // every run fail check 6, which is what the first version of this test did.
        target = new WindDownController(MULTISIG, address(f));

        _approveAllCode();
        _env();
    }

    function _approveAllCode() internal {
        vm.startPrank(MULTISIG);
        target.setApprovedCode(target.ROLE_TOKEN(),    token.codehash,    true);
        target.setApprovedCode(target.ROLE_ESCROW(),   escrow.codehash,   true);
        target.setApprovedCode(target.ROLE_VESTING(),  vesting.codehash,  true);
        target.setApprovedCode(target.ROLE_TREASURY(), treasury.codehash, true);
        target.setApprovedCode(target.ROLE_LOCKER(),   locker.codehash,   true);
        vm.stopPrank();
    }

    function _pool(address pair, uint24 fee) internal view returns (address) {
        (address a, address b) = token < pair ? (token, pair) : (pair, token);
        return IUniswapV3Factory(UNI_FACTORY).getPool(a, b, fee);
    }

    function _env() internal {
        vm.setEnv("PC_WIND_DOWN_CONTROLLER", vm.toString(address(target)));
        vm.setEnv("PC_TOKEN",           vm.toString(token));
        vm.setEnv("PC_ESCROW",          vm.toString(escrow));
        vm.setEnv("PC_VESTING",         vm.toString(vesting));
        vm.setEnv("PC_TREASURY",        vm.toString(treasury));
        vm.setEnv("PC_LOCKER",          vm.toString(locker));
        vm.setEnv("PC_EXPECT_OWNER",    vm.toString(OWNER));
        vm.setEnv("PC_EXPECT_TEAM",     vm.toString(TEAM));
        vm.setEnv("PC_EXPECT_OPERATOR", vm.toString(OPERATOR));
        vm.setEnv("PC_USDC_POOL",       vm.toString(_pool(USDC, 3000)));
        vm.setEnv("PC_ETH_POOL",        vm.toString(_pool(WETH, 3000)));
        vm.setEnv("PC_USDC",            vm.toString(USDC));
        vm.setEnv("PC_WETH",            vm.toString(WETH));
        vm.setEnv("PC_ETH_USD_FEED",    vm.toString(ETH_USD_FEED));
        vm.setEnv("PC_POSITION_MANAGER", vm.toString(POSITION_MANAGER));
        vm.setEnv("PC_MODE",            "pilot");
    }

    /// One test, sequentially. vm.setEnv writes the process environment and forge runs tests
    /// concurrently without rolling it back, so split across functions these poison each
    /// other — the same hazard that broke the micro-rehearsal suite.
    function test_theVerificationScript() public {
        if (!forked) { emit log("SKIPPED - needs --fork-url https://mainnet.base.org"); vm.skip(true); }

        // ── a correct suite passes ───────────────────────────────────────────
        _env();
        v.run();

        // ── strict mode also passes on a correct suite ───────────────────────
        _env(); vm.setEnv("PC_MODE", "strict");
        v.run();

        // ── an unapproved codehash fails, in either mode ─────────────────────
        MintableToken fake = new MintableToken(address(this));
        _env(); vm.setEnv("PC_TOKEN", vm.toString(address(fake)));
        vm.expectRevert("Verification failed - see the report above");
        v.run();

        // ── a missing pool fails ─────────────────────────────────────────────
        _env(); vm.setEnv("PC_USDC_POOL", vm.toString(address(0xDEAD)));
        vm.expectRevert("Verification failed - see the report above");
        v.run();

        // ── a wrong-price pool fails: point the ETH check at the USDC pool, whose
        //    implied USD price is nowhere near when valued as if it were WETH ──
        _env(); vm.setEnv("PC_ETH_POOL", vm.toString(_pool(USDC, 3000)));
        vm.expectRevert("Verification failed - see the report above");
        v.run();

        // ── an already-registered token fails ────────────────────────────────
        vm.startPrank(MULTISIG);
        target.setRegistrar(address(this), true);
        vm.stopPrank();
        target.registerManual(token, escrow, vesting, treasury, locker);

        _env();
        vm.expectRevert("Verification failed - see the report above");
        v.run();

        emit log("verification script passes a correct suite and fails every broken one");
    }

    /// The hole hand-assembly opens, and the factory closes by construction.
    ///
    /// initializeLP reads both positions from Uniswap and never checks the locker owns
    /// them — it cannot fail to in the factory path, which transfers the NFTs and then
    /// initialises in one transaction. Assembled by hand, the locker can report
    /// `isInitialized: true` while the liquidity sits in somebody's wallet, and everything
    /// downstream believes a claim the whole product rests on.
    function test_positionsNotOwnedByTheLockerAreCaught() public {
        if (!forked) { vm.skip(true); }

        // Move one position out from under the locker, as a wrong token ID or a forgotten
        // transfer would leave it.
        (uint256 usdcId,,,,,,,,,,,,) = IV_Locker(locker).getPositions();
        vm.prank(locker);
        IERC721Min721(POSITION_MANAGER).transferFrom(locker, address(0xBEEF), usdcId);

        _env();
        vm.expectRevert("Verification failed - see the report above");
        v.run();

        emit log("a position the locker does not own fails verification");
    }

    /// The mode difference, isolated: a shortfall warns in pilot and fails in strict.
    function test_pilotToleratesAShortfallAndStrictDoesNot() public {
        if (!forked) { vm.skip(true); }

        // Move 1M out of the escrow, as a hand-funded suite that was topped up short.
        vm.prank(escrow);
        IERC20(token).transfer(OWNER, 1_000_000 * 1e6);

        _env();                                  // pilot
        v.run();                                 // reports the shortfall, does not fail

        _env(); vm.setEnv("PC_MODE", "strict");
        vm.expectRevert("Verification failed - see the report above");
        v.run();

        emit log("pilot reports the shortfall; strict refuses it");
    }
}
