// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

/// @notice Every mixed-case address in the deploy config must carry a valid EIP-55 checksum.
///
/// @dev The router's address was written into base-mainnet.json by hand on the day it was
///      deployed, with the case of its letters made up: 0xb64a96F69be1… instead of
///      0xB64A96f69bE1…. The hex was right, so nothing that lowercases addresses noticed.
///      Anything that honours checksums does — Sourcify rejected it as "Invalid address",
///      which is how it surfaced, and ethers v6 (the dapp, the POS, the reporting pages)
///      throws on it. A wrong checksum is not cosmetic: it is the one check that catches a
///      mistyped address, so a config that carries a fake one has switched that check off.
///      All-lowercase and all-uppercase addresses carry no checksum and are skipped.
contract ConfigAddressChecksumsTest is Test {
    string[] files;

    function setUp() public {
        files.push("deploy/network/base-mainnet.json");
        files.push("deploy/network/locker-test.json");
        files.push("deploy/merchants/skoop.json");
    }

    function test_everyMixedCaseAddressHasAValidChecksum() public view {
        uint256 checked;
        for (uint256 f; f < files.length; f++) {
            bytes memory b = bytes(vm.readFile(files[f]));
            for (uint256 i; i + 42 <= b.length; i++) {
                if (b[i] != "0" || (b[i + 1] != "x" && b[i + 1] != "X")) continue;
                if (!_isHexRun(b, i + 2, 40)) continue;
                if (i + 42 < b.length && _isHex(b[i + 42])) continue;   // longer hex: a hash, not an address
                if (i > 0 && _isHex(b[i - 1])) continue;
                bytes memory a = _slice(b, i + 2, 40);
                if (!_isMixed(a)) continue;
                checked++;
                require(_checksumOk(a), string.concat(
                    files[f], ": bad EIP-55 checksum on 0x", string(a),
                    " - should be ", vm.toString(vm.parseAddress(string.concat("0x", _lower(a))))
                ));
            }
        }
        assertGt(checked, 10, "found almost no addresses - is the scanner reading the files?");
    }

    function test_theScannerCatchesTheOriginalMistake() public pure {
        assertFalse(_checksumOk(bytes("b64a96F69be171Fe2D81f03b6d3c4029367D4F08")), "the bad router checksum must fail");
        assertTrue (_checksumOk(bytes("B64A96f69bE171FE2d81F03b6D3c4029367d4f08")), "the real router checksum must pass");
    }

    // ── EIP-55 ────────────────────────────────────────────────────────────────
    function _checksumOk(bytes memory a) internal pure returns (bool) {
        bytes32 h = keccak256(bytes(_lower(a)));
        for (uint256 k; k < 40; k++) {
            bytes1 c = a[k];
            if (c >= "0" && c <= "9") continue;
            uint8 nib = uint8(h[k / 2]) >> (k % 2 == 0 ? 4 : 0) & 0x0f;
            bool upper = c >= "A" && c <= "F";
            if (upper != (nib >= 8)) return false;
        }
        return true;
    }

    function _lower(bytes memory a) internal pure returns (string memory) {
        bytes memory o = new bytes(a.length);
        for (uint256 k; k < a.length; k++) o[k] = (a[k] >= "A" && a[k] <= "F") ? bytes1(uint8(a[k]) + 32) : a[k];
        return string(o);
    }

    function _isMixed(bytes memory a) internal pure returns (bool) {
        bool lo; bool up;
        for (uint256 k; k < a.length; k++) {
            if (a[k] >= "a" && a[k] <= "f") lo = true;
            if (a[k] >= "A" && a[k] <= "F") up = true;
        }
        return lo && up;
    }

    function _isHex(bytes1 c) internal pure returns (bool) {
        return (c >= "0" && c <= "9") || (c >= "a" && c <= "f") || (c >= "A" && c <= "F");
    }

    function _isHexRun(bytes memory b, uint256 s, uint256 n) internal pure returns (bool) {
        for (uint256 k; k < n; k++) if (!_isHex(b[s + k])) return false;
        return true;
    }

    function _slice(bytes memory b, uint256 s, uint256 n) internal pure returns (bytes memory o) {
        o = new bytes(n);
        for (uint256 k; k < n; k++) o[k] = b[s + k];
    }
}
