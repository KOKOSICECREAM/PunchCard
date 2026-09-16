# PunchCard Roadmap

Living document. The point is that a decision made once stays made — several things here
were worked out at some cost and would be expensive to rediscover.

Last updated 2026-09-14.

---

## Where things stand

| | |
|---|---|
| Contracts | Compile, fit EIP-170, 63 tests + a Base mainnet fork test |
| Deployment | Network + merchant deployed end to end on a Base Sepolia fork, with a reward issued and a swap executed |
| Coverage | **Not currently reproducible.** `forge coverage` fails — see the auditor note |
| Audit | None |
| Customer dapp | Template builds and routes through PunchCardRouter. **KOKOS still runs its own untemplated copy — cutover frozen pending the SKOOP relaunch decision.** The prototype at punchcard.club/dapp is mock data |
| POS | KOKOS only, bespoke |
| Merchant dashboard | Does not exist |
| Revenue plumbing | Network fee + router fee built, and the dapp now routes through them. No keeper, no deployment fee |

**A merchant today could have a token and no way to issue a reward.** The contracts are
ahead of everything around them.

---

## Phase 1 — Templated customer dapp *(template building; cutover FROZEN)*

Turn the KOKOS customer dapp into a template plus a config. Running a live, money-handling
deployment on the templated build is what proves the template — the same logic as
validating against a mainnet fork rather than a mock.

> **The KOKOS cutover is frozen, decided 2026-09-14.** Today's SKOOP stays exactly as it
> is until the relaunch question below is settled. Nothing in `punchcard-launchpad`
> reaches `KOKOS-website` in the meantime — the launchpad renders into `dist/`, which is
> deployed nowhere.
>
> The reason to wait is that the two paths want different work. If SKOOP is relaunched
> through the factory it becomes a **new token with a new address, new pools and
> `swapMode: 'punchcard'`**, and a cutover done now would be redone in full. If it is not,
> the cutover is a straight swap onto `swapMode: 'uniswap'` and can happen any time.
> Cutting over now is the one order that costs work under either outcome.

- [x] Extract 12 contract addresses into `config.json`
- [ ] Extract ~155 brand literals into `config.json` *(partially done — swap-screen
      strings now render from `brand.shortName`)*
- [ ] Brand theme through the existing 21 CSS custom properties
- [ ] Per-merchant PWA manifest, icons, service-worker cache name
- [ ] Byte-compare rendered output against the live KOKOS dapp
- [ ] ~~Cut KOKOS over~~ **FROZEN** — see above

**Still worth doing while frozen:** everything above the cutover line. The template can be
finished, byte-compared and proven against a second merchant without touching KOKOS.

**Exit criteria:** a merchant's dapp can be produced from a config file alone, and the
rendered KOKOS build matches the live dapp modulo intended fixes.

> One intended difference already exists: the $500 swap cap was skipped whenever the ETH
> price feed was down, including for USDC input. Fixed in the template, so the cap now
> binds. It reaches KOKOS only at cutover.

## Phase 1b — route the dapp through PunchCardRouter *(built 2026-09-14)*

The templated customer dapp calls Uniswap's `SwapRouter02` **directly**:

```
exactInputSingle((tokenIn, tokenOut, fee, recipient, amountIn, amountOutMinimum, sqrtPriceLimitX96))
```

`PunchCardRouter` exposes a different function and a different struct:

```
swap(SwapParams)   // tokenIn, tokenOut, amountIn, minHop1, minHop2, midToken, recipient, deadline
```

**This is not a config change.** Pointing `network.router` at `PunchCardRouter` will not
work — the dapp's calling code has to change.

Correct for KOKOS, which is not a network merchant and has no PunchCardRouter to use. Wrong
the moment a real merchant launches, and it fails *silently*:

- [x] **Network fee collected** on swaps made in the app, via `network.swapMode`
- [x] **Cross-merchant swaps** via `network.partnerTokens`
- [x] `getPoolFeeTiers()` used, both midpoints quoted off-chain to choose `midToken`

Done in `punchcard-launchpad` (`f302944`). `swapMode: 'uniswap'` keeps KOKOS on
SwapRouter02 — SKOOP is not registered with `WindDownController`, so `PunchCardRouter`
would reject it. `swapMode: 'punchcard'` is required for every factory-deployed merchant.

Quotes subtract the network fee off-chain, since on stable→token it comes off the input
before the swap and quoting the gross overstates every quote by the fee.

> Easy to ship the Phase 1 cutover and not notice that swaps quietly stopped paying you.
> Nothing errors. The money simply never arrives.

Guarded on both sides, because that silence is the whole problem: `build.mjs` refuses a
config carrying a `punchCardRouter` address while `swapMode` is `uniswap` — a combination
with no legitimate reading — and the dapp throws at load on an incoherent mode rather than
failing quietly at the till.

