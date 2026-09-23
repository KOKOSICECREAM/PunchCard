// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/RewardEscrow.sol";

/// @title The config files must agree with the contracts they describe
///
/// @notice `deploy/network/base-mainnet.json` is where an operator looks up a figure at
///         deploy time. Nothing made it agree with the code, and on 2026-09-21 two entries
///         did not:
///
///         - `cliffDays: 180` / `vestDays: 1080`, unchanged since CLIFF_DURATION and
///           VEST_DURATION became 30 and 730. A team schedule quoted from this file was out
///           by 150 days on the cliff and a full year on the term.
///         - `dailyCap: 500000`, cited by `_template.json` as the bound on perTxFloor and
///           perTxMax. There is no DAILY_CAP in any contract. The real constructor check is
///           `_perTxMax <= perDay * MAX_DRAWER_DAYS`, and a value taken from that phantom
///           cap would have reverted step 3 AFTER the network was already deployed.
///
///         Both were the same failure: a number that looked authoritative, lived beside the
///         code rather than in it, and was never checked against anything. These tests are
///         the check.
contract ConfigMatchesContractsTest is Test {

    string config;
    RewardEscrow escrow;

    function setUp() public {
        config = vm.readFile("deploy/network/base-mainnet.json");
        // A real escrow, built with the real allocation, so the ceiling below is the one the
        // constructor enforces rather than one this test recomputed and could get wrong the
        // same way the config did.
        escrow = new RewardEscrow(
            address(0x1), address(0x2), address(0x3), address(0x4),
            45_000_000 * 1e6, 1, 50_000 * 1e6, address(this)
        );
    }

    function _num(string memory key) private view returns (uint256) {
        return vm.parseJsonUint(config, key);
    }

    function _str(string memory key) private view returns (uint256) {
        return vm.parseUint(vm.parseJsonString(config, key));
    }

    // ── the two that were actually wrong ──────────────────────────────────────

    /// @dev Read from the contract SOURCE rather than a deployed instance: these live on the
    ///      factories, whose constructors take eleven arguments, and the point of the check is
    ///      to catch a config figure drifting from a declaration — which the declaration text
    ///      answers directly. Same technique DeploymentInvariants.t.sol uses on the scripts.
    function test_theTeamScheduleMatchesTheContracts() public view {
        string memory src = vm.readFile("contracts/StagedTokenFactory.sol");
        _declares(src, "CLIFF_DURATION",    _num(".constants.cliffDays"));
        _declares(src, "VEST_DURATION",     _num(".constants.vestDays"));
        _declares(src, "TIMELOCK_DURATION", _num(".constants.timelockDays"));
    }

    /// Asserts the source literally declares `NAME = <days> days`, so a config value that has
    /// drifted from the constant fails by name.
    function _declares(string memory src, string memory name, uint256 configDays) private pure {
        // The declarations are aligned on `=`, so the padding differs per constant. Squash
        // runs of spaces first and the needle stops depending on how the file is formatted.
        string memory needle = string.concat(name, " = ", vm.toString(configDays), " days;");
        assertTrue(_contains(_squash(src), needle),
            string.concat("config says ", vm.toString(configDays), " days for ", name,
                          ", but StagedTokenFactory.sol does not declare that"));
    }

    /// The ceiling is derived, not declared, which is exactly why it drifted. Recompute it
    /// from the constants that enforce it rather than trusting either number alone.
    function test_thePerTxCeilingIsTheOneTheConstructorEnforces() public view {
        uint256 ceiling = escrow.maxDrawer();   // perDay * MAX_DRAWER_DAYS, from the contract

        assertEq(_str(".constants.perTxCeiling"), ceiling,
            "perTxCeiling does not match perDay * MAX_DRAWER_DAYS");

        // And the value SKOOP will actually be deployed with must clear it.
        string memory skoop = vm.readFile("deploy/merchants/skoop.json");
        uint256 perTxMax = vm.parseUint(vm.parseJsonString(skoop, ".escrowParams.perTxMax"));
        uint256 perTxFloor = vm.parseUint(vm.parseJsonString(skoop, ".escrowParams.perTxFloor"));

        assertGt(perTxFloor, 0, "perTxFloor must be > 0 - the constructor requires it");
        assertGe(perTxMax, perTxFloor, "perTxMax below perTxFloor - the constructor requires it");
        assertLe(perTxMax, ceiling,
            "skoop.json perTxMax exceeds the drawer ceiling - step 3 would revert 'Max above drawer ceiling'");
    }

    /// The phantom itself. Nothing in the contracts is named dailyCap, so nothing in the
    /// config may reintroduce it as though something were.
    function test_noConfigFileResurrectsTheDailyCap() public view {
        string[3] memory files = [
            "deploy/network/base-mainnet.json",
            "deploy/merchants/_template.json",
            "deploy/merchants/skoop.json"
        ];
        for (uint256 i = 0; i < files.length; i++) {
            string memory src = vm.readFile(files[i]);
            assertFalse(
                _contains(src, "dailyCap (500000)"),
                string.concat(files[i], " cites a dailyCap bound that no contract enforces")
            );
        }
    }

    // ── the allocations, which have not drifted and must not ──────────────────

    function test_theAllocationsMatchTheContract() public view {
        string memory src = vm.readFile("contracts/StagedTokenFactory.sol");
        _alloc(src, "REWARDS_ALLOC",   _str(".constants.rewardsAlloc"));
        _alloc(src, "LP_ALLOC",        _str(".constants.lpAlloc"));
        _alloc(src, "TEAM_ALLOC",      _str(".constants.teamAlloc"));
        _alloc(src, "TREASURY_ALLOC",  _str(".constants.treasuryAlloc"));
        _alloc(src, "LAUNCH_LP_ALLOC", _str(".constants.launchLpAlloc"));

        // The reserve is derived, so check the arithmetic rather than the text.
        assertEq(_str(".constants.lpReserve"),
                 _str(".constants.lpAlloc") - _str(".constants.launchLpAlloc"),
                 "lpReserve is not lpAlloc - launchLpAlloc");
    }

    /// The contract writes these with underscore separators (45_000_000), so compare against
    /// that spelling rather than the plain digits the JSON carries.
    function _alloc(string memory src, string memory name, uint256 whole) private pure {
        string memory grouped = _group(whole);
        string memory needle  = string.concat(name, " = ", grouped, " * 1e6;");
        assertTrue(_contains(_squash(src), needle),
            string.concat("config value for ", name, " (", grouped, ") is not what StagedTokenFactory.sol declares"));
    }

    function _group(uint256 v) private pure returns (string memory) {
        bytes memory d = bytes(vm.toString(v));
        bytes memory out = new bytes(d.length + (d.length - 1) / 3);
        uint256 k = out.length;
        for (uint256 i = 0; i < d.length; i++) {
            if (i > 0 && i % 3 == 0) { out[--k] = "_"; }
            out[--k] = d[d.length - 1 - i];
        }
        return string(out);
    }

    function test_theWindDownDurationMatches() public view {
        string memory src = vm.readFile("contracts/WindDownController.sol");
        assertTrue(_contains(_squash(src), string.concat("WIND_DOWN_DURATION = ",
            vm.toString(_num(".constants.windDownDays")), " days;")),
            "windDownDays does not match WIND_DOWN_DURATION");
    }

    /// Collapse runs of spaces to one, so needles do not depend on `=` alignment.
    function _squash(string memory src) private pure returns (string memory) {
        bytes memory b = bytes(src);
        bytes memory out = new bytes(b.length);
        uint256 k;
        bool lastWasSpace;
        for (uint256 i = 0; i < b.length; i++) {
            bool isSpace = b[i] == 0x20;
            if (isSpace && lastWasSpace) continue;
            out[k++] = b[i];
            lastWasSpace = isSpace;
        }
        bytes memory trimmed = new bytes(k);
        for (uint256 i = 0; i < k; i++) trimmed[i] = out[i];
        return string(trimmed);
    }

    function _contains(string memory hay, string memory needle) private pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) { ok = false; break; }
            }
            if (ok) return true;
        }
        return false;
    }
}
