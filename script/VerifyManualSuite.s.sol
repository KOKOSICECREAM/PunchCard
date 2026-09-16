// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

interface IV_ERC20 {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function symbol() external view returns (string memory);
}
interface IV_WDC {
    function isRegistered(address) external view returns (bool);
    function approvedCode(bytes32, bytes32) external view returns (bool);
    function registrars(address) external view returns (bool);
    function ROLE_TOKEN() external view returns (bytes32);
    function ROLE_ESCROW() external view returns (bytes32);
    function ROLE_VESTING() external view returns (bytes32);
    function ROLE_TREASURY() external view returns (bytes32);
    function ROLE_LOCKER() external view returns (bytes32);
}
interface IV_Pool {
    function slot0() external view returns (uint160 sqrtPriceX96, int24, uint16, uint16, uint16, uint8, bool);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
}
interface IV_Locker {
    function isInitialized() external view returns (bool);
    function reserveTokens() external view returns (uint256);
    function usdcFeeTier() external view returns (uint24);
    function ethFeeTier() external view returns (uint24);
    function ownerWallet() external view returns (address);
}
interface IV_Escrow {
    function ownerWallet() external view returns (address);
    function REWARDS_ALLOCATION() external view returns (uint256);
    function getDrawer(address) external view returns (uint256, uint256, uint256, bool);
}
interface IV_Vesting  { function teamWallet() external view returns (address); }
interface IV_Treasury { function ownerWallet() external view returns (address); }
interface IV_Oracle   { function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80); function decimals() external view returns (uint8); }
interface IV_Router   { function getPoolFeeTiers(address) external view returns (uint24, uint24); }

