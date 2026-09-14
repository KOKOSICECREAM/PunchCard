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
| Coverage | 62% lines. Branch coverage 11% — thin |
| Audit | None |
| Customer dapp | **KOKOS only.** Not templated. The prototype at punchcard.club/dapp is mock data |
| POS | KOKOS only, bespoke |
| Merchant dashboard | Does not exist |
| Revenue plumbing | Network fee + router fee built, and the dapp now routes through them. No keeper, no deployment fee |

**A merchant today could have a token and no way to issue a reward.** The contracts are
ahead of everything around them.

---

## Phase 1 — Templated customer dapp *(in progress)*

Turn the KOKOS customer dapp into a template plus a config, and make **KOKOS merchant #1
of the new system**. Running the live, money-handling deployment on the templated build is
what proves the template — the same logic as validating against a mainnet fork rather than
a mock.

- [ ] Extract 12 contract addresses and ~155 brand literals into `config.json`
- [ ] Brand theme through the existing 21 CSS custom properties
- [ ] Per-merchant PWA manifest, icons, service-worker cache name
- [ ] Byte-compare rendered output against the live KOKOS dapp
- [ ] Cut KOKOS over, verify in-store, keep a rollback

**Exit criteria:** KOKOS runs on the template with zero behaviour change, and a second
merchant's dapp can be produced from a config file alone.

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

### Still open — native ETH costs two extra transactions

`PunchCardRouter.swap()` is not `payable` and has no WETH handling, so in `punchcard` mode
a customer paying with ETH must **wrap → approve → swap**. That is three transactions on
the most-used path in the app, against one today. The dapp implements the wrap, so it
works, but it is the worst UX in the product and it lands on the default token.

- [ ] Make `swap()` `payable`; when `tokenIn == WETH` and `msg.value > 0`, deposit
      `msg.value` instead of `safeTransferFrom`, and require `msg.value == 0` on every
      other path so ETH cannot be stranded. Collapses it back to one transaction.

## Phase 2 — POS, dashboard, provisioning

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

## Phase 4 — Revenue and mainnet

- [ ] Deployment fee in `deploy()` — onboarding currently recovers neither gas nor labour
- [ ] Keeper for `collectFees()` — without it PunchCard earns nothing from LP
- [ ] Public Sepolia run with Basescan verification
- [ ] External audit
- [ ] Mainnet network deployment
- [ ] KOKOS migrated onto the protocol, or launched as merchant #2

---

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
  → pull the old SKOOP LP, recovering the capital
  → deploy the new token through TokenFactory with that capital
  → distribute to holders over the following months
```

**Snapshot retroactively.** Announcing a future block lets anyone buy SKOOP cheaply to farm
the airdrop, and with a $720 pool a large share of circulating supply costs a few hundred
dollars. A block already in the past closes that completely.

**Sequence matters for how it reads.** Pulling the LP makes old SKOOP untradeable. A holder
who finds a drained pool with no prior announcement will assume the worst regardless of
intent, so announce first and keep the gap between pulling and deploying short.

### Open on this plan

- **Holder count is assumed, not measured.** The working guess is ~5 real holders with the
  rest bots. The whole plan's difficulty scales off this number and it has not been checked.
- **The recovered capital is close, but the wrong shape.** The old pools hold **$720 USDC
  + 0.76 WETH ≈ $2,598** against the $2,000 USDC / $1,000 ETH floors. The ETH side clears
  with ~$878 to spare; the USDC side is short by $1,280. Rebalancing the ETH surplus into
  USDC leaves roughly **$402 to top up** — a real number, not a blocker.
- **This is what set the floors.** KOKOS being unable to meet its own minimum was the
  evidence that $5,000 was wrong, and it drove the move to $3,000 total weighted toward
  USDC (settled 2026-09-14, below). The minimums are **factory-level policy**, not
  per-merchant — they cannot be bent for one shop without bending for all.
- **Distribution source.** Rewards escrow (fast, consumes reward budget) or treasury
  (90-day timelock, uses the merchant's own allocation). See below.

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

## Open design decisions

Each of these is a deliberate choice nobody has made yet.

1. **PunchCard emergency lever.** Wind-down is a 365-day termination — a sledgehammer, not
   a fire alarm. A short, auto-expiring, halt-only pause would match "emergency oversight",
   at the cost of a centralisation surface.
2. **Merchant-initiated wind-down.** Only the multisig can start one. A merchant closing
   their business cannot recover their own LP. No customer guarantee depends on this.
3. **The 10% permanent LP.** At wind-down it is abandoned in the position — not to
   PunchCard, not burned. Probably not intentional.
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
- **Build-time config, one origin per merchant.** Not runtime multi-tenant: these apps take
  money at a counter, and a bad deploy should have a blast radius of one merchant.
