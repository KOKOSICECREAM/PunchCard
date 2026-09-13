// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title MerchantToken
/// @notice A single merchant's loyalty token. One of these is deployed per merchant.
/// @dev This is the template, not a network token — there is no PunchCard-issued token and
///      PunchCard holds no allocation of any merchant's supply. Each deployment carries the
///      merchant's own name, symbol and metadata hash.
/// @dev Fixed supply — entire supply minted to factory at deployment.
///      No mint function. Supply can only decrease via ERC20Burnable.burn().
///      6 decimals network standard.
///      All allocation distribution handled by factory after deployment.
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
    /// @param totalSupply_ Fixed supply — 100_000_000 * 1e6, set by factory
    /// @param factory_     Receives entire supply for distribution to suite contracts
    /// @param ipfsHash_    IPFS hash of merchant metadata (name, symbol, logo)
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 totalSupply_,
        address factory_,
        bytes32 ipfsHash_
    ) ERC20(name_, symbol_) {
        require(factory_     != address(0), "Invalid factory");
        require(totalSupply_  > 0,          "Invalid supply");
        require(ipfsHash_    != bytes32(0), "Invalid IPFS hash");

        ipfsHash = ipfsHash_;

        // Mint entire fixed supply to factory
        // Factory distributes to suite contracts in deploy sequence
        _mint(factory_, totalSupply_);
    }

    // ── OVERRIDES ─────────────────────────────────────────────────────────────

    /// @notice Returns 6 decimals — PunchCard network standard
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
