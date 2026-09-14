# PunchCard Protocol — Architecture

Every merchant gets an identical, independently-deployed suite of six contracts. No
merchant shares state with another. The only shared infrastructure is the factory that
deploys them, the router that swaps between them, and the wind-down controller.

```
        ┌─────────────────┐  ┌──────────────────┐
        │  SuiteDeployer  │  │  LockerDeployer  │  hold the creation bytecode
        └────────┬────────┘  └────────┬─────────┘
                 └──────────┬─────────┘
                    ┌───────▼──────────┐
                    │   TokenFactory   │  one call deploys everything below
                    └────────┬─────────┘
                             │
   ┌──────────┬──────────────┼──────────────┬──────────────┐
   ▼          ▼              ▼              ▼              ▼
┌──────┐ ┌──────────┐ ┌─────────────┐ ┌──────────┐ ┌───────────────┐
│Token │ │ Reward   │ │  Vesting    │ │ Treasury │ │   LPLocker    │
│      │ │ Escrow   │ │  Wallet     │ │ Timelock │ │ (USDC + ETH)  │
│ 100M │ │   45%    │ │    15%      │ │   10%    │ │     30%       │
└──────┘ └──────────┘ └─────────────┘ └──────────┘ └───────────────┘
              └──────────────┴──────────────┴──────────────┘
                             │
                    ┌────────▼──────────┐
                    │ WindDownController│  PunchCard multisig only
                    └───────────────────┘
```

## Fixed network constants

Identical for every merchant — set as `constant` in `TokenFactory`, not parameters.

| Constant | Value |
|---|---|
| `TOTAL_SUPPLY` | 100,000,000 (6 decimals) |
| `REWARDS_ALLOC` | 45,000,000 — 45% |
| `LP_ALLOC` | 30,000,000 — 30% |
| `TEAM_ALLOC` | 15,000,000 — 15% |
| `TREASURY_ALLOC` | 10,000,000 — 10% |
| `LAUNCH_LP_ALLOC` | 3,000,000 seeded at launch |
| `MIN_USDC_SEED_USD` | $2,000 floor |
| `MIN_ETH_SEED_USD` | $3,000 floor |
| `LP_RESERVE` | 27,000,000 held for merchant-controlled release |
| `DAILY_CAP` | 500,000 tokens/day |
| `CLIFF_DURATION` | 180 days |
| *fully vested at* | *day 1,260 (cliff + duration)* |
| `VEST_DURATION` | 1,080 days |
| `TIMELOCK_DURATION` | 90 days |
| `WIND_DOWN_DURATION` | 365 days |

## The six contracts

### MerchantToken — the merchant's brand asset

One per merchant. This is the template every merchant token is deployed from; there is no
PunchCard-issued network token and PunchCard holds no allocation of any merchant supply.
Standard ERC-20 + `ERC20Burnable`. 6 decimals. Entire fixed supply minted to the factory
at construction and distributed immediately. **No owner, no mint, no pause, no access
control of any kind.** An `immutable ipfsHash` points at merchant metadata, which is how
the dapp discovers merchants — it reads `MerchantDeployed` events off the factory, so
there is no central registry.

### RewardEscrow — 45%, the reward pool
Holds the reward allocation and meters it out through a daily bucket capped at
`DAILY_CAP`. `distributeReward()` is callable only by `operator` (the merchant's POS
signer). The merchant (`ownerWallet`) can tune `perTxMax` and `lowThreshold` but cannot
withdraw. All addresses immutable after deploy.

### VestingWallet — 15%, the team allocation
Linear vesting: nothing for 180 days, then linear over the following 1,080 — **fully vested
at day 1,260**, about 3.45 years. `vestingEnd = start + cliff + duration`, so the schedule is
continuous with no jump at the end. Worth stating precisely, because "180-day cliff,
1,080-day duration" reads as if it completes at day 1,080. `teamWallet` is **immutable forever —
there is no update function**, so getting it right at deploy time matters more than any
other parameter.

### TreasuryTimelock — 10%, merchant working capital
The merchant submits a release, waits 90 days, then executes. They can cancel their own
pending release. The delay is autonomous — nobody approves it.

