# SKOOP launch plan

The first official token on the PunchCard network. Written 2026-09-16, from the decisions
recorded in `docs/staged-rollout.md` and `docs/deployment-runbook.md`; where this disagrees
with either, they are the source of truth and this is stale.

## What is being launched

```
name          SKOOP PunchCard
symbol        SKOOP
supply        100,000,000 at 6dp
lineage       hand-assembled suite with LPLockerPilot
admission     manual registrar path, not the factory
LP            recoverable by the owner wallet, indefinitely
team vesting  30-day cliff, nothing at the cliff, then 730 days -> day 760
treasury      10M behind a 7-day delay  (merchants get 90 — see below)
rewards       45M emitting over 1825 days, ~24,657/day
```

## The naming decision, and the one thing it forces

Decided 2026-09-16: **name `SKOOP PunchCard`, symbol `SKOOP`.** Not `pSKOOP`, not
`KOKOS SKOOPS`.

`PunchCard` in the name because it is a word a customer already understands — a card you
punch at a shop — so the name explains itself in a wallet to someone who has never heard of
any of this. `PunchCard Network` and `SKOOP PCN` were both considered and both describe the
plumbing rather than the thing: "Network" turns it into infrastructure, and an acronym
carries no information until the full name is known.

The intended family, for later merchants:

```
SKOOP PunchCard
FROTH PunchCard
SLICE PunchCard
```

**A convention, not a rule.** It is deliberately not enforced on-chain. The registry could
require the suffix and make network membership and the naming convention one verifiable
fact, but that is a check which cannot be retrofitted — every token registered before it
would fail it afterwards — and the model is still settling. Leaving room to change the
convention is worth more right now than making it structural. Revisit once several merchants
exist and the shape has stopped moving.

An earlier decision chose `pSKOOP` precisely to avoid a symbol collision, and that reasoning
was correct *for a pilot running alongside a live token*. This is not that. This is the
official launch, and the 2023 token is being retired — so the new one takes the name and the
old one stops being the SKOOP anyone means.

**But the old contract does not disappear.** `0xfd3ce21c…` exists on Base forever, holds
13 public wallets' balances, and its two pools work until someone pulls them. For any window
where both are tradeable there are two things called SKOOP, and a customer following a link
or searching a DEX can buy the wrong one.

That is the cost of the name, and it is paid entirely in **sequencing**:

- The overlap window cannot be zero. New pools must exist before registration, and pulling
  the old LP is a separate transaction from a separate wallet.
- It can be **short and announced**, which is the whole mitigation. Hours, in one session,
  not days.
- Nothing about the launch should be promoted until the old pools are drained. A promoted
  link during the overlap is how somebody buys the wrong SKOOP.

> **Hard rule: do not promote, tweet, or publish the new token address until the old SKOOP
> pools are drained.** Assemble quietly, cut over in one session, announce afterwards.

## Where SKOOP differs from the merchant standard

Deliberate, and short. Every difference is a **deploy parameter**, not a loosened rule — the
factory and the constants it enforces are untouched, and a merchant launching tomorrow gets
exactly what the README describes.

| | merchant standard | SKOOP | why |
|---|---|---|---|
| LP recovery | none, or 30 days self-closing | **indefinite, owner-only** | unaudited code must stay movable |
| Treasury delay | 90 days | **7 days** | see below |
| Admission | factory, automatic | **registrar, reviewed** | hand-assembled |
| Allocations at admission | exact, enforced | **targets, reported** | funded by hand, must not strand |
| Allocation split | 45/30/15/10 | **same** | |
| Team vesting | 30-day cliff, 730 days | **same** | |
| Emission | 45M over 1825 days | **same** | |
| Supply | 100M, no mint | **same** | |

### Why the treasury delay differs

Not convenience. **SKOOP's LP is evacuable instantly, with no deadline, forever.** That is a
larger and faster lever than the treasury, held by the same wallet, and disclosed on the
page. A 90-day gate on 10% of supply while that hatch stands open is theatre.