### Native ETH path fixed 2026-09-14

`PunchCardRouter.swap()` is now `payable`. In `punchcard` mode, a customer paying with ETH
sets `tokenIn = WETH` and sends `msg.value == amountIn`; the router wraps it, skims the WETH
fee, and swaps the rest in one transaction. Users who already hold WETH can still approve
and swap WETH directly.

Any native ETH sent on a non-WETH route reverts, and native ETH on the WETH route must match
`amountIn`, so ETH cannot be silently stranded in the router. Covered by router tests for the
native happy path, the already-wrapped WETH path, and both rejection cases.

## Phase 2 — POS, dashboard, provisioning

> **The POS contract must emit a redemption event.** `docs/beta-measurement.md` — earning
> and swapping are already observable on-chain, but redemption is not, because PunchCard
> has no payment contract of its own yet. That is the link that closes "a reward earned at
> Merchant A caused a purchase at Merchant B", which is the metric the whole network thesis
> rests on. Easy to ship a POS that works perfectly and measures nothing, and events cannot
> be added to an immutable contract afterwards.

- [ ] POS templated the same way
- [ ] **Kiosk key provisioning**: POS generates its own keypair on first run, stores it in
      device secure storage, displays only the address. Owner calls `addOperator` from
      their phone. The key never exists anywhere else; `removeOperator` is the recovery.
- [ ] Merchant dashboard: drawers, emission runway, treasury, LP, reports
- [ ] `provision.ts` — build and publish one merchant or all, gradual rollout by default
- [ ] Dollar-drift alerting (see Standing Risks)

## Phase 3 — Launchpad UI

Deliberately last. At merchant #2 and #3 a config file and a CLI do the same job, and
building a UI before the schema settles hardens the wrong thing. Around merchant #5.

- [ ] Branding import (logo, colours) with live preview
- [ ] Preview the real dapp and POS **before anything goes on-chain**
- [ ] Deploy runner wrapping the forge scripts; addresses written back from the receipt
- [ ] Pre-flight checklist from the runbook, enforced in UI

## Micro-launch rehearsal — scripted, not yet run

`docs/micro-launch-runbook.md`. ~$20 of seed across two merchants on Base mainnet with
controlled wallets, to learn what a fork cannot teach: real cost, quote-vs-fill, and where
the customer flow snags.

**Everything it deploys is disposable** — seed floors are immutable constructor args, so a
$5-floor factory can never become the production factory, and the router binds to its
controller. Addresses go in `base-mainnet-rehearsal.json` behind a `_WARNING` key, never in
`base-mainnet.json`.

**It proves mechanics, not economics.** No customers, no demand — so it says nothing about
emission rate, drawer size or reward value. Do not cite it for any economic constant.
Two merchants, not one: cross-merchant routing is the least-proven path and the off-chain
midpoint quoting has never run against a real pool.

Known gap going in: `dist/` deploys nowhere, so the mobile install-and-pay flow cannot be
rehearsed until there is an https origin to serve a punchcard-mode build from.

## Phase 4 — Revenue and mainnet

- [ ] Deployment fee in `deploy()` — onboarding currently recovers neither gas nor labour
- [ ] Keeper for `collectFees()` — without it PunchCard earns nothing from LP
- [ ] Public Sepolia run with Basescan verification
- [ ] External audit
- [ ] Mainnet network deployment
- [ ] KOKOS migrated onto the protocol, or launched as merchant #2

---

## BLOCKER — `deploy()` does not fit in a Base transaction

Found 2026-09-15 by the $25 micro rehearsal, on its first live run. The rehearsal paid for
itself in seventeen cents of gas.

```
TokenFactory.deploy()   17,011,396 gas
Base per-tx ceiling     16,777,216 gas   (2^24)
                        ------------
over by                    234,180 gas   (1.4%)
```

**No merchant can be deployed on Base today.** Not beta, not pilot, not production — all
three lineages share `TokenFactory.deploy()` and the number above is that function.

### It is the chain's ceiling, not a provider's

`mainnet.base.org`, `base-rpc.publicnode.com` and `1rpc.io/base` all answer
`gas required exceeds: 16777216`, identically, while the block gas limit is 400,000,000. It
is exactly 2^24. No paid endpoint, gas override or `--gas-limit` flag makes the transaction
includable.

### Compiler settings do not close it

| optimizer_runs | deploy() gas | over by |
|---|---|---|
| 1 | 16,972,887 | 195,671 |
| 50 | 16,973,993 | 196,777 |
| 200 (current) | 17,011,396 | 234,180 |

The most aggressive setting saves 38k of the 234k needed. **The fix is structural.**

### Where the gas goes

Measured on a Base fork:

