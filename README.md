# PunchCard Network

A launchpad for merchant loyalty tokens on Base. One factory call deploys a complete,
self-contained suite for a business: its own ERC-20, a metered reward escrow, team vesting,
a timelocked treasury, and locked dual-pool liquidity. A shared router lets customers swap
between any two merchant tokens.

**Site:** [punchcard.club](https://punchcard.club)

**The premise is uniformity.** Every merchant gets byte-identical contracts and identical
terms — the same 45/30/15/10 split, the same 180-day cliff, the same 90-day treasury delay,
the same daily cap. All of it is `constant` in the factory, not a parameter, so terms
cannot be negotiated even if someone wanted to. That is what makes the customer promise
credible, turns onboarding into a checklist, and lets the router treat every merchant token
as interchangeable.

Only six things differ between merchants: name, symbol, three wallet addresses, a metadata
hash, the pool seed sizes, and the per-transaction reward bounds.

---

## Status

| Piece | State |
|---|---|
| Contracts | **Compile and fit EIP-170. Never deployed, never run against live Uniswap.** |
| Tests | 27 passing — pricing maths, fee-split invariants, drawer/emission/pause, against mocks |
| Marketing site | Live at punchcard.club, GitHub Pages from the repo root |
| Customer dapp (`dapp/`) | **Prototype** — hardcoded mock balances, no web3 |
| `website/` | **Stale duplicate** of the root site, candidate for deletion |

Honest read: **ready for a testnet deployment, not a mainnet one.** Nothing here has ever
executed against real Uniswap contracts. The mocks prove the arithmetic, not the
integration.

**On KOKOS.** KOKOS Ice Cream in Nashville runs a live loyalty token (SKOOP) taking real
payments, and it is the model this protocol generalises. It is *not* a deployment of this
factory — it runs on its own earlier contracts. **No merchant has been deployed through
`TokenFactory` yet.**

---

## Layout

```
├── index.html  CNAME  og-image.*      ← the live site. Pages serves the repo ROOT,
│                                        so these must never move
├── contracts/
│   ├── PunchCardToken.sol             the merchant's ERC-20
│   ├── RewardEscrow.sol               45% — 5yr emission + per-kiosk drawers
│   ├── VestingWallet.sol              15% — team, 180d cliff / 1080d linear
│   ├── TreasuryTimelock.sol           10% — merchant capital, 90d delay
│   ├── LPLocker.sol                   30% — dual Uniswap positions + fee collection
│   ├── TokenFactory.sol               orchestrates a merchant deployment
│   ├── WindDownController.sol         the one privileged contract
│   ├── PunchCardRouter.sol            merchant-to-merchant swaps
│   ├── deployers/                     construction helpers (EIP-170 workaround)
│   ├── libraries/LaunchPricing.sol    launch split + sqrtPriceX96 maths
│   └── interfaces/
├── docs/architecture.md               per-contract behaviour + trust model
├── docs/deployment-runbook.md         network setup, then the repeatable merchant path
├── docs/audit-2026-09.md              first full-suite compilation audit
├── docs/building.md                   build settings — via_ir is mandatory
├── deploy/network/base-mainnet.json   addresses + constants
├── deploy/merchants/_template.json    copy per merchant
└── test/                              foundry tests
```

---

## What actually happens when a merchant is deployed

`TokenFactory.deploy()` is `onlyDeployer` — PunchCard's hot wallet, after off-chain review.
The merchant never calls it. In one transaction:

1. Pull `usdcPairAmount` from `ownerWallet`; wrap `msg.value` to WETH
2. Read Chainlink ETH/USD; value both seeds; **enforce the $2,000 / $3,000 minimums**
3. Derive the launch token split from the seeded USD value *(see Economics below)*
4. Deploy token, vesting, treasury, escrow via `SuiteDeployer`; LP locker via `LockerDeployer`
5. Distribute 15M / 10M / 45M to vesting, treasury, escrow — factory retains exactly 30M
6. Create and initialise both Uniswap pools at the derived price, mint both positions into
   the locker, return any dust to `ownerWallet`
7. Move the 27M LP reserve into the locker
8. Register the suite with `WindDownController`; emit `MerchantDeployed`

Merchant status on the network is exactly this: a `MerchantDeployed` event plus
`WindDownController` registration. Nothing else confers it.

---

## Economics

### Allocation — identical for every merchant

| Slice | Amount | Where it goes |
|---|---|---|
| Rewards | 45,000,000 | `RewardEscrow`, emitted over 5 years, spent through per-kiosk drawers |
| Liquidity | 30,000,000 | `LPLocker` — 3M seeds the pools, 27M reserve |
| Team | 15,000,000 | `VestingWallet`, 180d cliff then linear to 1080d |
| Treasury | 10,000,000 | `TreasuryTimelock`, 90d delay per release |

100,000,000 fixed supply, 6 decimals, no mint function.

### Seeding is a floor, not a fixed size

Minimums are **$2,000 USDC and $3,000 ETH**, enforced on-chain. There is no upper bound —
a merchant, an outside investor, or PunchCard may fund deeper pools, and deeper is better.

Because the amounts vary, the **token side of each pool is derived, not fixed**. Each pool
receives launch tokens in proportion to the USD value seeded into it, which makes the
implied price identical in both by construction:

```
price per token = (usdcSeedUsd + ethSeedUsd) / 3,000,000
```

$2k + $3k → 40/60 split. $50k + $50k → 50/50. Any seed → one price.

> This replaced a fixed 1.8M/1.2M split, which only priced both pools equally at a seed
> ratio of exactly 1.5:1. At $2k + $3k it opened them **2.25× apart** and handed the first
> trader a large slice of the seed.

### How PunchCard earns

| Source | Mechanism | Reliability |
|---|---|---|
| **LP trading fees** | `LPLocker.collectFees()` — 20% PunchCard / 80% seeder | **Unavoidable.** Every trade in the pool pays, however routed |
| Router swap fee | 30 bps on swaps through `PunchCardRouter` | **Avoidable** — these are ordinary Uniswap pools; anyone can trade direct |

Merchant-token fees are **burned**, never kept, so PunchCard never holds a position in a
merchant's token. PunchCard receives no allocation of any merchant's supply.

---

## Trust model

**What nobody can touch**
- Tokens already in a customer's wallet. No owner, no pause, no clawback, no blacklist
- The team's vesting schedule and `teamWallet`
- Allocation percentages, cliff, vest duration, treasury delay, daily cap
- Router swap logic

**What PunchCard's multisig can do**
`WindDownController.initiate()` is `onlyMultisig`. It immediately freezes the reward
escrow, the treasury and LP additions. After 365 days anyone may settle, which **burns the
undistributed escrow and the unclaimed treasury** and returns 90% of LP to the merchant.

So PunchCard can end a merchant's *future* rewards. PunchCard cannot claw back rewards a
customer already holds. Any marketing copy must keep that distinction intact — "no admin
keys, no freeze functions" is false at the system level, though true of the token contract.

---

# Open logic considerations

Design decisions worth making deliberately before mainnet, roughly in order of how much
they would hurt. Items 1–3 were closed by the drawer/emission rework; the rest stand.

### ~~1. The POS operator key cannot be rotated~~ — ✅ FIXED

`RewardEscrow.operator` is `immutable`. There is no `setOperator`. If a merchant's POS
signing key is leaked, an attacker can call `distributeReward` to their own address up to
the daily cap — **500,000 tokens a day, indefinitely** — and the merchant has no way to
stop it. The only remedy is PunchCard initiating a wind-down, which freezes rewards but
also ends the program and burns the remaining escrow.

**Fixed by the drawer model.** Each kiosk is its own operator with its own till,
replenishing continuously up to a daily allowance (default two days of emission, ~49,300
tokens, roughly $82 at launch price). A leaked key costs at most one drawer per day until
the merchant removes that operator with their cold wallet. `MAX_DRAWER_DAYS` caps any till
at 14 days of emission, so even a compromised owner key cannot open an unlimited drawer,
and raising an allowance does not refill a till already drawn down.

### ~~2. The reward pool lasts 90 days at full draw~~ — ✅ FIXED

45,000,000 rewards ÷ 500,000 daily cap = **90 days**. A busy merchant hitting the cap
exhausts their entire reward allocation in three months, and the escrow cannot be refilled
from anywhere — `refill()` only moves tokens within the escrow's own balance.

**Fixed by the emission schedule.** The allocation now unlocks continuously over five
years — 24,657/day — and only unlocked tokens are spendable, with at most 30 days of
emission reachable at once so a quiet month banks capacity for a busy one. Unspent emission
is not forfeited: it stays claimable and extends the programme past five years, which is
also how price appreciation is absorbed without an oracle.

### ~~3. `perTxFloor` is immutable~~ — ✅ FIXED

**Fixed.** `setPerTxBounds()` lets the owner move both floor and ceiling, bounded by the
drawer ceiling. Both are token-denominated and what a token is worth moves.

### 4. Nothing triggers `collectFees()`

Permissionless is right, but somebody still has to call it or PunchCard earns nothing.
Needs a keeper. (`refill()` is gone — continuous emission needs no trigger, which also
removed a griefing vector where anyone could pin a merchant's daily refill to an hour of
their choosing by topping up a nearly-full bucket the instant the cooldown lapsed.)

### 5. Merchants cannot wind down their own program

Only PunchCard's multisig can initiate. A merchant closing their business has no way to
start an orderly wind-down and recover their LP. Consider letting `ownerWallet` initiate
too — it does not weaken any customer guarantee, since the 365-day timer and the
"earned tokens are untouchable" property are unchanged.

### 6. The 10% permanent LP goes nowhere

At wind-down, 90% of liquidity returns to the merchant and the remaining 10% is left in the
position forever — not to PunchCard, not burned, just abandoned. That is probably not a
deliberate choice. Decide where it should go.

### 7. LP dust leaks to the merchant

After each mint, leftover amounts go to `ownerWallet`. When the leftover is merchant tokens,
that is allocation escaping the locked LP into the merchant's hands. Small, but it is a hole
in "30% is locked." Sending token dust to the locker's reserve instead would close it.

### 8. `teamWallet` has no recovery path

Immutable forever, controlling 15% of supply vesting over three years. A lost or compromised
key means that allocation vests to a dead address permanently. This is a deliberate
guarantee and I would probably keep it — but it should be a decision, and the runbook should
insist on a hardware wallet.

### 9. Deploys now depend on a live oracle

Valuing the ETH seed requires Chainlink, and `deploy()` reverts on an answer older than an
hour. If the feed stalls, no merchant can launch until it recovers. Acceptable — deployment
is not time-critical — but it is a new external dependency that did not exist before.

### 10. No deployment fee

Onboarding costs PunchCard real gas plus real labour, and currently recovers neither at the
point of sale. A flat USDC fee in `deploy()` would cover it without touching the LP fee
share.

---

## Building

```bash
forge install OpenZeppelin/openzeppelin-contracts@v4.9.6 --no-git
forge build --sizes
forge test
```

`via_ir = true` with the optimizer is **required**, not a preference — `TokenFactory.deploy()`
fails with "stack too deep" otherwise. The same settings must be used for Basescan
verification or the bytecode will not match. See [`docs/building.md`](docs/building.md).

Two constraints that are load-bearing and easy to undo by accident:

- **Never `import` a concrete suite contract into `TokenFactory`.** Using `new X(...)` or
  even importing the type pulls X's creation bytecode into the factory. That is what put it
  10KB over the EIP-170 limit. The factory talks to everything through interfaces.
- **Never add a page under `/Customer_dapp/`** in the KOKOS repo — unrelated to this repo,
  but the same class of invisible trap.

## Adding a merchant

1. `cp deploy/merchants/_template.json deploy/merchants/<business>.json`
2. Fill in three wallets, IPFS metadata hash, pool seeds, reward bounds
3. Work the pre-flight checklist in [`docs/deployment-runbook.md`](docs/deployment-runbook.md)
4. `ownerWallet` approves USDC → deployer calls `TokenFactory.deploy()`
5. Record the deployed addresses back into the JSON and commit

> **Source of truth is this repo.** The contracts previously lived only in an iCloud Remix
> workspace with no version history. If you edit them in Remix, commit the result here.
