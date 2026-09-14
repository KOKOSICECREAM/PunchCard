// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

/// @title Deployment invariants enforced against the scripts themselves
/// @notice Some of this system's worst mistakes are not reachable from Solidity, because
///         they live in which script somebody runs. The highest one is:
///
///             One WindDownController is the network. A second is a forked network.
///
///         The router binds to one controller and only recognises merchants in that
///         controller's registry, so merchants registered under a second controller can
///         never swap against the first one's. It is unfixable afterwards and invisible
///         until a cross-stage swap fails.
///
///         That commandment was written in docs/staged-rollout.md, where it relies on
///         somebody having read it. These tests make it hold mechanically instead.
contract DeploymentInvariantsTest is Test {

    string[4] scripts = [
        "script/DeployNetwork.s.sol",
        "script/DeployNetworkBeta.s.sol",
        "script/DeployProductionFactory.s.sol",
        "script/DeployMerchant.s.sol"
    ];

    /// Any script that constructs a WindDownController must demand explicit
    /// acknowledgement that it is creating a new network.
    function test_everyNetworkCreatingScriptDemandsAcknowledgement() public view {
        for (uint256 i = 0; i < scripts.length; i++) {
            string memory src = vm.readFile(scripts[i]);
            if (_contains(src, "new WindDownController")) {
                assertTrue(
                    _contains(src, "PC_CREATE_NEW_NETWORK"),
                    string.concat(scripts[i], " creates a WindDownController without requiring PC_CREATE_NEW_NETWORK")
                );
            }
        }
    }

    /// Stage 2 adds a factory to the network that already exists. If it ever starts
    /// deploying a controller, it stops adding to the network and starts forking it.
    function test_productionFactoryScriptNeverCreatesAController() public view {
        string memory src = vm.readFile("script/DeployProductionFactory.s.sol");
        assertFalse(
            _contains(src, "new WindDownController"),
            "DeployProductionFactory must reuse the existing controller, never deploy one"
        );
        assertTrue(
            _contains(src, "PC_WIND_DOWN_CONTROLLER"),
            "DeployProductionFactory must take the existing controller as input"
        );
    }

    /// The beta lineage must never be reachable from the production deploy path.
    function test_productionScriptsNeverImportTheBetaLineage() public view {
        string[2] memory prod = ["script/DeployNetwork.s.sol", "script/DeployProductionFactory.s.sol"];
        for (uint256 i = 0; i < prod.length; i++) {
            string memory src = vm.readFile(prod[i]);
            assertFalse(_contains(src, "contracts/beta/"),
                string.concat(prod[i], " must not import the beta lineage"));
            assertFalse(_contains(src, "Beta"),
                string.concat(prod[i], " must not reference beta contracts"));
        }
    }

    function _contains(string memory haystack, string memory needle) private pure returns (bool) {
        bytes memory h = bytes(haystack);
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