| step | gas |
|---|---|
| deployToken | 654,622 |
| deployVesting | 662,297 |
| deployTreasury | 759,607 |
| deployEscrow | 1,458,571 |
| deployLocker | 2,539,822 |
| **suite subtotal** | **6,074,919** |
| pools, transfers, registration | ~10,936,477 |

### Status as of 2026-09-15

```
Contracts            conceptually tested — 125 passing, fork-exercised
Base deployability   BLOCKED
Critical path        modular staged deployment
pSKOOP pilot         PAUSED until deploy() is split
micro rehearsal      halted after the network deployed; no merchants exist
```

Everything else in this document that depends on deploying a merchant is downstream of
this. The pilot slug, the wallets, the seed capital and the disclosure work all remain
valid and all wait.

### The fix is the thing this document opened by arguing against

Splitting `deploy()` in two is the obvious remedy, and the natural seam is exactly where the
gas divides:

```
stage 1   deploy the five suite contracts, distribute allocations    ~6.3M
stage 2   create and mint both pools, initialise locker, register   ~10.7M
```

Both fit with room. But this is the **assemble, then verify, then register** model that was
considered and set aside — see the modular-launchpad discussion. The argument against it was
that atomicity is the cheapest possible verifier: every invariant holds by construction,
with nothing to check because nothing can be observed half-built.

That argument was sound and is now moot. **The chain does not permit the atomic version.**
So the half-assembled window has to exist, which means the things atomicity was giving for
free now have to be enforced:

- what stops a stage-1 suite being abandoned, or stage 2 being run twice
- what stops anyone creating the token's Uniswap pool between the two transactions and
  setting the launch price — today impossible only because the token is minted and pooled in
  one transaction, which the factory's own comment relies on
- whether registration happens at stage 2, and what an unregistered half-suite can do

Do not design this in a hurry. Nothing can launch on Base until it is done, so it is now the
critical path, but it is also the decision with the longest shadow.

**The split fits, with room.** From the measured table above: stage 1 is the 6,074,919 of
suite deployment plus four allocation transfers, call it ~6.3M. Stage 2 is the remaining
~10.94M plus a new transaction's base cost and the SLOADs to re-read what stage 1 wrote —
call it ~11.1M. Both are comfortably under 16,777,216, and neither is close enough to the
ceiling to be fragile the way a 234k shave would be.

### Staged shape, decided 2026-09-15

```
1. create suite
2. fund allocations / seed capital
3. create pools + LP
4. verify exact invariants
5. register / activate merchant
```

**Nothing is a PunchCard merchant until step 5.** Before that it is staged, inspectable and
abortable. `register()` remains the activation gate and the router keeps refusing anything
unregistered, so this changes what happens *before* activation and nothing about what
activation means.

What atomicity used to give for free, and now has to be checked explicitly at step 4:

- [ ] token allocation totals — 45/30/15/10 of exactly 100,000,000e6
- [ ] suite contract addresses are the ones this staging produced
- [ ] owner / team / operator match what was staged, and are immutable
- [ ] USDC and ETH seed amounts are what was funded
- [ ] both pool prices agree
- [ ] LP positions exist and are owned by the locker
- [ ] 27M reserve sits in the locker
- [ ] owner wallet received no merchant tokens
- [ ] router and controller accept the token only after activation

### Settled 2026-09-15 — stage 1 issues a claim that stage 2 must present

```
stageSuite(params)                        -> suiteId
fundAndMintLP(suiteId, seeds, slippage)   -> pools, LP, reserve
activateMerchant(suiteId)                 -> final invariant check + register()
```

The `suiteId` is consumed exactly once, which buys three properties the atomic version had
implicitly:

- an abandoned staged suite cannot be completed by a random actor
- stage 2 cannot be replayed
- activation proves it is completing **the exact staged suite that was inspected**, not a
  different one assembled in between

The id must bind the parameters, not just name the suite. If `suiteId` is a bare counter,
stage 2 or 3 can present a valid claim while supplying a different owner, team or operator
than the one staged — and "the suite that was inspected" stops meaning anything. Hash the
params into it.

### Pools: create-or-revert on the first pass

Stage 2 must not silently join a pool someone else created. Three options exist —

```
create the pool at the expected price
or verify an existing pool's price and liquidity are exactly acceptable
or revert
```

— and the first pass takes **create-or-revert**. If the pool already exists, stop. Verifying
someone else's pool is a second mechanism with its own failure modes, and it can be added
later against a working split rather than designed alongside one.

### The front-run that atomicity was silently preventing

`TokenFactory.deploy()` carries this comment, twice:

> The merchant token was created moments ago in this same transaction, so its pool cannot
> exist yet. `mint()` reverts against an uninitialised pool, and `sqrtPriceX96` is what
> actually sets the launch price.

Split steps 1 and 3 into separate transactions and that stops being true. Between them,
anyone watching the mempool can call `createAndInitializePoolIfNecessary` on the new token
at a price of their choosing, and the launch mint lands into a pre-poisoned pool.

