# PunchCard Network

A launchpad for merchant loyalty tokens on Base. One factory call deploys a complete,
self-contained suite for a business: its own ERC-20, a metered reward escrow, team vesting,
a timelocked treasury, and locked dual-pool liquidity. Every merchant follows the identical
path, and a shared router lets customers swap between any two merchant tokens.

**Site:** [punchcard.club](https://punchcard.club)

---

## Status

Be precise about this — the marketing site and the chain are not in the same place yet.

| Piece | State |
|---|---|
| Contracts (`contracts/`) | **Written, not deployed.** No PunchCard network contracts are live on Base |
| Marketing site (`index.html`) | **Live** at punchcard.club, served by GitHub Pages from the repo root |
| Customer dapp (`dapp/`) | **Prototype only** — hardcoded mock balances, no web3, not wired to anything |
| `website/` | **Stale duplicate** of the root site from an earlier revision — candidate for deletion |

**On KOKOS.** KOKOS Ice Cream in Nashville runs a live loyalty token (SKOOP) taking real
payments, and it is the model this protocol generalises. It is *not* a deployment of this
factory — it runs on its own earlier contracts. No merchant has been deployed through
`TokenFactory` yet. Worth stating carefully anywhere it is described as "the first
PunchCard deployment."

---

## Layout

```
├── index.html            ← the live site. GitHub Pages serves the repo ROOT,
├── CNAME                   so these must not move or punchcard.club breaks
├── og-image.*  punchbari.jpg
│
├── contracts/            ← the protocol (8 contracts + 5 interfaces)
│   └── interfaces/
│
├── docs/
│   ├── architecture.md   ← what each contract does, allocations, trust model
│   └── deployment-runbook.md  ← network setup + the repeatable merchant path
│
├── deploy/
│   ├── network/base-mainnet.json   ← canonical addresses + fixed constants
│   └── merchants/_template.json    ← copy per merchant, commit when deployed
│
├── dapp/                 ← prototype UI (mock data)
└── website/              ← stale duplicate
```

---

## Adding a merchant

The whole point of the project is that this never varies:

1. `cp deploy/merchants/_template.json deploy/merchants/<business>.json`
2. Fill in three wallets, IPFS metadata hash, pool seed amounts, reward bounds
3. Work down the pre-flight checklist in [`docs/deployment-runbook.md`](docs/deployment-runbook.md)
4. `ownerWallet` approves USDC → deployer calls `TokenFactory.deploy()`
5. Record the deployed addresses back into the JSON and commit

Allocations are not configurable. Every merchant gets the same split, enforced as
constants in the factory:

**45% rewards · 30% liquidity · 15% team · 10% treasury** — 100M fixed supply, 6 decimals.

---

## Working on the contracts

They were authored in Remix. `.gitignore` excludes `artifacts/` and `.deps/` so a Remix
workspace can point at this directory without committing build output.

- Solidity **0.8.24+**, OpenZeppelin v4.x or v5.x
- Every merchant-facing address is `immutable` after deploy — there are no setters for
  `teamWallet`, `ownerWallet`, or `operator`
- Read [`docs/architecture.md`](docs/architecture.md) before changing allocation or
  wind-down behaviour; the trust model section explains which guarantees the marketing
  copy depends on

> **Source of truth is this repo.** The contracts previously lived only in an iCloud Remix
> workspace with no version history. If you edit them in Remix, commit the result here.