/// @title VerifyManualSuite — inspect a hand-assembled merchant before admitting it
///
/// @notice The factory path proves a suite was created by known code. The manual path
///         cannot, so `WindDownController.registerManual` checks the one thing a person
///         cannot check reliably by eye: that every contract is bytecode the multisig
///         approved.
///
///         Everything else it deliberately does not check — balances, pools, liquidity,
///         wallets — because encoding those on-chain would rebuild the factory inside the
///         controller, which is what the manual path exists to avoid. **This script is that
///         everything else.** It is the registrar's homework, and it is the difference
///         between "flexible" and "careless".
///
/// @dev Read-only. Registers nothing, signs nothing, deploys nothing. Needs only an RPC.
///
///      Two modes, because the two callers want different answers:
///
///          PC_MODE=strict   a future merchant admitted by hand. Allocations must be exact.
///          PC_MODE=pilot    SKOOP. Allocations are reported with the shortfall and do not
///                           fail the run, because the pilot is funded by hand on purpose
///                           and must not be blocked by a transfer that can still be topped
///                           up. Everything that makes the token unusable still fails.
///
///      It reports every check before deciding, rather than stopping at the first problem.
///      A registrar fixing three things wants to see three, not to run this three times.
contract VerifyManualSuite is Script {

    uint256 private failures;
    uint256 private warnings;

    // Reported, and fatal only in strict mode.
    uint256 constant TOTAL_SUPPLY   = 100_000_000 * 1e6;
    uint256 constant REWARDS_ALLOC  =  45_000_000 * 1e6;
    uint256 constant TEAM_ALLOC     =  15_000_000 * 1e6;
    uint256 constant TREASURY_ALLOC =  10_000_000 * 1e6;
    uint256 constant LP_RESERVE     =  27_000_000 * 1e6;

    /// @dev Pools are seeded independently, so their implied prices never match exactly.
    ///      5% is loose enough for rounding and a little drift, tight enough that a pool
    ///      opened at the wrong price — the thing a mempool watcher would do between a
    ///      hand-assembly's steps — cannot slip through.
    uint256 constant PRICE_TOLERANCE_BPS = 500;

    struct Inputs {
        address wdc; address router; address oracle;
        address token; address escrow; address vesting; address treasury; address locker;
        address owner; address team; address operator;
        address usdcPool; address ethPool;
        address usdc; address weth;
        bool strict;
    }

    function run() external {
        Inputs memory i = _inputs();

        console2.log("=====================================================");
        console2.log(string.concat("  Manual suite verification  [", i.strict ? "STRICT" : "PILOT", " mode]"));
        console2.log(string.concat("  token ", vm.toString(i.token)));
        console2.log("=====================================================");
        console2.log("");

        _checkCode(i);
        _checkCodehashes(i);
        _checkSupplyAndAllocations(i);
        _checkWallets(i);
        _checkPools(i);
        _checkNotYetOnNetwork(i);

        console2.log("");
        console2.log("-----------------------------------------------------");
        if (failures == 0) {
            console2.log(warnings == 0 ? "  ALL CHECKS PASSED" : "  PASSED, with warnings above");
            console2.log("");
            console2.log("  Run this from an approved registrar:");
            console2.log("");
            console2.log(string.concat(
                "  cast send ", vm.toString(i.wdc), " \\\n",
                "    'registerManual(address,address,address,address,address)' \\\n",
                "    ", vm.toString(i.token), " ", vm.toString(i.escrow), " \\\n",
                "    ", vm.toString(i.vesting), " ", vm.toString(i.treasury), " \\\n",
                "    ", vm.toString(i.locker), " \\\n",
                "    --rpc-url $R --private-key $PC_KEY_REGISTRAR"
            ));
        } else {
            console2.log("  DO NOT REGISTER. Failures above must be resolved first.");
        }
        console2.log("-----------------------------------------------------");

        require(failures == 0, "Verification failed - see the report above");
    }

    // ── 1. code where code is expected ───────────────────────────────────────

    function _checkCode(Inputs memory i) private {
        console2.log("[1] contracts exist");
        _hasCode("token",    i.token);
        _hasCode("escrow",   i.escrow);
        _hasCode("vesting",  i.vesting);
        _hasCode("treasury", i.treasury);
        _hasCode("locker",   i.locker);
        console2.log("");
    }

    // ── 2-3. the check registerManual itself will make ───────────────────────

    function _checkCodehashes(Inputs memory i) private {
        console2.log("[2] runtime codehashes approved by the multisig");
        IV_WDC w = IV_WDC(i.wdc);
        _codeOk("token",    i.token,    w.ROLE_TOKEN(),    i.wdc);
        _codeOk("escrow",   i.escrow,   w.ROLE_ESCROW(),   i.wdc);
        _codeOk("vesting",  i.vesting,  w.ROLE_VESTING(),  i.wdc);
        _codeOk("treasury", i.treasury, w.ROLE_TREASURY(), i.wdc);
        _codeOk("locker",   i.locker,   w.ROLE_LOCKER(),   i.wdc);
        console2.log("");
    }

    // ── 4-8. supply, allocations, reserve ────────────────────────────────────

    function _checkSupplyAndAllocations(Inputs memory i) private {
        console2.log("[3] supply and allocations");
        uint256 supply = IV_ERC20(i.token).totalSupply();
        _eq("total supply", supply, TOTAL_SUPPLY, true);

        _alloc(i, "escrow  ", i.escrow,   REWARDS_ALLOC);
        _alloc(i, "vesting ", i.vesting,  TEAM_ALLOC);
        _alloc(i, "treasury", i.treasury, TREASURY_ALLOC);

        uint256 lockerBal = IV_ERC20(i.token).balanceOf(i.locker);
        _report("locker reserve", lockerBal, LP_RESERVE);
        if (lockerBal < LP_RESERVE) _flag(i.strict, "locker holds less than the 27M reserve");

        if (!IV_Locker(i.locker).isInitialized()) {
            _fail("locker is NOT initialised - it holds no LP positions, so the token cannot trade");
        } else {
            console2.log("    locker initialised: yes");
        }
        console2.log("");
    }

    // ── 12. where the rest of the supply sat ─────────────────────────────────

    function _checkWallets(Inputs memory i) private {
        console2.log("[4] wallets");
        _addrEq("escrow.ownerWallet",   IV_Escrow(i.escrow).ownerWallet(),     i.owner);
        _addrEq("treasury.ownerWallet", IV_Treasury(i.treasury).ownerWallet(), i.owner);
        _addrEq("locker.ownerWallet",   IV_Locker(i.locker).ownerWallet(),     i.owner);
        _addrEq("vesting.teamWallet",   IV_Vesting(i.vesting).teamWallet(),    i.team);

        (,,, bool active) = IV_Escrow(i.escrow).getDrawer(i.operator);
        if (active) console2.log("    operator drawer active: yes");
        else        _fail("the expected operator has no active drawer - the POS cannot issue rewards");

        uint256 ownerBal = IV_ERC20(i.token).balanceOf(i.owner);
        if (ownerBal == 0) {
            console2.log("    owner holds no merchant tokens: yes");
        } else {
            console2.log(string.concat("    owner still holds ", _amt(ownerBal), " - unallocated supply"));
            _flag(i.strict, "owner wallet still holds merchant tokens");
        }
        console2.log("");
    }

    // ── 9-11. the market ─────────────────────────────────────────────────────

    function _checkPools(Inputs memory i) private {
        console2.log("[5] pools");
        _hasCode("usdc pool", i.usdcPool);
        _hasCode("eth pool",  i.ethPool);
        if (i.usdcPool.code.length == 0 || i.ethPool.code.length == 0) { console2.log(""); return; }

        _feeTier("usdc", i.usdcPool, IV_Locker(i.locker).usdcFeeTier());
        _feeTier("eth ", i.ethPool,  IV_Locker(i.locker).ethFeeTier());

        if (IV_Pool(i.usdcPool).liquidity() == 0) _fail("usdc pool has zero liquidity");
        if (IV_Pool(i.ethPool).liquidity()  == 0) _fail("eth pool has zero liquidity");

        uint256 usdPerTokenFromUsdc = _priceUsd(i.usdcPool, i.token, i.usdc, 6, 1e8);
        uint256 ethUsd              = _ethUsd(i.oracle);
        uint256 usdPerTokenFromEth  = _priceUsd(i.ethPool, i.token, i.weth, 18, ethUsd);

        console2.log(string.concat("    implied price, usdc pool: $", _usd(usdPerTokenFromUsdc)));
        console2.log(string.concat("    implied price, eth  pool: $", _usd(usdPerTokenFromEth)));

        if (usdPerTokenFromUsdc == 0 || usdPerTokenFromEth == 0) {
            _fail("a pool reports a zero price - it was never initialised at a real price");
        } else {
            uint256 hi = usdPerTokenFromUsdc > usdPerTokenFromEth ? usdPerTokenFromUsdc : usdPerTokenFromEth;
            uint256 lo = usdPerTokenFromUsdc > usdPerTokenFromEth ? usdPerTokenFromEth : usdPerTokenFromUsdc;
            uint256 driftBps = ((hi - lo) * 10_000) / hi;
            console2.log(string.concat("    drift between pools: ", vm.toString(driftBps), " bps"));
            if (driftBps > PRICE_TOLERANCE_BPS) {
                _fail("pool prices disagree by more than 5% - one was opened at the wrong price");
            }
        }
        console2.log("");
    }

    // ── 13-14. not on the network yet ────────────────────────────────────────

    function _checkNotYetOnNetwork(Inputs memory i) private {
        console2.log("[6] not on the network yet");
        if (IV_WDC(i.wdc).isRegistered(i.token)) {
            _fail("token is ALREADY registered - registerManual would revert");
        } else {
            console2.log("    isRegistered: false, as expected");
        }

        if (i.router != address(0)) {
            (bool ok, ) = i.router.staticcall(
                abi.encodeWithSelector(IV_Router.getPoolFeeTiers.selector, i.token)
            );
            if (ok) _fail("the router already serves this token before registration");
            else    console2.log("    router refuses it: yes");
        }
        console2.log("");
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _inputs() private view returns (Inputs memory i) {
        i.wdc      = vm.envAddress("PC_WIND_DOWN_CONTROLLER");
        i.token    = vm.envAddress("PC_TOKEN");
        i.escrow   = vm.envAddress("PC_ESCROW");
        i.vesting  = vm.envAddress("PC_VESTING");
        i.treasury = vm.envAddress("PC_TREASURY");
        i.locker   = vm.envAddress("PC_LOCKER");
        i.owner    = vm.envAddress("PC_EXPECT_OWNER");
        i.team     = vm.envAddress("PC_EXPECT_TEAM");
        i.operator = vm.envAddress("PC_EXPECT_OPERATOR");
        i.usdcPool = vm.envAddress("PC_USDC_POOL");
        i.ethPool  = vm.envAddress("PC_ETH_POOL");
        i.usdc     = vm.envAddress("PC_USDC");
        i.weth     = vm.envAddress("PC_WETH");
        i.oracle   = vm.envAddress("PC_ETH_USD_FEED");
        i.router   = vm.envOr("PC_ROUTER", address(0));
        i.strict   = keccak256(bytes(vm.envOr("PC_MODE", string("pilot")))) == keccak256("strict");
    }

    function _hasCode(string memory what, address a) private {
        if (a == address(0))        { _fail(string.concat(what, " is the zero address")); return; }
        if (a.code.length == 0)     { _fail(string.concat("no code at ", what));          return; }
        console2.log(string.concat("    ", what, ": code present"));
    }

    function _codeOk(string memory what, address a, bytes32 role, address wdc) private {
        if (a.code.length == 0) return;                      // already reported
        if (IV_WDC(wdc).approvedCode(role, a.codehash)) {
            console2.log(string.concat("    ", what, ": approved"));
        } else {
            _fail(string.concat(what, " codehash is NOT approved - registerManual will revert"));
            console2.log(string.concat("      codehash ", vm.toString(a.codehash)));
        }
    }

    function _alloc(Inputs memory i, string memory what, address holder, uint256 target) private {
        uint256 actual = IV_ERC20(i.token).balanceOf(holder);
        _report(what, actual, target);
        if (actual != target) {
            _flag(i.strict, string.concat(what, " is not at its target"));
        }
    }

    /// @dev Strict fails; pilot warns. The distinction is the whole point of the two modes:
    ///      an allocation that is short can be topped up after registration, and blocking a
    ///      hand-funded pilot on it strands the launch. Anything that makes the token
    ///      unusable calls `_fail` directly and ignores the mode.
    function _flag(bool strict, string memory msg_) private {
        if (strict) _fail(msg_);
        else        _warn(msg_);
    }

    function _report(string memory what, uint256 actual, uint256 target) private {
        if (actual == target) {
            console2.log(string.concat("    ", what, ": ", _amt(actual), "  == target"));
        } else if (actual < target) {
            console2.log(string.concat("    ", what, ": ", _amt(actual), "  target ", _amt(target),
                "  SHORT ", _amt(target - actual)));
        } else {
            console2.log(string.concat("    ", what, ": ", _amt(actual), "  target ", _amt(target),
                "  OVER ", _amt(actual - target)));
        }
    }

    function _eq(string memory what, uint256 a, uint256 b, bool fatal) private {
        if (a == b) { console2.log(string.concat("    ", what, ": ", _amt(a))); return; }
        if (fatal) _fail(string.concat(what, " is ", _amt(a), ", expected ", _amt(b)));
    }

    function _addrEq(string memory what, address actual, address expected) private {
        if (actual == expected) console2.log(string.concat("    ", what, ": matches"));
        else _fail(string.concat(what, " is ", vm.toString(actual), ", expected ", vm.toString(expected)));
    }

    function _feeTier(string memory what, address pool, uint24 lockerSays) private {
        uint24 poolFee = IV_Pool(pool).fee();
        if (poolFee == lockerSays) {
            console2.log(string.concat("    ", what, " fee tier: ", vm.toString(uint256(poolFee)), " matches locker"));
        } else {
            _fail(string.concat(what, " pool fee tier ", vm.toString(uint256(poolFee)),
                " does not match the locker's ", vm.toString(uint256(lockerSays))));
        }
    }

    /// @dev Price of one merchant token in USD, 8dp. `pairUsd` is the pair asset's USD price
    ///      at 8dp — 1e8 for USDC, the oracle answer for WETH.
    ///
    ///      sqrtPriceX96 is shifted down by 48 before squaring so the square cannot
    ///      overflow uint256. That costs precision far below what a 5% tolerance cares
    ///      about, and this is a sanity check rather than an oracle.
    function _priceUsd(address pool, address token, address pair, uint8 pairDec, uint256 pairUsd)
        private view returns (uint256)
    {
        (uint160 sqrtP,,,,,,) = IV_Pool(pool).slot0();
        if (sqrtP == 0) return 0;

        uint256 p = uint256(sqrtP) >> 48;
        uint256 ratioX96 = p * p;                       // price(token1/token0) * 2^96

        bool tokenIsToken0 = IV_Pool(pool).token0() == token;
        uint256 pairPerToken;                           // pair raw units per 1e6 token, 1e18 scaled
        if (tokenIsToken0) {
            pairPerToken = (ratioX96 * 1e18) >> 96;
        } else {
            if (ratioX96 == 0) return 0;
            pairPerToken = (uint256(1e18) << 96) / ratioX96;
        }

        // raw -> whole units: token is 6dp, pair is pairDec
        // pairPerToken is (pair raw / token raw) * 1e18
        // whole pair per whole token = pairPerToken * 10^6 / 10^pairDec / 1e18
        uint256 scaled = pairPerToken * 1e6;
        uint256 wholePairPerTokenX18 = scaled / (10 ** pairDec);
        return (wholePairPerTokenX18 * pairUsd) / 1e18;
    }

    function _ethUsd(address oracle) private view returns (uint256) {
        (, int256 answer,,,) = IV_Oracle(oracle).latestRoundData();
        if (answer <= 0) return 0;
        uint8 dec = IV_Oracle(oracle).decimals();
        uint256 price = uint256(answer);
        if (dec < 8) price = price * (10 ** (8 - dec));
        else if (dec > 8) price = price / (10 ** (dec - 8));
        return price;
    }

    function _amt(uint256 raw) private pure returns (string memory) {
        return string.concat(vm.toString(raw / 1e6), ".", _pad6(raw % 1e6));
    }
    function _usd(uint256 x8) private pure returns (string memory) {
        return string.concat(vm.toString(x8 / 1e8), ".", _pad8(x8 % 1e8));
    }
    function _pad6(uint256 v) private pure returns (string memory) {
        string memory s = vm.toString(v);
        while (bytes(s).length < 6) s = string.concat("0", s);
        return s;
    }
    function _pad8(uint256 v) private pure returns (string memory) {
        string memory s = vm.toString(v);
        while (bytes(s).length < 8) s = string.concat("0", s);
        return s;
    }

    /// @dev Records as well as prints. An earlier draft made every check `view`, which
    ///      meant these counters could not be incremented — the report printed FAIL and the
    ///      final `require(failures == 0)` passed anyway. A verification script that cannot
    ///      fail is worse than none: it produces a signed-off feeling with no signature.
    function _fail(string memory m) private {
        failures++;
        console2.log(string.concat("    FAIL  ", m));
    }
    function _warn(string memory m) private {
        warnings++;
        console2.log(string.concat("    warn  ", m));
    }
}