**Checking for this at step 4 is too late** — the seed is already in the bad pool by then,
and the remedy is an abort rather than a deploy. Step 3 must instead *create* the pool and
revert if one already exists, so a poisoned pool stops the staging rather than being
discovered after it. That is a stricter call than
`createAndInitializePoolIfNecessary`, which is deliberately tolerant of an existing pool.

### The suite clocks start at stage 1, not at activation

Not on anyone's checklist yet, and it is not an invariant — it is a behaviour change that
staging introduces by existing.

```
VestingWallet.sol:66   vestingStart = block.timestamp
VestingWallet.sol:67   cliffTime    = block.timestamp + _cliffDuration
RewardEscrow.sol:111   emissionStart = block.timestamp
```

All three are set in the constructors, which run in **stage 1**. Under atomic deploy, stage
1 and activation were the same instant, so "the clock starts when the merchant goes live"
was true without anyone deciding it. Split them and it stops being true: a suite staged on
Monday and activated on Friday opens with four days of emission already accrued and four
days already served against the 180-day team cliff.

At minutes between stages this is noise. At days it is a merchant quietly starting with
rewards unlocked that nobody issued, and `bufferCap` is 30 days of emission, so a month-long
staging window would open the escrow at its full spendable ceiling on day one.

Decide deliberately, do not inherit it:

- **accept it**, and require stages to complete within some short window
- **or pass the timestamps in**, so the constructors take a start time that stage 3 sets to
  the activation block

The second is more code and makes the suite contracts take an argument they currently
derive. The first is free and needs enforcing, or it is just a hope.

## Economics — UNVALIDATED

See `docs/economics-review.md`. There is no usage evidence. KOKOS is in beta and barely
used; its on-chain activity is correctness testing, not commerce, and must not be used to
calibrate emission, drawer size or network fee. An earlier version of that document drew
conclusions from it and was wrong.

What holds on logic alone: loyalty tokens generate burns and transfers rather than swaps, so
the network fee will contribute approximately nothing at merchant #1–10, which makes the unbuilt
deployment fee load-bearing.

**Merchant #1 is the experiment.** Instrument rewards issued per day, drawer utilisation,
swap volume and the dollar value of a typical reward. Treat their parameters as provisional
— redeploying one suite is far cheaper than locking a wrong constant across a network.

## Decision: relaunch SKOOP through the factory

**The existing SKOOP can never join the network.** `WindDownController.register()` is
`onlyFactory` and is only ever called inside `TokenFactory.deploy()`; the router then
refuses anything unregistered (`"Token not on network"`). There is no admin override and no
adapter. This is binary, not a preference — if SKOOP is to be routable, it must be deployed
through the factory. Do not spend time looking for a bridge that cannot exist.

Today's SKOOP can keep running exactly as it does. It simply cannot be swapped to or from
any other merchant's token.

**Decided 2026-09-14: leave it running, unchanged, until this is settled.** No cutover, no
migration, no contract changes to the live deployment. This decision gates the Phase 1
cutover and nothing else — template work, contracts, launchpad and a second merchant all
proceed independently of it.

### Why the clock runs the wrong way

Migration cost grows with holder count, and KOKOS is in beta — 2.5M of 888M burned, a $720
pool, few third-party holders. **It will never be cheaper than now.** The deadline is not
when the contracts are ready; it is when SKOOP has enough holders to make migration
political.

What a relaunch buys beyond network membership:

- **The drawer model.** Live SKOOP has the un-rotatable operator problem PunchCard fixed. A
  leaked POS key today has no per-kiosk cap and no removal path.
- Emission schedule, wind-down protections, treasury timelock.
- **"Merchant #1" becomes true.** The site says *"Where This Was Built"* precisely because
  KOKOS is not a factory deployment.

### Working plan — DEBATABLE, not decided

Relaunch through the standard factory. No special contract, no exception: KOKOS is the
reference merchant and is the one that most needs to run identical bytecode to everyone
else.

```
verify the real holder count (basescan token holders page — do not guess)
  → pick a snapshot block that has ALREADY PASSED, then announce
  → rehearse the cutover on a Base fork with the real seed amounts
  → fund fresh wallets with $2,000 USDC + $1,000 of ETH
  → deploy the new token through TokenFactoryPilot from those wallets
  → move the old SKOOP LP out BY HAND, on your own schedule
  → verify, then lockLP() when the pilot is proven
  → distribute to holders over the following months
```

**Nothing automated touches KOKOS's existing deployment.** Decided 2026-09-15. The pilot
launches from fresh wallets with fresh capital, and the old LP is moved manually rather than
drained by a script that has to be handed the keys to live positions. That removes a whole
class of risk — no automated path has authority over anything KOKOS already has — at the
cost of the cutover step being unrehearsed by construction. Accepted: the mechanical risk in
`decreaseLiquidity` + `collect` through the Uniswap UI is low and well-trodden. The risk that
remains is **sequencing**, which no test was ever going to cover (see below).

