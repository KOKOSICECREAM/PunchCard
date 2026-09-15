// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../contracts/WindDownController.sol";
import "../contracts/PunchCardRouter.sol";
import "../contracts/deployers/SuiteDeployer.sol";
import "../contracts/beta/TokenFactoryBeta.sol";
import "../contracts/beta/LockerDeployerBeta.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title DeployMicroRehearsal — a ~$25 disposable network, start to finish, in one command
///
/// @notice **Everything this deploys is throwaway and must stay throwaway.** It stands up a
///         complete parallel network — its own controller, factory and router — seeds one or
///         two tiny merchants, and never touches the real one.
///
/// @dev **Why a dedicated script rather than DeployNetworkBeta with small numbers.**
///      The beta script is used for two different things: the Stage 0 rehearsal and the
///      Stage 1 beta with real merchants. The difference between them is which numbers are
///      in the environment — which means the difference between "disposable" and "the
///      network" is a shell variable. That is the shape of mistake this codebase keeps
///      writing warnings about, so here the rehearsal constants are `constant`:
///      `MICRO_USDC_FLOOR` and `MICRO_ETH_FLOOR` cannot be raised by an environment
///      variable, and the symbol guard below cannot be turned off at all.
///
///      **The one rule that has no undo.** `WindDownController.register()` sets
///      `_registered[token] = true` and nothing anywhere clears it. A merchant registered
///      into a controller is on that network permanently — the router quotes it forever,
///      and disabling the factory that created it changes nothing, because disabling only
///      stops NEW registrations. A $25 throwaway in the real controller becomes the first
///      thing on the PunchCard network, for good. So this script always deploys its own
///      controller and offers no way to point at an existing one.
///
///      **Why the BETA lineage and not the pilot's.** The pSKOOP pilot uses
///      `TokenFactoryPilot`, whose hatch never closes by itself, and the fork rehearsal in
///      `test/SkoopMigration.t.sol` deploys that lineage precisely because it should
///      rehearse the plan. This script is not rehearsing the pilot. It is testing live
///      deploy mechanics — fresh controller, pool creation, approvals, quoting, fees, dapp
///      wiring — and its most important property is different: it is a disposable artifact
///      left on public mainnet, so if whoever runs it gets distracted it must **decay into
///      safety**. A beta locker's hatch self-closes after 30 days. A pilot locker's stays
///      open forever, which is correct for a pilot somebody is actively minding and wrong
///      for a throwaway nobody is.
///
///          micro       disposable mechanical test    Beta       hatch self-closes
///          pilot       live pSKOOP                   Pilot      hatch open until lockLP()
///          production  merchants                     none       no hatch, ever
///
///      **Keys.** This broadcasts as two different signers, because the step most likely to
///      fail on launch day is the cross-wallet one: ownerWallet approves the factory, the
///      deployer calls deploy(), and deploy() pulls from ownerWallet rather than from
///      msg.sender. A single-wallet rehearsal proves deployability and skips exactly that.
///      Both keys are passed raw, which is acceptable here and nowhere else: these wallets
///      hold ~$25 and are discarded afterwards. Never put a funded wallet's key in an
///      environment variable.
///
///      Run:
///        PC_MICRO_REHEARSAL=true PC_CREATE_NEW_NETWORK=true \
///        PC_KEY_A=0x… PC_KEY_B=0x… \
///        PC_POSITION_MANAGER=… PC_SWAP_ROUTER=… PC_USDC=… PC_WETH=… PC_ETH_USD_FEED=… \
///        forge script script/DeployMicroRehearsal.s.sol --rpc-url $BASE --broadcast
///
///      Drop `--broadcast` to simulate first. Do that.
contract DeployMicroRehearsal is Script {

    /// @notice $5 each. Constants, not environment variables — see the note above.
    uint256 constant MICRO_USDC_FLOOR = 5 * 1e8;
    uint256 constant MICRO_ETH_FLOOR  = 5 * 1e8;

    uint256 constant ROUTER_FEE_BPS = 30;

    /// @notice ~$6 of ETH at $2,400, against a $5 floor.
    /// @dev Headroom is the whole point of the number. The floor is USD-denominated and
    ///      checked against Chainlink inside deploy(), so a seed sized to clear $5 exactly
    ///      reverts on a 1% price move between funding the wallet and running the script.
    ///      That is not a hypothetical margin for ETH. Overshoot; the surplus comes back
    ///      out through evacuateLP() anyway.
    uint256 constant DEFAULT_ETH_SEED = 0.0025 ether;

    /// @notice Gas headroom required of wallet A on top of the seeds.
    /// @dev The full run is roughly 26M gas — a network deploy plus two merchant suites,
    ///      each of which deploys five contracts and creates and mints two Uniswap pools.
    ///      At Base's typical sub-0.01 gwei that is well under a dollar, so this margin is
    ///      deliberately generous rather than tight. Running out halfway through leaves a
    ///      half-built network on mainnet that nothing cleans up.
    uint256 constant GAS_MARGIN = 0.0005 ether;

    struct Merchant {
        string  name;
        string  symbol;
        uint256 usdcSeed;
        uint256 ethSeed;
    }

    function run() external {
        // ── acknowledgements ──────────────────────────────────────────────────
        require(
            vm.envOr("PC_MICRO_REHEARSAL", false),
            "Set PC_MICRO_REHEARSAL=true. This deploys a disposable parallel network and tiny merchants that are NOT part of the PunchCard network."
        );
        require(
            vm.envOr("PC_CREATE_NEW_NETWORK", false),
            "This deploys a NEW WindDownController and therefore a NEW network. That is correct for a rehearsal and wrong for everything else. Set PC_CREATE_NEW_NETWORK=true to confirm."
        );

        uint256 keyA = vm.envUint("PC_KEY_A");   // deployer / multisig / fee recipient
        uint256 keyB = vm.envUint("PC_KEY_B");   // merchant owner / team / operator
        address A = vm.addr(keyA);
        address B = vm.addr(keyB);
        require(A != B, "PC_KEY_A and PC_KEY_B must be different wallets - the point is to exercise the cross-wallet approval");

        address posMgr     = vm.envAddress("PC_POSITION_MANAGER");
        address swapRouter = vm.envAddress("PC_SWAP_ROUTER");
        address usdc       = vm.envAddress("PC_USDC");
        address weth       = vm.envAddress("PC_WETH");
        address oracle     = vm.envAddress("PC_ETH_USD_FEED");

        require(posMgr.code.length     > 0, "position manager has no code");
        require(swapRouter.code.length > 0, "swap router has no code");
        require(usdc.code.length       > 0, "USDC has no code");
        require(weth.code.length       > 0, "WETH has no code");
        require(oracle.code.length     > 0, "oracle has no code");

        // ── merchants ─────────────────────────────────────────────────────────
        // Two by default: cross-merchant routing is the one behaviour a single merchant
        // cannot exercise at all, and it is the reason PunchCardRouter exists.
        bool two = vm.envOr("PC_MICRO_TWO_MERCHANTS", true);

        Merchant[] memory ms = new Merchant[](two ? 2 : 1);
        ms[0] = Merchant({
            name:     vm.envOr("PC_MICRO_NAME_A",   string("PunchCard Micro A")),
            symbol:   vm.envOr("PC_MICRO_SYMBOL_A", string("PCMA")),
            usdcSeed: vm.envOr("PC_MICRO_USDC_A",   uint256(5 * 1e6)),
            ethSeed:  vm.envOr("PC_MICRO_ETH_A",    uint256(DEFAULT_ETH_SEED))
        });
        if (two) {
            ms[1] = Merchant({
                name:     vm.envOr("PC_MICRO_NAME_B",   string("PunchCard Micro B")),
                symbol:   vm.envOr("PC_MICRO_SYMBOL_B", string("PCMB")),
                usdcSeed: vm.envOr("PC_MICRO_USDC_B",   uint256(5 * 1e6)),
                ethSeed:  vm.envOr("PC_MICRO_ETH_B",    uint256(DEFAULT_ETH_SEED))
            });
        }

        uint256 totalUsdc;
        uint256 totalEth;
        for (uint256 i = 0; i < ms.length; i++) {
            _rejectReservedSymbol(ms[i].symbol);
            totalUsdc += ms[i].usdcSeed;
            totalEth  += ms[i].ethSeed;
        }

        // A rehearsal that quietly grows into a real launch is the failure the whole
        // micro-launch runbook is written against. Cap it in code.
        require(totalUsdc <= 100 * 1e6, "Total USDC seed above $100 - this is no longer a micro rehearsal");
        require(IERC20(usdc).balanceOf(B) >= totalUsdc, "Wallet B (merchant owner) does not hold enough USDC - deploy() pulls from ownerWallet, not from the deployer");
        // Seeds AND a gas margin. The message used to say "plus gas" while checking only
        // the seeds, so a wallet holding exactly the seed total passed the check and then
        // ran out mid-broadcast — after the controller, factory and router were already
        // deployed and paid for. Base is cheap enough that the margin is rounding error:
        // the whole run is ~26M gas, well under $1 at current prices.
        require(
            A.balance >= totalEth + GAS_MARGIN,
            "Wallet A (deployer) does not hold enough ETH for the pool seeds plus a gas margin"
        );

        // B never sends ETH, only the approve() — but an approve still costs gas, and a
        // wallet funded with USDC and nothing else fails on its first transaction. Cheap to
        // check here, annoying to diagnose halfway through a broadcast.
        require(B.balance > 0, "Wallet B (merchant owner) has no ETH for gas - it broadcasts the USDC approval and cannot pay for it");

        // ── network, as wallet A ──────────────────────────────────────────────
        vm.startBroadcast(keyA);

        SuiteDeployer       suite  = new SuiteDeployer();
        LockerDeployerBeta  locker = new LockerDeployerBeta();

        address predictedFactory = vm.computeCreateAddress(A, vm.getNonce(A) + 1);
        WindDownController wdc = new WindDownController(A, predictedFactory);

        TokenFactoryBeta factory = new TokenFactoryBeta(
            A,              // multisig — wallet A stands in, disposable
            A,              // deployer hot wallet
            address(wdc), posMgr, usdc, weth, oracle,
            A,              // fee recipient
            address(suite), address(locker),
            MICRO_USDC_FLOOR, MICRO_ETH_FLOOR
        );
        require(address(factory) == predictedFactory, "factory address mismatch");

        PunchCardRouter router = new PunchCardRouter(
            A, address(wdc), swapRouter, usdc, weth, ROUTER_FEE_BPS, A
        );

        vm.stopBroadcast();

        // ── merchants: B approves, A deploys ──────────────────────────────────
        for (uint256 i = 0; i < ms.length; i++) {
            Merchant memory m = ms[i];

            // Exact amount, immediately before use. A standing allowance on a factory
            // anyone can call is a live risk even at rehearsal size.
            vm.broadcast(keyB);
            IERC20(usdc).approve(address(factory), m.usdcSeed);

            vm.broadcast(keyA);
            factory.deploy{value: m.ethSeed}(TokenFactory.DeployParams({
                name:           m.name,
                symbol:         m.symbol,
                ipfsHash:       keccak256(bytes(m.symbol)),
                ownerWallet:    B,
                teamWallet:     B,
                operator:       B,
                usdcFeeTier:    3000,
                ethFeeTier:     3000,
                usdcPairAmount: m.usdcSeed,
                ethPairAmount:  m.ethSeed,
                perTxFloor:     1e6,
                perTxMax:       20_000 * 1e6
            }));
        }

        // ── say plainly what was just created ─────────────────────────────────
        console2.log("");
        console2.log("*** DISPOSABLE REHEARSAL NETWORK - NOT THE PUNCHCARD NETWORK ***");
        console2.log("These addresses must never appear in deploy/network/base-mainnet.json,");
        console2.log("and no real merchant may ever be deployed against this factory.");
        console2.log("");
        console2.log("windDownController  ", address(wdc));
        console2.log("tokenFactoryBeta    ", address(factory));
        console2.log("punchCardRouter     ", address(router));
        console2.log("suiteDeployer       ", address(suite));
        console2.log("lockerDeployerBeta  ", address(locker));
        console2.log("walletA (deployer)  ", A);
        console2.log("walletB (merchant)  ", B);
        console2.log("");
        console2.log("Read the merchant addresses from the MerchantDeployed events.");
        console2.log("When finished: evacuateLP() from wallet B recovers the seed and bricks each locker.");
        console2.log("If you forget, the hatch closes by itself 30 days from deploy and the seed stays in.");
    }

    /// @dev The pilot's symbol was chosen so that two tokens on Base could be told apart.
    ///      A throwaway carrying it would undo that, so this cannot be overridden.
    function _rejectReservedSymbol(string memory symbol) internal pure {
        bytes32 h = keccak256(bytes(symbol));
        require(h != keccak256("pSKOOP"), "Reserved symbol: pSKOOP is the pilot token. A throwaway must not share it.");
        require(h != keccak256("PSKOOP"), "Reserved symbol: pSKOOP is the pilot token. A throwaway must not share it.");
        require(h != keccak256("SKOOP"),  "Reserved symbol: SKOOP is the live 2023 token.");
        require(bytes(symbol).length > 0, "Empty symbol");
    }
}