For a merchant the reasoning inverts. Their hatch self-closes at 30 days or never existed,
so the treasury delay is their holders' only protection against a sudden 10% move. Same
constant, opposite justification — which is why it tracks the lineage rather than being one
number for everyone.

Seven rather than zero: the constructor rejects zero, and a week keeps `ReleaseSubmitted` as
a visible on-chain signal before 10% of supply moves, at no operational cost. It also makes
the one-pending-release-at-a-time limit irrelevant, which at 90 days is a real constraint —
four releases a year, no queue.

### Marketing comes from the treasury

Settled 2026-09-16. The treasury's 10% is the **discretionary budget** — it is the only
allocation not already committed, since rewards belong to customers, liquidity to the pools
and vesting to the team. A campaign, a partnership, a giveaway that is not a customer
reward, or converting to cash all come from there.

An earlier draft of this plan said marketing comes from the reward escrow. That was wrong,
and wrong in a way worth recording: `distributeReward` does take any address, so it is
mechanically possible — and it spends the customers' budget to do it. The two are different
commitments.

The question surfaced a gap nobody had written down. SKOOP v1 had **five** allocations
including a dedicated 10% `PunchcardMarketingVault`. PunchCard has four and no marketing
line, having moved that 10% and half the old treasury into rewards and liquidity:

| SKOOP v1 | | PunchCard | |
|---|---|---|---|
| Rewards | 35% | Rewards | **45%** |
| Liquidity | 20% | Liquidity | **30%** |
| Treasury Reserve | 20% | Treasury | **10%** |
| Team | 15% | Team | 15% |
| Marketing / Community | 10% | — | — |

Deeper pools and a bigger reward budget are both real improvements. The consequence is that
discretionary tokens all come from one place now, which is worth knowing before the constants
are committed rather than after.

SKOOP's 7-day delay makes that workable — one release a week rather than four a year. For
merchants at 90 days with one pending release at a time, treasury spend is a quarterly
decision, and that is a genuine constraint on a merchant's marketing rather than an
oversight.

### This must be stated, not inherited

The marketing site describes what a *factory* merchant gets, including the 90-day delay.
SKOOP does not get that, and nothing on SKOOP's own page may imply it does. The vocabulary
rules in `docs/staged-rollout.md` apply: **PunchCard-registered**, **bytecode-reviewed**,
**network-admitted** — never *factory-standard*.

## Before the day

- [ ] **Wallets**, all fresh, none reused from the rehearsals:
      multisig · deployer · registrar · fee recipient · owner *(hardware)* · team
      *(hardware)* · operator
      The **owner wallet** is the highest-stakes key in the system: it alone can evacuate the
      LP, for as long as SKOOP exists. Treat it accordingly.
- [ ] **Capital**: $2,000 USDC + $1,000 of ETH in the owner wallet, plus gas. Re-check the
      ETH figure on the day — the floor is USD-denominated against Chainlink and the wei
      that clears $1,000 moves with the price.
- [ ] **A Sourcify (and ideally Basescan) verification path**, tested. Step 5 below is
      load-bearing, not cosmetic.
- [ ] **Announcement drafted**, so the cutover is not waiting on writing.
- [ ] **Old SKOOP snapshot taken at a block already in the past.** Announcing a future block
      lets anyone buy cheaply to farm the distribution.

## The sequence

Everything up to step 8 is reversible. Step 9 is not.