**Pilot factory, mainnet floors.** These are two separate dials and conflating them is the
mistake this document keeps warning about. Clearing the $2,000 / $1,000 floors does *not*
mean launching through the production factory — `TokenFactoryPilot` takes its floors as
constructor arguments, so the fresh pilot gets the real liquidity depth AND the open-ended
recovery hatch. The micro floors exist for the $20 mechanical rehearsal, where nobody
trades. A live pilot with real customers uses real floors.

**Snapshot retroactively.** Announcing a future block lets anyone buy SKOOP cheaply to farm
the airdrop, and with a $720 pool a large share of circulating supply costs a few hundred
dollars. A block already in the past closes that completely.

**Sequence matters for how it reads.** Pulling the LP makes old SKOOP untradeable. A holder
who finds a drained pool with no prior announcement will assume the worst regardless of
intent, so announce first and keep the gap between pulling and deploying short.

### Open on this plan

- ~~**Holder count is assumed, not measured.**~~ **Measured 2026-09-14** by scanning all
  2,494 Transfer events since deployment (block 43,454,133) and reading every balance
  on-chain. 76 addresses ever touched SKOOP; 50 hold a non-zero balance.

  **13 public wallets hold $1 or more, worth $338 combined.** Largest is $103, median
  $11.78, six are under $10. A further 28 wallets hold non-zero dust totalling $1.19.

  Everything else is project infrastructure: five addresses — two contracts and three EOAs,
  one holding exactly 88,888,890 tokens — hold **95.9% of supply**, plus the two pools and
  the POS signer.

  **This settles the migration question.** The difficulty was supposed to scale off this
  number; at 13 wallets and $338 it is not a distribution problem at all. Anything owed
  can be made whole from the merchant's own treasury allocation rather than the rewards
  escrow, since the amounts are trivial next to a 10% treasury — and the 90-day timelock
  is affordable when the date can be announced to thirteen people.

  Caveat: SKOOP's total supply is **886,355,705**, not the factory's 100,000,000. Any
  relaunch has to pick an exchange ratio and defend it. With $338 of public value at stake,
  generosity is cheaper than argument.
- ~~**The recovered capital is close, but the wrong shape.**~~ **Moot as of 2026-09-15** —
  the pilot is funded with fresh capital, not with the old pools. Recorded because the
  measurement stands and explains why: the live pools hold **$720 USDC + 0.76 WETH**, so the
  ETH side cleared its floor with ~$826 to spare while the USDC side was short $1,280.
  Recycling that would have meant a top-up *and* handing a script authority over live
  positions, to save roughly $1,290. Not worth it.

  The pilot seeds **$2,000 USDC + $1,000 of ETH** — the floors exactly. Verified against a
  live Base fork: $2,000.00 + $1,010.28 = **$3,010.28**, clears both.

  The old LP still comes out eventually; it is now a manual step on its own schedule rather
  than a dependency of the launch.
- **This is what set the floors.** KOKOS being unable to meet its own minimum was the
  evidence that $5,000 was wrong, and it drove the move to $3,000 total weighted toward
  USDC (settled 2026-09-14, below). The minimums are **factory-level policy**, not
  per-merchant — they cannot be bent for one shop without bending for all.
