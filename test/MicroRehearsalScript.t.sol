// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../script/DeployMicroRehearsal.s.sol";
import "../contracts/beta/LPLockerBeta.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title The micro rehearsal script, actually executed
///
/// @notice A script that compiles is not a script that runs. This one deploys a controller,
///         a factory, a router and two full merchant suites across two signers, and until
///         this test existed none of that had ever been executed — the first run would have
///         been on Base mainnet with real money, where a bad nonce prediction or a wrong
///         broadcast order costs gas and leaves a half-built network behind.
///
/// @dev Runs against a Base fork with funded throwaway keys, exercising the same path the
///      operator will: wallet B approves, wallet A deploys, deploy() pulls from B.
contract MicroRehearsalScriptTest is Test {
    address constant POSITION_MANAGER = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address constant SWAP_ROUTER      = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant USDC             = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH             = 0x4200000000000000000000000000000000000006;
    address constant ETH_USD_FEED     = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    // Throwaway keys, test-only. Never funded on any real chain.
    uint256 constant KEY_A = 0xA11CE;
    uint256 constant KEY_B = 0xB0B;

    DeployMicroRehearsal script;
    bool forked;

    function setUp() public {
        if (block.chainid != 8453) return;
        forked = true;
        script = new DeployMicroRehearsal();
    }

    /// @dev Every variable, every test — including the optional ones.
    ///
    ///      `vm.setEnv` writes the PROCESS environment, and forge does not roll that back
    ///      between tests the way it rolls back EVM state. setUp also runs once, with its
    ///      result snapshotted and replayed, so environment writes made there happen a
    ///      single time while writes made inside a test persist into every test that runs
    ///      after it. Setting only the variables a given test cares about therefore leaks:
    ///      the pSKOOP symbol case poisoned the happy path, and the same-wallet case
    ///      poisoned everything after it. Both looked like script bugs and were not.
    function _env() internal {
        vm.setEnv("PC_MICRO_REHEARSAL",   "true");
        vm.setEnv("PC_CREATE_NEW_NETWORK","true");
        vm.setEnv("PC_KEY_A",             vm.toString(KEY_A));
        vm.setEnv("PC_KEY_B",             vm.toString(KEY_B));
        vm.setEnv("PC_POSITION_MANAGER",  vm.toString(POSITION_MANAGER));
        vm.setEnv("PC_SWAP_ROUTER",       vm.toString(SWAP_ROUTER));
        vm.setEnv("PC_USDC",              vm.toString(USDC));
        vm.setEnv("PC_WETH",              vm.toString(WETH));
        vm.setEnv("PC_ETH_USD_FEED",      vm.toString(ETH_USD_FEED));
        vm.setEnv("PC_MICRO_SYMBOL_A",    "PCMA");
        vm.setEnv("PC_MICRO_SYMBOL_B",    "PCMB");
        vm.setEnv("PC_MICRO_TWO_MERCHANTS", "true");
    }

    function _fundLikeTheRealWallets() internal returns (address A, address B) {
        A = vm.addr(KEY_A);
        B = vm.addr(KEY_B);
        // The amounts actually sitting in the real wallets right now (A topped up by
        // 0.002 for the staged run, which costs more gas than the atomic one did).
        vm.deal(A, 0.008083 ether);
        vm.deal(B, 0.003393 ether);
        deal(USDC, B, 10_006_944);
    }

    /// Everything, in one test, on purpose.
    ///
    /// @dev `vm.setEnv` writes the PROCESS environment. Forge runs tests concurrently and
    ///      does not roll that back the way it rolls back EVM state, so a variable set by
    ///      one test is visible to every other test racing alongside it. Split across six
    ///      test functions this file failed four of them with errors belonging to its
    ///      siblings — the pSKOOP guard tripping the happy path, the same-wallet guard
    ///      tripping the funding checks — all of which read as script bugs and were not.
    ///
    ///      Within a single function, execution is sequential and the environment is
    ///      whatever the previous line set. So the guards run first, each reverting cleanly
    ///      and leaving no state behind, and the happy path runs last.
    function test_theScriptActuallyRuns() public {
        if (!forked) { vm.skip(true); }

        // ── guard: one wallet skips the whole point ──────────────────────────
        _env();
        _fundLikeTheRealWallets();
        vm.setEnv("PC_KEY_B", vm.toString(KEY_A));
        vm.expectRevert(bytes("PC_KEY_A and PC_KEY_B must be different wallets - the point is to exercise the cross-wallet approval"));
        script.run();

        // ── guard: the pilot's symbol is not available to a throwaway ────────
        _env();
        vm.setEnv("PC_MICRO_SYMBOL_A", "pSKOOP");
        vm.expectRevert(bytes("Reserved symbol: pSKOOP is the pilot token. A throwaway must not share it."));
        script.run();

        // ── guard: seeds without a gas margin fail BEFORE anything deploys ───
        _env();
        vm.deal(vm.addr(KEY_A), 0.005 ether);
        vm.expectRevert(bytes("Wallet A (deployer) does not hold enough ETH for the pool seeds plus a gas margin"));
        script.run();

        // ── guard: USDC with no ETH cannot pay for its own approval ──────────
        _env();
        vm.deal(vm.addr(KEY_A), 0.008083 ether);
        vm.deal(vm.addr(KEY_B), 0);
        vm.expectRevert(bytes("Wallet B (merchant owner) has no ETH for gas - it broadcasts the USDC approval and cannot pay for it"));
        script.run();

        // ── the real thing, with the balances the real wallets hold ──────────
        _env();
        (address A, address B) = _fundLikeTheRealWallets();
        uint256 aBefore    = A.balance;
        uint256 bUsdcBefore= IERC20(USDC).balanceOf(B);

        vm.recordLogs();
        script.run();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 registered;
        uint256 deployed;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("SuiteRegistered(address,address,address,address,address,uint256)")) registered++;
            // The staged factory emits MerchantActivated, not MerchantDeployed — a merchant
            // now exists only once stage 3 has run, which is the whole point of staging.
            if (logs[i].topics[0] == keccak256("MerchantActivated(address,uint256)")) deployed++;
        }

        assertEq(deployed,   2, "two merchants activated");
        assertEq(registered, 2, "both registered into the throwaway controller this run created");
        assertLt(A.balance, aBefore, "wallet A spent ETH on seeds and gas");
        assertLt(IERC20(USDC).balanceOf(B), bUsdcBefore, "wallet B's USDC went into the pools");

        emit log_named_decimal_uint("A ETH before", aBefore, 18);
        emit log_named_decimal_uint("A ETH after",  A.balance, 18);
        emit log_named_decimal_uint("B USDC after", IERC20(USDC).balanceOf(B), 6);
        emit log("the script runs end to end on the funding we actually have");
    }
}
