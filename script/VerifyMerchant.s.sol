// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../contracts/StagedTokenFactory.sol";

interface IVerifyToken {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function ipfsHash() external view returns (bytes32);
}

interface IVerifyEscrow {
    function perTxFloor() external view returns (uint256);
    function perTxMax() external view returns (uint256);
}

interface ILineage {
    function HAS_UNLIMITED_LP_RECOVERY() external view returns (bool);
}

/// @title VerifyMerchant — print the exact Basescan verification commands for a merchant
///
/// @notice The five contracts a factory creates are the awkward ones. Nobody typed their
///         constructor arguments, so nobody can retype them: they were assembled inside
///         `stageSuite` from the factory's constants and immutables and never written down
///         anywhere an operator can see.
///
///         Reconstructing them from memory months later, for a token customers hold, is how
///         a verification ends up subtly wrong — a `perTxMax` off by a zero, a wallet
///         confused for another, and a contract that will not verify with no clue why.
///
///         So this reads them back off the chain and prints ready-to-paste commands.
///
/// @dev Read-only. No broadcast, no keys, nothing deployed. Needs only an RPC.
///
///          PC_FACTORY=0x… PC_TOKEN=0x… \
///          forge script script/VerifyMerchant.s.sol --rpc-url https://mainnet.base.org
///
///      Then paste the commands it prints. `--constructor-args` is pre-encoded, so there is
///      nothing left to get wrong.
///
///      The compiler settings come from foundry.toml and MUST match what was deployed —
///      `via_ir = true` with `optimizer_runs = 200`. Verifying from a working tree whose
///      settings have changed produces bytecode that will not match, and the error will not
///      say so.
contract VerifyMerchant is Script {

    struct Suite {
        address factory;
        address token;
        address ownerWallet;
        address teamWallet;
        address operator;
        address escrow;
        address vesting;
        address treasury;
        address locker;
    }

    function run() external view {
        Suite memory s = _load();
        StagedTokenFactory f = StagedTokenFactory(payable(s.factory));

        console2.log(string.concat("# Source verification for merchant ", vm.toString(s.token)));
        console2.log("# Read from chain, not retyped. Paste as-is.");
        console2.log("#");
        console2.log("# Two commands per contract, because Sourcify and Basescan are separate");
        console2.log("# registries and verifying on one does NOT verify on the other.");
        console2.log("#   sourcify  - no API key, decentralised, read by Blockscout and tooling");
        console2.log("#   basescan  - needs a free BASESCAN_API_KEY, and is where people actually look");
        console2.log("# Do both. Same arguments, so it costs one extra paste.");
        console2.log("");

        _cmd("contracts/MerchantToken.sol:MerchantToken", s.token, abi.encode(
            IVerifyToken(s.token).name(),
            IVerifyToken(s.token).symbol(),
            f.TOTAL_SUPPLY(),
            s.factory,
            IVerifyToken(s.token).ipfsHash()
        ));

        _cmd("contracts/RewardEscrow.sol:RewardEscrow", s.escrow, abi.encode(
            s.token, s.operator, s.ownerWallet, f.windDownController(),
            f.REWARDS_ALLOC(),
            IVerifyEscrow(s.escrow).perTxFloor(),
            IVerifyEscrow(s.escrow).perTxMax(),
            s.factory
        ));

        _cmd("contracts/VestingWallet.sol:VestingWallet", s.vesting, abi.encode(
            s.token, s.teamWallet, f.windDownController(),
            f.CLIFF_DURATION(), f.VEST_DURATION(), s.factory
        ));

        _cmd("contracts/TreasuryTimelock.sol:TreasuryTimelock", s.treasury, abi.encode(
            s.token, s.ownerWallet, f.windDownController(), f.TIMELOCK_DURATION(), s.factory
        ));

        _cmd(_lockerPath(s.locker), s.locker, abi.encode(
            s.token, s.ownerWallet, f.windDownController(), f.positionManager(),
            s.factory, f.USDC(), f.WETH(), f.punchcardFeeRecipient()
        ));

        console2.log("# The network contracts are verified from the deploy script's own");
        console2.log("# arguments - see docs/deployment-runbook.md. Only these five are");
        console2.log("# created by the factory and therefore have no record anywhere else.");
    }

    function _load() internal view returns (Suite memory s) {
        s.factory = vm.envAddress("PC_FACTORY");
        s.token   = vm.envAddress("PC_TOKEN");
        StagedTokenFactory.Stage stage;
        (stage, s.ownerWallet, s.teamWallet, s.operator,
         s.escrow, s.vesting, s.treasury, s.locker,
         , , , , , , ) = StagedTokenFactory(payable(s.factory)).suites(s.token);
        require(
            stage != StagedTokenFactory.Stage.None,
            "Not a suite from this factory - check PC_FACTORY and PC_TOKEN"
        );
    }

    /// @dev Which locker lineage this factory produced. The hatch semantics differ and so
    ///      does the contract path; guessing it is the kind of small error that wastes an
    ///      afternoon on a verification that fails without saying why.
    function _lockerPath(address locker) internal view returns (string memory) {
        (bool unlimited, ) = locker.staticcall(abi.encodeWithSignature("HAS_UNLIMITED_LP_RECOVERY()"));
        if (unlimited) return "contracts/pilot/LPLockerPilot.sol:LPLockerPilot";
        (bool hatch, ) = locker.staticcall(abi.encodeWithSignature("evacuationOpen()"));
        if (hatch) return "contracts/beta/LPLockerBeta.sol:LPLockerBeta";
        return "contracts/LPLocker.sol:LPLocker";
    }

    /// @dev Emits both, with `--verifier` explicit in each. Forge's default verifier is
    ///      sourcify, so a command that omits the flag silently goes there — which is fine
    ///      until a runbook tells you to set a Basescan key for commands that never touch
    ///      Basescan. Saying which registry each line targets removes that trap.
    function _cmd(string memory path, address addr, bytes memory args) internal view {
        console2.log(string.concat(
            "forge verify-contract ", vm.toString(addr), " ", path, " \\\n",
            "  --chain base --watch --verifier sourcify \\\n",
            "  --constructor-args ", vm.toString(args)
        ));
        console2.log(string.concat(
            "forge verify-contract ", vm.toString(addr), " ", path, " \\\n",
            "  --chain base --watch --verifier etherscan --etherscan-api-key $BASESCAN_API_KEY \\\n",
            "  --constructor-args ", vm.toString(args)
        ));
        console2.log("");
    }
}
