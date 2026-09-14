# First end-to-end deployment — 2026-09-13

Run against a **local fork of Base Sepolia** (chainId 84532, block 46,788,801) with real
broadcast: `forge script --broadcast`, real nonces, real gas estimation, real receipts,
and the live Uniswap v3 contracts from that chain's state.

Public Sepolia was the intent, but its faucets gate on wallet transaction history and a
fresh deployer address cannot satisfy that. A local fork exercises everything except
public block conditions and a Basescan artifact — and needs no faucet.

```bash
anvil --fork-url https://sepolia.base.org --silent &
forge script script/DeployNetwork.s.sol:DeployNetwork  --rpc-url http://127.0.0.1:8545 --broadcast --private-key <anvil key>
forge script script/DeployMerchant.s.sol:DeployMerchant --rpc-url http://127.0.0.1:8545 --broadcast --private-key <anvil key>
```

## What ran

**Network** — five contracts, circular dependency resolved by predicting the factory
address; the script asserted it landed where predicted.

**Merchant** — "Testnet Scoops" / TSCOOP, seeded $10 USDC + 0.005 ETH.

| Check | Result |
|---|---|
| Total supply | 100,000,000 exactly |
| Reward escrow | 45,000,000 |
| Vesting wallet | 15,000,000 |
| Treasury timelock | 10,000,000 |
| LP locker reserve | 27,000,000 |
| Factory residue | **0** tokens, 0 USDC |
| Uniswap positions held by locker | **2** |
| Registered with WindDownController | true |

**Rewards** — after two days of emission, `spendable` 49,336 and drawer 49,315 (two days
of allowance, as designed). Issued 5,000 TSCOOP to a customer; drawer fell to exactly
44,315.

**Swap** — 1,000 TSCOOP → USDC through `PunchCardRouter`, against the pool this deployment
created. Customer received 0.007405 USDC; PunchCard collected 0.000022 — **30 bps**, as
configured.

## Still worth doing on public Sepolia

Basescan verification and behaviour under real block conditions and competing traffic.
Neither changes what the contracts do; both are worth having before mainnet.
