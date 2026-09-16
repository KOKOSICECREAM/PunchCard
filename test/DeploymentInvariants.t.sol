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

    /// @dev Every script under script/ belongs here. A hardcoded list silently stops
    ///      covering whatever is added next, and the check it stops applying is the one
    ///      that keeps a second controller — a second network — from being deployed by
    ///      accident. DeployMicroRehearsal.s.sol was added in exactly that gap.
    string[7] scripts = [
        "script/DeployNetwork.s.sol",
        "script/DeployNetworkBeta.s.sol",
        "script/DeployProductionFactory.s.sol",
        "script/DeployMerchant.s.sol",
        "script/DeployMicroRehearsal.s.sol",
        "script/DeployNetworkStaged.s.sol",
        "script/StageMerchant.s.sol"
    ];

    /// Scripts that build or drive the ATOMIC lineage. deploy() costs 17,325,962 against
    /// Base's 16,777,216 cap, so each of these must refuse to run on Base rather than
    /// deploying a network that can never onboard anyone.
    string[4] atomicScripts = [
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

    /// The list above is hardcoded, so it can fall behind the directory it describes —
    /// which is how DeployMicroRehearsal.s.sol came to exist unchecked. This fails when a
    /// script is added and not listed, rather than leaving the gap silent.
    function test_everyScriptOnDiskIsCovered() public view {
        Vm.DirEntry[] memory onDisk = vm.readDir("script");
        for (uint256 i = 0; i < onDisk.length; i++) {
            string memory path = onDisk[i].path;
            if (!_contains(path, ".s.sol")) continue;

            bool listed;
            for (uint256 j = 0; j < scripts.length; j++) {
                if (_contains(path, scripts[j])) { listed = true; break; }
            }
            assertTrue(listed, string.concat(path, " is not in the scripts list above - add it"));
        }
    }

    /// A rehearsal exists to be thrown away, so it must never be reachable from, or
    /// recorded alongside, the real network. The acknowledgement check above proves it
    /// deploys its own controller deliberately; this proves it cannot be pointed at
    /// someone else's.
    function test_microRehearsalCannotTargetAnExistingController() public view {
        string memory src = vm.readFile("script/DeployMicroRehearsal.s.sol");
        assertTrue(_contains(src, "new WindDownController"),
            "the rehearsal must deploy its own controller");
        assertFalse(_contains(src, "PC_WIND_DOWN_CONTROLLER"),
            "the rehearsal must offer no way to point at an existing controller - registration is permanent");
        assertTrue(_contains(src, "PC_MICRO_REHEARSAL"),
            "the rehearsal must demand its own acknowledgement, separate from PC_CREATE_NEW_NETWORK");
    }

    /// The micro rehearsal must use the SELF-CLOSING lineage, not the pilot's.
    ///
    /// It is a disposable artifact left on public mainnet, so its most important property
    /// is that it decays into safety when nobody is minding it: a beta locker's evacuation
    /// hatch shuts by itself after 30 days, a pilot locker's never does. "Rehearse the
    /// lineage you will deploy" is the right rule for `test/SkoopMigration.t.sol`, which
    /// rehearses the pSKOOP pilot. It is the wrong rule here, and this stops the two being
    /// conflated again later.
    function test_microRehearsalUsesTheSelfClosingLineage() public view {
        string memory src = vm.readFile("script/DeployMicroRehearsal.s.sol");
        assertTrue(_contains(src, "contracts/beta/"),
            "the micro rehearsal must use the beta lineage, whose hatch self-closes");
        assertFalse(_contains(src, "contracts/pilot/"),
            "the micro rehearsal must NOT use the pilot lineage - a throwaway with a hatch that never expires is a loaded gun left on mainnet");
        // `new TokenFactoryPilot`, not the bare name. These checks are substring matches
        // over source, so a bare name also matches the comment that explains why the pilot
        // lineage is NOT used here — which is prose doing the opposite of what it says, and
        // exactly the false positive that teaches people to weaken an assertion. Match the
        // construction instead: that is the thing being forbidden.
        assertFalse(_contains(src, "new TokenFactoryPilot"),
            "the micro rehearsal must not deploy the pilot factory");
        assertFalse(_contains(src, "new LockerDeployerPilot"),
            "the micro rehearsal must not deploy the pilot locker deployer");
        assertTrue(_contains(src, "new StagedTokenFactoryBeta"),
            "the micro rehearsal must deploy the STAGED beta factory - beta for the self-closing hatch, staged because the atomic one cannot deploy a merchant on Base");
    }

    /// The blocker, enforced rather than documented. A warning in a doc is a warning
    /// somebody has to have read; a chainid guard is one the RPC cannot ignore.
    function test_atomicScriptsRefuseToRunOnBase() public view {
        for (uint256 i = 0; i < atomicScripts.length; i++) {
            string memory src = vm.readFile(atomicScripts[i]);
            assertTrue(
                _contains(src, "block.chainid != 8453"),
                string.concat(atomicScripts[i], " builds or drives the atomic lineage and must refuse to run on Base")
            );
        }
    }

    /// The staged path must NOT carry that guard — it is the one that works on Base, and a
    /// guard copied into it by habit would block the only usable deployment path.
    function test_theStagedScriptsRunOnBase() public view {
        string[2] memory staged = ["script/DeployNetworkStaged.s.sol", "script/StageMerchant.s.sol"];
        for (uint256 i = 0; i < staged.length; i++) {
            string memory src = vm.readFile(staged[i]);
            assertFalse(
                _contains(src, "block.chainid != 8453"),
                string.concat(staged[i], " is the Base deployment path and must not refuse Base")
            );
        }
    }

    /// The live micro rehearsal exists to exercise Base. It must use the lineage that runs
    /// there — it originally did not, and that is how the ceiling was discovered.
    function test_microRehearsalUsesTheStagedFactory() public view {
        string memory src = vm.readFile("script/DeployMicroRehearsal.s.sol");
        assertTrue(_contains(src, "new StagedTokenFactoryBeta"),
            "the micro rehearsal must deploy the staged beta factory - the atomic one cannot deploy a merchant on Base");
        assertFalse(_contains(src, "new TokenFactoryBeta("),
            "the micro rehearsal must not deploy the atomic beta factory");
    }

    /// Anyone opening TokenFactory.sol must learn it cannot run on Base before they learn
    /// anything else about it.
    function test_theAtomicFactorySaysItCannotRunOnBase() public view {
        string memory src = vm.readFile("contracts/TokenFactory.sol");
        assertTrue(_contains(src, "THIS CANNOT DEPLOY A MERCHANT ON BASE"),
            "TokenFactory must carry an unmissable notice that it is reference-only on Base");
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
