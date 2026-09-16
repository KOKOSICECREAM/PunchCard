# Staged rollout — what is guaranteed, and by what

Decided 2026-09-14. Reversibility before scale: prove the machine on real merchants with a
recovery path, then make the guarantees contractual.

## The stages

| | Stage 0 — Rehearsal | Stage 1 — Beta | Stage 2 — Production |
|---|---|---|---|
| Money | ~$20 total | Real seed, real merchants | Real |
| Merchants | Throwaway | KOKOS + 2–4 friendly | Anyone onboarded |
| Contracts | `*Beta` lineage | `*Beta` lineage | `TokenFactory` / `LPLocker` |
| LP recovery | 30-day window | 30-day window | **none, ever** |
| Controller | Throwaway | **THE controller** | Same controller |
| Config | `base-mainnet-rehearsal.json` | `base-mainnet.json` | `base-mainnet.json` |

Stage 2 does not deploy a new network. It deploys a **strict factory** and authorises it
into the controller Stage 1 already created.

## One network across all stages

This is the part that had to be built before any beta deployment, because it cannot be
retrofitted.

`WindDownController.factory` used to be a single immutable address, and `PunchCardRouter`
binds to one controller. That made the chain rigid — beta factory → beta controller → beta
router, production factory → production controller → production router — which is **two
networks**. A beta merchant's token and a production merchant's token could never be
swapped against each other; each router rejects the other's merchants with *"Token not on
network"*. The network effect would have stopped at the stage boundary, right where it was
being proven.

So the controller now holds a **set** of authorised factories:

```
proposeFactory(addr, authorize)   multisig, starts a 48-hour timelock
executeFactory(addr)              multisig, after the timelock
```

- Beta and production merchants register into the same controller, route through the same
  router, and see each other as one network.
- Disabling a factory stops it registering **new** merchants. Merchants it already
  registered keep working — retiring a deployment path must never orphan its merchants.
- **This is a governance power, not a custody power.** Authorising a factory adds a future
  deployment path. There is no function here that mutates a registered suite, and
  `register()` refuses a token that is already registered, so a newly blessed factory
  cannot reach an existing merchant's terms, liquidity or tokens.

## The pilot lineage — SKOOP only

Added 2026-09-15. A third lineage sits beside beta and production, for **one deployment**.

| | Production | Beta | **Pilot** |
|---|---|---|---|
| Factory | `StagedTokenFactory` | `StagedTokenFactoryBeta` | `StagedTokenFactoryPilot` |
| Locker | `LPLocker` | `LPLockerBeta` | `LPLockerPilot` |
| LP recovery | none, ever | 30 days from activation, self-closing | **open until closed by hand** |
| Who | any merchant | beta merchants | **pSKOOP only** |

> **The atomic `TokenFactory` / `TokenFactoryBeta` / `TokenFactoryPilot` lineage is
> reference-only on Base.** `deploy()` is 17,325,962 gas against a 16,777,216 cap. The three
> lineages above are the staged equivalents and carry the same marker constants —
> `HAS_LP_RECOVERY` on beta and pilot, `HAS_UNLIMITED_LP_RECOVERY` on pilot alone.
>
> Note "30 days **from activation**": every clock in a suite — emission, team cliff,
> treasury, and the recovery hatch — starts when the merchant goes live, not when the
> contracts were built. Staging means those are no longer the same instant.

`LPLockerBeta`'s first guardrail says a hatch that must be closed by hand can be left open
forever through neglect or intent, and that `EVACUATION_WINDOW` closes it regardless of
whether anyone acts. **The pilot deletes that guardrail on purpose.** The reasoning is not
refuted, it is accepted: KOKOS's pilot is PunchCard testing its own machine with its own
money, on a schedule set by the work rather than by a constant. A 30-day fuse there fails in
the worst direction — the window shuts mid-test and real capital is committed for a year
because nobody watched a calendar.

**That reasoning does not transfer to a merchant.** A merchant is owed a liquidity guarantee
that does not depend on PunchCard remembering to honour it, which is exactly what a
self-closing window provides and an open-ended one does not. Merchants get beta or
production. Nothing else.

**Enforced structurally, not by policy.** The pilot is a separate contract, separate
deployer and separate factory, so "SKOOP only" is enforced by which factory the controller
has authorised. For the first pilot network there is nothing to authorise:
`DeployNetworkStaged` creates the controller with `StagedTokenFactoryPilot` already wired
in. `proposeFactory` / `executeFactory` are for adding a **later** factory — a production
one at Stage 2 — to that same controller, and disabling one leaves merchants it already
registered working, which is what that path was built for.