### LPLocker — 30%, liquidity
Holds two Uniswap v3 NFT positions, one against USDC and one against ETH. 3M tokens seed the pools at launch; the remaining **27M reserve** stays locked for
merchant-controlled release via `increaseLiquidity()`.

How those 3M split between the two pools is **derived at deploy time, not fixed**. Seed
amounts are minimums — a merchant, an investor or PunchCard may fund deeper pools — so
each pool receives launch tokens in proportion to the USD value seeded into it. That makes
the implied price identical in both pools by construction:

```
price = (usdcSeedUsd + ethSeedUsd) / 3,000,000
```

Seed $2k USDC + $3k ETH and the split is 40/60. Seed $50k + $50k and it is 50/50. Either
way one price, and no arbitrage between a merchant's own two pools. ETH is valued through
a Chainlink ETH/USD feed, which `deploy()` rejects if it is more than an hour stale.

### PunchCardRouter — the network effect
Routes swaps between any two merchant tokens. A cross-merchant swap is two hops through
a shared midpoint — USDC or WETH — and the caller passes `midToken` to choose. Best
execution is quoted off-chain by the interface, the same division of labour Uniswap's own
routers use; `getPoolFeeTiers()` exposes both tiers so an interface can quote each route.

That choice matters economically: the midpoint was hardcoded to USDC, which meant every
merchant's ETH seed was capital that structurally could not earn from network flow. This is what
makes the network more than a collection of isolated loyalty programs. Enforces a maximum
price-impact guard to protect users against thin pools. Swap logic is immutable; only
parameters (fee rate, recipient, impact ceiling) can change, and only through a
propose/execute timelock.

### How PunchCard gets paid

`LPLocker.collectFees()` sweeps accrued Uniswap trading fees from both positions and splits
them by asset: **the entire pair-asset side (USDC/WETH) is PunchCard's network fee.**
Merchant-token fees are never taken — they are **burned**.

Deliberately not all of the fee. Uniswap charges on the *input* token of each swap, so a
buyer pays in USDC and a seller pays in the merchant token. PunchCard takes the first; the
second shrinks supply and lifts everything the merchant holds. Sell pressure converts into
burn, and PunchCard earns when people are buying in — which is when the merchant is winning.

It is permissionless: every destination is fixed and immutable, so there is nothing to gain
by calling it and no operational key needed to keep fees flowing. It is disabled once
frozen — during wind-down `release()` returns accrued fees to the merchant instead.

This is the durable revenue line, and deliberately so. The router's swap fee is
**avoidable**: these are ordinary Uniswap v3 pools, so anyone can trade directly or through
an aggregator and pay PunchCard nothing. LP fees are unavoidable — every trade in the pool
pays them no matter how it is routed.

## Trust model — read this before writing marketing copy

Most of the system is genuinely trustless. Two things are not, and the distinction matters:

**What no one can touch**
- Tokens already in a customer's wallet. The token has no owner, no pause, no clawback,
  no blacklist. Once distributed, they are the holder's permanently.
- The team's vested share, the vesting schedule, and `teamWallet`.
- The allocation percentages and every constant above.
- Swap logic in the router.

**What PunchCard earns**
The pair-asset side of trading fees, plus the router skim when a trade is routed through it.
Both in USDC and ETH. It replaces a subscription rather than sitting on top of one: no
monthly fee, no per-sale cut. PunchCard holds no merchant tokens and no claim on any merchant's treasury,
rewards or team allocation.

**What PunchCard's multisig can do**
`WindDownController.initiate(merchantToken)` is `onlyMultisig` and immediately calls
`freeze()` on the RewardEscrow, TreasuryTimelock, and LPLocker. After 365 days, anyone
may call the settlement functions, which **burn the undistributed escrow and the unclaimed
treasury**. LP stays swappable throughout — only `addLiquidity()` is blocked — and at the
end the LP is released to the merchant.

So PunchCard can end a merchant's *future* rewards. PunchCard cannot take back rewards a
customer already holds.

This is a defensible design — a dead merchant should not leave a zombie escrow emitting
rewards forever. But it means the phrases "no admin keys", "no freeze functions, ever" and
"nobody can change the rules" are **not accurate at the system level**, even though they
are accurate for the token contract itself. Marketing copy should say so precisely:
*earned tokens are permanent and cannot be revoked; the program itself can be wound down
by PunchCard with a 12-month notice period.*