```
 1  deploy the network            DeployNetworkStaged.s.sol
                                  controller + router + the factory FUTURE merchants use.
                                  SKOOP joins it, it does not come through it.
 2  hand-assemble the suite       token, escrow, vesting, treasury, LPLockerPilot
 3  fund each contract, in turn   45M escrow · 15M vesting · 10M treasury.
                                  Exercise each one with a small amount first.
 4  seed both pools               $2,000 USDC + $1,000 ETH, at one price.
                                  Mint both positions TO THE LOCKER, send the 27M reserve,
                                  and only THEN call initializeLP. Order matters — see below.
 5  publish the source            all five contracts. Do this BEFORE step 6.
 6  multisig approves 5 codehashes  setApprovedCode(role, codehash, true)
 7  VerifyManualSuite             PC_MODE=pilot. Read-only. Fix what it reports, run again.
 8  -- announce --                the cutover is starting
 9  pull the old SKOOP LP         old token stops being tradeable
10  registrar admits SKOOP        registerManual(...)   <-- no undo after this
11  confirm the router serves it  getPoolFeeTiers stops reverting
12  fill the launchpad config     controller · router · token · escrow · pools
13  confirm the page copy         "SKOOP liquidity is not permanently locked."
14  distribute to old holders     13 wallets, ~$338, from the treasury allocation
15  point the POS at the escrow   when ready, not before
```

**Steps 5 and 6 are in that order deliberately.** Codehash approval is per deployment —
Solidity writes immutables into runtime bytecode, so the multisig cannot approve
implementations in advance. Approving the hash of a contract nobody has verified is a rubber
stamp; approving one whose published source matches is an attestation.

### Two things the factory was doing silently

Hand-assembly exposes both. Neither is a bug in the contracts; both are guarantees the
factory produced by construction and nobody has to produce by hand until now.

**The locker never checks it owns the positions.** `initializeLP` reads both from Uniswap
and records their liquidity, but does not verify ownership — in the factory path it cannot
fail to, because the factory transfers the NFTs and initialises in one transaction it
controls. By hand, paste the wrong token IDs or forget to move the NFTs and the locker
reports `isInitialized: true` while the liquidity sits in a wallet. "The LP is in the
locker" is the claim the whole product rests on. `VerifyManualSuite` now checks
`ownerOf(tokenId) == locker` for both.

**The reserve must be sent BEFORE initializeLP.** It snapshots `_reserveTokens` from the
locker's balance at that instant. Initialise first and it records zero permanently — the
27M arrives afterwards and is never counted, so `addLiquidity` cannot deploy what the locker
does not believe it has. The verifier flags a zero reserve against a non-zero balance.

So step 4's order is: **mint positions to the locker → send the reserve → initializeLP**.

**Step 7 is the only step with no transaction in it**, and the reason the manual path is
defensible rather than merely flexible.

**Step 10 is the point of no return.** `register()` sets a flag nothing clears; the only
exit is a 365-day wind-down. Before it, every problem is fixable by redeploying a contract
and re-running step 7.

## If something goes wrong

| where | what it costs | what to do |
|---|---|---|
| steps 1–4 | gas | redeploy the offending contract, carry on |
| step 5 | nothing | verify again; settings must match the deployment |
| step 6 | nothing | approve the corrected hash |
| step 7 | nothing | it is telling you something is wrong. Fix it, do not override it |
| step 9 | old SKOOP untradeable | expected; this is the cutover |
| after step 10 | **SKOOP is on the network for a year minimum** | LP is still recoverable via `evacuateLP()`; allocations can still be topped up |

The LP hatch is the backstop for everything after step 10: `evacuateLP()` from the owner
wallet returns the seed and the reserve, at any time, with no deadline. It does not undo
registration.

## What must not be said

- **Not "factory-standard" or "factory-deployed".** SKOOP is hand-assembled and admitted by
  review. Accurate: *PunchCard-registered*, *bytecode-reviewed*, *network-admitted*.
- **Not "liquidity is locked".** It is recoverable, indefinitely, by design. The dapp reads
  the state and says so; no other surface may contradict it.
- **Nothing about returns, appreciation or holding.**
- **No "audited".** It has not been.
- **No economics.** Emission rate, reward size and drawer sizing are unvalidated — see
  `docs/economics-review.md`. A live launch does not change that.

## What this launch proves, and does not

It proves the machine: a token on the network, tradable, routable, paying rewards, with
recoverable liquidity and a published, reviewed codebase.

It proves nothing about whether the economics work. That needs customers, months, and the
measurements in `docs/beta-measurement.md`. The first merchant is the experiment, and the
experiment has not started until people are earning and spending.
