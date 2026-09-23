// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../contracts/MerchantToken.sol";

/// @title DeploySkoopToken — mint the token, and nothing else
///
/// @notice The first move of the SKOOP launch, deliberately the smallest one. It deploys
///         `MerchantToken` and stops: no suite contracts, no pools, no registration.
///
///         The token is the only piece with no dependencies. Everything else — escrow,
///         vesting, treasury, locker — takes the `WindDownController` address as an
///         immutable, so it cannot be built until the network exists and can never be moved
///         to a different one afterwards. Deploying the token alone commits nothing except
///         the five values below, which is the point: it lets SKOOP exist while each
///         remaining contract is deployed and proven one at a time.
///
///         Registration is last, and is the only step with no undo.
///
/// @dev **Simulating is the default.** Without `--broadcast` this prints exactly what it
///      would deploy and stops. Run it that way first and read the five values back: four
///      of them can never be changed.
///
///          PC_TOKEN_OWNER=0x…  PC_TOKEN_IPFS=Qm…  \
///            forge script script/DeploySkoopToken.s.sol --rpc-url https://mainnet.base.org
///
///      Then add `--broadcast`.
contract DeploySkoopToken is Script {

    /// @dev Constants rather than environment variables. These are the token's identity and
    ///      three of them are immutable forever — a typo in a shell variable is not a thing
    ///      that should be able to name the first token on the network.
    string  constant TOKEN_NAME   = "SKOOP PunchCard";
    string  constant TOKEN_SYMBOL = "SKOOP";
    uint256 constant TOKEN_SUPPLY = 100_000_000 * 1e6;

    function run() external {
        address mintTo   = vm.envAddress("PC_TOKEN_OWNER");
        string memory cid = vm.envString("PC_TOKEN_IPFS");
        bytes32 ipfsHash = keccak256(bytes(cid));

        require(mintTo != address(0),   "PC_TOKEN_OWNER is the zero address");
        require(bytes(cid).length > 0,  "PC_TOKEN_IPFS is empty - pin the metadata first, the hash is immutable");
        require(ipfsHash != bytes32(0), "Invalid IPFS hash");

        // An EOA is expected here — the owner wallet holds the whole supply and funds each
        // contract by hand. Flagged rather than refused, because a multisig is a legitimate
        // choice and this script should not decide that.
        if (mintTo.code.length > 0) {
            console2.log("NOTE: mintTo is a contract, not an EOA. Intentional?");
        }

        console2.log("=====================================================");
        console2.log("  Deploying the SKOOP token, and nothing else");
        console2.log("=====================================================");
        console2.log("");
        console2.log("  PERMANENT - none of these can be changed after deploy:");
        console2.log(string.concat("    name       ", TOKEN_NAME));
        console2.log(string.concat("    symbol     ", TOKEN_SYMBOL));
        console2.log(string.concat("    supply     ", vm.toString(TOKEN_SUPPLY / 1e6), " at 6dp"));
        console2.log(string.concat("    ipfsHash   ", vm.toString(ipfsHash)));
        console2.log(string.concat("      from CID ", cid));
        console2.log("");
        console2.log("  Receives the entire supply:");
        console2.log(string.concat("    mintTo     ", vm.toString(mintTo)));
        console2.log("");

        vm.startBroadcast();
        MerchantToken token = new MerchantToken(
            TOKEN_NAME, TOKEN_SYMBOL, TOKEN_SUPPLY, mintTo, ipfsHash
        );
        vm.stopBroadcast();

        console2.log("-----------------------------------------------------");
        console2.log(string.concat("  SKOOP  ", vm.toString(address(token))));
        console2.log("-----------------------------------------------------");
        console2.log("");
        console2.log("  This token is NOT on the PunchCard network. It has no pools, no");
        console2.log("  escrow, no vesting, no treasury and no locker. It is an ERC-20 with");
        console2.log("  a fixed supply sitting in one wallet, which is exactly the point.");
        console2.log("");
        console2.log("  DO NOT PUBLISH THIS ADDRESS until your own pools are seeded.");
        console2.log("  Anyone can create a Uniswap pool for a token they know the address");
        console2.log("  of, at any price they choose. Check immediately before seeding:");
        console2.log("");
        console2.log(string.concat(
            "    cast call 0x33128a8fC17869897dcE68Ed026d694621f6FDfD \\\n",
            "      'getPool(address,address,uint24)(address)' \\\n",
            "      ", vm.toString(address(token)), " $USDC 3000 --rpc-url $R"
        ));
        console2.log("");
        console2.log("  Zero address means clear. Anything else: stop, use another fee tier.");
        console2.log("");
        console2.log("  Next: docs/skoop-launch-plan.md. Deploy the network, then each suite");
        console2.log("  contract in turn, proving each before it holds anything. Registration");
        console2.log("  is last and is the only step with no undo.");
    }
}
