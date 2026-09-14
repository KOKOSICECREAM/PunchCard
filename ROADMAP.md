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
| Revenue plumbing | Network fee + router fee built. No keeper, no deployment fee |

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
- **Never import a concrete suite contract into `TokenFactory`.** `new X(...)`, or even the
  type, pulls X's creation bytecode in and blows the size limit. Interfaces only.
- **Never add a page under `/Customer_dapp/`** in the KOKOS repo — its service worker
  caches any in-scope navigation as the app shell and would replace the dapp for installed
  customers.
- **Build-time config, one origin per merchant.** Not runtime multi-tenant: these apps take
  money at a counter, and a bad deploy should have a blast radius of one merchant.
