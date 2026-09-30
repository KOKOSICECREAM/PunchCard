// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title MerchantToken
/// @notice Fixed-supply ERC-20 blueprint for one merchant's PunchCard rewards program.
/// @dev Each deployment is a merchant-specific token with its own name, symbol and
///      metadata hash. PunchCard does not issue one shared network token and holds no
///      built-in allocation of any merchant's supply.
/// @dev Fixed supply — entire supply minted once to the constructor recipient.
///      In the factory path, that recipient is the factory. In the manual path, it may be
///      the merchant owner wallet, which funds the suite by hand before registration.
///      No mint function. Supply can only decrease via ERC20Burnable.burn().
///      6 decimals network standard.
///      Allocation distribution happens after deployment, either by the factory or by the
///      owner on a manually admitted token such as SKOOP.
///      Fully permissionless after deployment — no owner, no pause, no access control.
///      ERC20Burnable enables burn() calls from suite contracts holding tokens
///      (RewardEscrow, TreasuryTimelock, VestingWallet, LPLocker) — no allowance needed.
contract MerchantToken is ERC20, ERC20Burnable {

    // ── IMMUTABLES ────────────────────────────────────────────────────────────

    /// @notice IPFS hash of merchant metadata — name, symbol, logo
    /// @dev Stored on-chain for permanent discoverability.
    ///      Dapp discovers all tokens via MerchantDeployed events from factory,
    ///      then reads ipfsHash from each token. No centralized registry needed.
    bytes32 public immutable ipfsHash;

    // ── CONSTRUCTOR ───────────────────────────────────────────────────────────

    /// @param name_        Token name — e.g. "Frothy Monkey Rewards"
    /// @param symbol_      Token symbol — e.g. "FROTHY"
    /// @param totalSupply_ Fixed supply — normally 100_000_000 * 1e6
    /// @param mintTo_      Receives the entire supply at deployment
    /// @param ipfsHash_    IPFS hash of merchant metadata (name, symbol, logo)
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 totalSupply_,
        address mintTo_,
        bytes32 ipfsHash_
    ) ERC20(name_, symbol_) {
        require(mintTo_      != address(0), "Invalid recipient");
        require(totalSupply_  > 0,          "Invalid supply");
        require(ipfsHash_    != bytes32(0), "Invalid IPFS hash");

        ipfsHash = ipfsHash_;

        _mint(mintTo_, totalSupply_);
    }

    // ── OVERRIDES ─────────────────────────────────────────────────────────────

    /// @notice Returns 6 decimals — PunchCard network standard
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