```
cast call $FACTORY 'HAS_LP_RECOVERY()(bool)'            → true on beta and pilot
cast call $FACTORY 'HAS_UNLIMITED_LP_RECOVERY()(bool)'  → true on pilot only
```

At the locker level there is no marker constant on `LPLockerBeta`, so which calls *answer*
is the discriminator: `evacuationOpen()` reverts on production; `evacuationExpiresAt()`
answers only on the pilot, returning `type(uint256).max`. The inherited `evacuationDeadline`
on a pilot locker still reads deploy + 30 days and **does not apply** — read
`evacuationExpiresAt()`.

**While the hatch is open, SKOOP's liquidity is not locked, and no PunchCard surface may say
that it is.** This is the same rule as beta, for a longer and open-ended period. Closing it
is a deliberate act (`lockLP()`), one-way, and after it the contract behaves exactly as
production does.

Covered by `test/PilotRecovery.t.sol` (10 tests, including that beta still self-closes and
production still has no hatch at all) and `test_phase4_pilotHatchSurvivesBeyondThirtyDays`
against live Base.

## What is guaranteed, and by what

The distinction merchants and customers are owed, stated exactly.

### Beta (Stage 1)

```
All merchants use the same economic terms by PunchCard POLICY and deployment checklist.
LP is recoverable by the merchant for up to 30 days after launch, then permanently locked.
```

- The 45/30/15/10 split, 30-day cliff, 90-day treasury delay and daily cap **are**
  contractual — they are `constant` in the factory and cannot be negotiated.
- What is *not* contractual in beta is the LP lock. It becomes contractual when the window
  closes, either by `lockLP()` or by expiry.
- **Do not describe a beta merchant's LP as permanently locked** until that has happened.
  The dapp reads the state from the locker rather than asserting it.

### Production (Stage 2)

```
All merchants use the same economic terms because the factory makes alternatives impossible.
LP is permanently locked at deployment. There is no recovery path in the contract.
```

## Language

During Stage 1, this is a **PunchCard beta launch, using the protocol architecture with a
launch verification window** — not the final trustless protocol. After Stage 2 it is a
**PunchCard production launch, factory-enforced, no LP recovery path**.

The strong version of the marketing claim belongs to Stage 2 only. Saying it earlier would
be false in one specific, checkable way, which is the worst kind.

## Moving from Stage 1 to Stage 2

1. Beta merchants close their windows (`lockLP()`) or let them expire. After that their
   contracts behave identically to production.
2. Deploy `TokenFactory` (strict) pointing at the **existing** controller.
3. `proposeFactory(productionFactory, true)` → wait 48 hours → `executeFactory`.
4. `proposeFactory(betaFactory, false)` → wait 48 hours → `executeFactory`. Existing beta
   merchants are unaffected; the path simply closes to new ones.
5. Update the site to the strong claim — **after** step 4, not before.

Never deploy a second `WindDownController`. That is the one irreversible mistake available
here, and it splits the network permanently.

**This is enforced, not just written down.** `test/DeploymentInvariants.t.sol` reads the
deploy scripts and asserts:

- every script that constructs a `WindDownController` demands `PC_CREATE_NEW_NETWORK=true`
- `DeployProductionFactory.s.sol` never constructs one, and takes the existing controller
  as input
- production scripts never import the beta lineage

Each was confirmed to fail when deliberately violated, rather than assumed to work — a
green test that cannot fail is this codebase's most repeated bug.

### Which script for which job

| Job | Script | Creates a controller? |
|---|---|---|
| Start a network from nothing | `DeployNetwork.s.sol` / `DeployNetworkBeta.s.sol` | **yes** — gated behind `PC_CREATE_NEW_NETWORK` |
| Stage 2: add the strict factory | `DeployProductionFactory.s.sol` | no — reuses `PC_WIND_DOWN_CONTROLLER` |
| Deploy a merchant | `DeployMerchant.s.sol` | no |

Stage 2 is the dangerous one, because `DeployNetwork.s.sol` looks like the right script and
is not: running it would fork the network rather than extend it.

## Telling the lineages apart on-chain

```bash
cast call $FACTORY 'HAS_LP_RECOVERY()(bool)' --rpc-url https://mainnet.base.org
# reverts → production, no recovery path
# true    → beta, merchants have a 30-day recovery window
```

The distinction is otherwise a constructor argument and invisible on a block explorer,
which is why it was made structural.