- **Distribution source.** Rewards escrow (fast, consumes reward budget) or treasury
  (90-day timelock, uses the merchant's own allocation). See below.

### Gates before mainnet — both must clear

Settled 2026-09-15 after the fork rehearsal. Everything downstream of these two is proven;
these two are not.

**Gate 1 — sequencing, not a test run.** ~~Run phase 1 against the real positions.~~
Superseded 2026-09-15: the LP is moved by hand from fresh wallets, so there is no automated
drain to rehearse. What that step still carries is unchanged and no test ever covered it —

- **Announce before pulling.** Pulling the LP makes old SKOOP untradeable. A holder who
  finds a drained pool with no prior announcement assumes the worst regardless of intent.
- **Keep the gap short.** Between pulling and the new token being tradeable, there is
  nothing for a holder to do and nothing for them to read except silence.
- **Snapshot retroactively**, on a block already in the past. See above.

`test_phase1_liveSkoopLiquidityIsRecoverable` is kept and still runs with
`PC_SKOOP_LP_OWNER` set. It is now a **dry run for a human**, not a gate: whoever pulls those
positions by hand can watch exactly what `decreaseLiquidity` + `collect` do on a fork first.

**Gate 2 — real launch capital.** $2,000 USDC + $1,000 of ETH into fresh wallets. Rehearse
the real numbers before the day:

```
PC_MIGRATION_USDC=2000000000 PC_MIGRATION_ETH=415000000000000000 \
  forge test --match-path test/SkoopMigration.t.sol --fork-url https://mainnet.base.org -vv
```

The ETH side is sized in **wei**, not dollars, because the floor is USD-denominated against
Chainlink and the wei that clears $1,000 moves with the price. Re-run this close to the day
and read what phase 2 prints; a seed sized in dollars months earlier is how a deploy reverts
on the morning it matters.

**What the rehearsal already proves** (`test/SkoopMigration.t.sol`, 6 passing against a live
Base fork):

- the migrated suite deploys with allocations landing exactly — 45/30/15/10, factory drained
- day zero pays no rewards and that is correct: `emitted()` accrues from deploy, so the POS
  reverts with `"Emission limit"` for the first few minutes. **Brief the operator.** It will
  look like a bricked kiosk on launch morning.
- a real trade through live Uniswap generates collectable fees and the network fee reaches
  PunchCard
- `evacuateLP()` returns the seed and the full 27M reserve from a suite that had already
  issued rewards and been traded against, then bricks the locker
- **wind-down completes end to end — the first time it has ever been executed.** Freezes
  land on `initiate`, the terminal gate refuses until the other three legs settle, 94.3M
  burns. It is not on the operating path (every suite contract gates it behind
  `onlyWindDown`, and their `notFrozen` checks read a local bool rather than calling out),
  so a bug there could never have bricked day-to-day SKOOP — but it is a promise made to
  merchants, and it now has evidence behind it.

**What it does not prove.** Mechanism, not economics. It says nothing about whether 45M over
1825 days is the right emission rate, what a reward should be worth, or whether drawer sizes
match real kiosk traffic. See `docs/economics-review.md`, which is correct to call those
unvalidated.

### Vesting does not behave like KOKOS's — check before quoting a date

Pinned by `test_phase3_vestingAndTreasuryOnTheLongClock`, because the live deployment is the
obvious thing to reason from and it will mislead you:

| | KOKOS `TeamVesting` (live) | PunchCard `VestingWallet` |
|---|---|---|
| accrues from | `startTimestamp` | `cliffTime` |
| at the cliff | ~17% immediately claimable | **zero** |
| fully vested | start + duration | start + cliff + duration — **day 1260, not 1080** |

Same three words in the docs, different money. KOKOS's live contracts are a good
*differential oracle* for the new ones, but they are different code — 295 lines against 332
for the vault, 103 against 155 for vesting — so "KOKOS works" is not evidence about this
bytecode.

### Migrating holders — use the rewards escrow, not an exception

The factory mints 100M into fixed allocations with no airdrop bucket, and the treasury's
90-day timelock makes a fast distribution awkward. **Do not carve out a migration
allocation** — every merchant would inherit a bucket they do not need, and it would break
the uniformity the network is sold on.

Use `RewardEscrow.distributeReward()`. It sends to any address, and existing SKOOP holders
*are* customers who earned loyalty rewards — paying them from the rewards pool is what that
pool is for. No new contract, no new bytecode to audit, and the drawer and emission limits
apply, so a botched airdrop cannot drain anything.

**Throughput:** the default drawer is two days of emission (49,315/day). The owner can raise
it to `MAX_DRAWER_DAYS` (14 days, ~345,205/day) with `setDrawerAllowance`, then lower it
again. A 1M-token migration takes about three days at the raised rate.

**Mechanics:**

- [ ] Snapshot SKOOP balances at an announced block
- [ ] Exclude KOKOS's own addresses — rewards vault, team vesting, both pools, payment
      escrow, treasury and marketing wallets. Only genuine third-party holders qualify
- [ ] Allocate a migration pool as a share of the 45M rewards allocation and distribute
      **proportionally** — supply falls from 888M to 100M, so 1:1 is impossible and any
      promise of it would be wrong
- [ ] Raise the operator drawer for the distribution window, then put it back
- [ ] **Pick a distinct symbol.** Two tokens called SKOOP on Base is a support problem and a
      phishing surface

> The escrow route is deliberately rate-limited rather than a bulk send. That is the point:
> the migration runs through the same machinery a normal reward does, so it inherits every
> protection already tested rather than needing a trusted one-off path.

## Note to auditors — read this before the contracts

Say this plainly rather than let it be discovered:

- **Coverage cannot currently be measured.** `forge coverage` disables `viaIR`, which this
  project requires, so it fails with *stack too deep* in `LPLocker`. The documented
  workaround, `--ir-minimum`, also fails — a Yul *"1 too deep in the stack"* in
  `TokenFactory`. The previously recorded figures (62% line / 11% branch) predate the
  current contracts and **cannot be regenerated**, so do not quote them. Branch coverage
  was thin when last measured and nothing since has targeted branches. Restoring a working
  coverage run is a prerequisite for the audit, not a nice-to-have: right now no one can
  tell an auditor what is untested, which is exactly how the wind-down policy went
  untested through 20 passing tests.
- **Several of the important findings were in the verification mechanisms, not in protocol
  intent.** The pattern that keeps recurring is a check that passes because it is not
  testing anything. Concretely:
  - `MockWDC` returned constant `false` for both wind-down states, so the router's entire
    wind-down policy passed 20 tests without one reaching it.
  - The fork test passed only because the merchant owner happened to be the broadcaster,
    masking an approval bug.
  - A `try/catch` in an invariant handler defeated `fail_on_revert = true`.
  - The seed floors were only ever exercised from *above*, so a non-binding floor would
    have passed the whole suite.
  - Two `@notice` comments documented a fixed 60/40 launch split whose constants had been
    deleted — NatSpec asserting an algorithm the contract no longer implements, on the
    first function an auditor reads.
- **Where bugs clustered:** deployment choreography (`TokenFactory.deploy()`), merchant-facing
  liquidity (`LPLocker`), router policy, and docs/config drift.
- **Useful context to hand over:** this roadmap's *Settled* section for design intent,
  `docs/audit-2026-09.md` for the prior audit, and the invariant suite.

Treat a green run here as a claim to check, not evidence.

## Open design decisions

Each of these is a deliberate choice nobody has made yet.

0. **NFT layer — direction, NOT settled.** ERC-20 stays the fungible reward asset; NFTs
   would layer on top for status, access passes, VIP perks, yearly membership and limited
   drops, mintable with the merchant's token. Recorded here rather than under *Settled*
   because nothing has been designed, costed or built, and it briefly appeared on a
   summary as a settled answer with no record anywhere in the repo behind it. Directionally
   agreed; do not cite it as decided.

1. **PunchCard emergency lever.** Wind-down is a 365-day termination — a sledgehammer, not
   a fire alarm. A short, auto-expiring, halt-only pause would match "emergency oversight",
   at the cost of a centralisation surface.
2. **Merchant-initiated wind-down.** Only the multisig can start one. A merchant closing
   their business cannot recover their own LP. No customer guarantee depends on this.
3. **The 10% permanent LP.** At wind-down it is abandoned in the position — not to
   PunchCard, not burned. Probably not intentional, but it is now load-bearing for the
   wind-down policy below: it is what keeps a wound-down token tradable at all, so
   removing it would quietly turn "you can still sell" into a false statement.
4. **ETH pool economics.** Cross-merchant routing can now use either pool, but liquidity is
   still split across two thin pools. Worth revisiting whether both are earning.
5. **`teamWallet` recovery.** Immutable forever, controls 15% of supply. A lost key means
   that allocation vests to a dead address permanently.
6. ~~**LP fee share is 20%.**~~ — **decided 2026-09-14.** It is now the **network fee**:
   PunchCard takes the entire pair-asset side (USDC/WETH); the merchant-token side is
   burned. The renaming matters as much as the number — "LP fee share" described a rent on
   the merchant's capital, when the mechanism is a toll on using the network, and it
   replaces the monthly platform fee a merchant would otherwise pay forever. It is also not
   the whole fee: Uniswap charges on the input token, so roughly half of fee value accrues
   in the merchant token and is burned, lifting what the merchant already holds.



---

## Standing risks

**Dollar drift** — drawers, `perTxFloor` and `perTxMax` are token-denominated. If a token
appreciates 10x, an $82 drawer silently becomes an $820 drawer and rewards become 10x too
generous. `setDrawerAllowance` and `setPerTxBounds` exist; nobody will remember to use
them. **This is the most likely real-world failure in the system** and it is slow and quiet.

**A failed reward must never block a sale.** `distributeReward` reverts on an empty drawer,
a pause, or the emission limit. If the POS treats that as a failed transaction, a reward
outage stops the shop selling. Fire-and-forget, retried or dropped, never in the critical
path of taking money.

**USDC approval front-running.** `deploy()` pulls from `ownerWallet`, so a standing
approval could be consumed with someone else's parameters. `DeployMerchant.s.sol` approves
exactly the seed immediately before deploying; keep that property in any UI.

**Verify every external address on-chain, never from a doc.** The position manager in the
original README was one character off from an address with no code on it, which would have
reverted every deployment forever. `cast code` takes seconds.

---

## Settled — do not relitigate without new information

- **No PunchCard token.** Revenue is network fee, router skim, deployment fee — all in
  dollars. A network token reintroduces the conflict of interest the model is built
  against, adds a securities question, and muddies an equity raise. See README.
- **Split the factory, don't use clone proxies.** Clones cannot use `immutable`, which
  would turn `teamWallet`, `ownerWallet` and `operator` into ordinary storage and weaken
  the guarantee the trust model rests on.
- **Seed minimums are constructor arguments.** So testnet and mainnet run identical
  bytecode. Never compile a special build for testing.
- **Seed floors are $2,000 USDC / $1,000 ETH** — **decided 2026-09-14**, down from
  $2,000 / $3,000 and weighted the opposite way to the first proposal ($1,000 USDC /
  $2,000 ETH). Two reasons:
  - **$3,000 total, not $5,000.** $5,000 of working capital before a single reward is
    issued is a genuine barrier for an independent shop, and KOKOS itself could not clear
    it. $3,000 is still enough depth that ordinary reward-swap flow does not whipsaw the
    price.
  - **Depth belongs on the USDC side.** USDC carries customer purchases, cross-merchant
    routing and merchant cash-out. The ETH pool is the speculative venue, and speculators
    are the participants most able to size their own trades around thin liquidity. An
    earlier version of this argument leaned on customer slippage; that was wrong —
    customers receive rewards, they are not price-sensitive traders. The real cost of a
    thin pool is **instability in what holders already own**, plus arbitrage leakage
    between the two pools.
- **The merchant's incentive to seed deeply is their own holding, not fee income.** A
  merchant holds 25,000,000 tokens (10M treasury + 15M vesting) — **$25,000** at a $3,000
  seed. A 10% price move is worth **$2,500** to them; the pair-asset fees now used as the
  network fee were worth **$12–$240/year** at realistic volume. Fee income was never the
  meaningful incentive. Treasury's 90-day timelock and the 180-day vesting cliff
  mean they cannot exit into a pump, so the only way to act on that incentive is the slow
  one: deeper pools, more customers, more burn from real sales. **This is the pitch** —
  "$3,000 establishes the market for an asset you own 25% of", not "$3,000 to fund a
  loyalty programme".
- **Never import a concrete suite contract into `TokenFactory`.** `new X(...)`, or even the
  type, pulls X's creation bytecode in and blows the size limit. Interfaces only.
- **Never add a page under `/Customer_dapp/`** in the KOKOS repo — its service worker
  caches any in-scope navigation as the app shell and would replace the dapp for installed
  customers.
- **A change touching customer flow crosses two repos.** Contracts here, dapp in the
  private `punchcard-launchpad`. Both must be committed *and pushed*; a commit is not a
  push, and the gap is silent. Checklist lives in that repo's README — single copy on
  purpose.
- **Figures quoted to customers are read from the contract, not retyped in the app.** The
  wind-down disclosure reads `LPLocker.WIND_DOWN_RELEASE_PCT()`. A hardcoded copy would
  keep asserting a number the contract had stopped meaning.
- **Staged rollout: one network, three stages.** — **decided 2026-09-14.** Rehearsal →
  Beta (real merchants, 30-day LP recovery window) → Production (strict factory, no
  recovery). All stages share ONE `WindDownController` and ONE router, which is why the
  controller holds a *set* of authorised factories behind a 48-hour timelock. A controller
  per stage would have split the network exactly where the network effect is being proven,
  and it could not be retrofitted — the field was immutable. Full detail and the exact
  beta-vs-production guarantee language in `docs/staged-rollout.md`.
- **Testing-only trust assumptions live in a separate contract lineage, never in the
  protocol** — **decided 2026-09-14.** The first live deployment runs unaudited code, so a
  temporary LP evacuation hatch is reasonable *for that deployment*. It is NOT reasonable
  for every merchant to inherit forever. So `contracts/rehearsal/` holds
  `TokenFactoryRehearsal` / `LPLockerRehearsal` with a 30-day self-expiring, one-way,
  evacuate-everything hatch, and production keeps no withdrawal path at all.
  `REHEARSAL_ONLY()` makes the lineage queryable on-chain, because otherwise the
  distinction is a constructor argument nobody can see. The worst outcome this avoids is
  shipping a temporary safety valve into permanent architecture and having to explain it
  later.
- **Build-time config, one origin per merchant.** Not runtime multi-tenant: these apps take
  money at a counter, and a bad deploy should have a blast radius of one merchant.
- **The router gates membership, not health** — **decided 2026-09-14, pre-deploy.**
  `isRegistered` and `isComplete` are membership questions and stay enforced in the
  contract. `isInitiated` is a health question and was removed: `initiate()` is
  `onlyMultisig`, so blocking on it let PunchCard make a merchant's token unbuyable on the
  official route by fiat — a kill switch over someone else's market, in a protocol whose
  promise is that PunchCard does not control the merchant's token. It never prevented the
  trade either, since these are ordinary Uniswap pools and 10% of liquidity stays in the
  pool permanently; it only prevented the informed one. The interface discloses the expiry
  date and what happens on it. **Swap logic is immutable once deployed — reinstating this
  would mean redeploying the router and migrating every merchant.**
