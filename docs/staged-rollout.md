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

## What is guaranteed, and by what

The distinction merchants and customers are owed, stated exactly.

### Beta (Stage 1)

```
All merchants use the same economic terms by PunchCard POLICY and deployment checklist.
LP is recoverable by the merchant for up to 30 days after launch, then permanently locked.
```

- The 45/30/15/10 split, 180-day cliff, 90-day treasury delay and daily cap **are**
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
