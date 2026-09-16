# Deployment Runbook

Two distinct procedures. **Network setup** happens once, ever. **Merchant onboarding**
repeats identically for every business that joins.

---

## Rules for Base — read these before anything else

Settled 2026-09-15, after a live micro rehearsal found the ceiling that makes them
necessary.

1. **The atomic `TokenFactory` lineage is reference-only on Base.** `deploy()` costs
   17,325,962 gas against a 16,777,216 per-transaction cap — a chain-level limit, identical
   across every RPC and exactly 2^24. It is kept as the readable version of what the stages
   do and as the oracle the staged tests compare against. `DeployNetwork.s.sol`,
   `DeployNetworkBeta.s.sol`, `DeployProductionFactory.s.sol` and `DeployMerchant.s.sol` all
   refuse to run on chainid 8453, mechanically.

2. **Base merchant launches use `StagedTokenFactory*`**, through
   `DeployNetworkStaged.s.sol` and `StageMerchant.s.sol`.

3. **pSKOOP starts a fresh staged network.** `DeployNetworkStaged` creates its own
   `WindDownController` with the staged factory already authorised, so there is **no
   authorisation step** for the first network. `proposeFactory` / `executeFactory` exist
   for adding *later* factories to that same controller.

4. **Never reuse the micro rehearsal controller.** The one at
   `0x54BeC817f99f1a477944e84688bCeBEAF92175E7` is a disposable artifact of the rehearsal
   that found the gas ceiling. It has no merchants, it is not the network, and it stays
   dead. Registration is permanent, so anything registered into it would be stuck there.

5. **Do not deploy a second controller once pSKOOP exists.** A controller *is* the network.
   The router binds to one, so merchants under a second could never swap against the
   first's — unfixable afterwards and invisible until a cross-merchant swap fails. After
   pSKOOP, every new deployment path is added to its controller, never alongside it.

6. **The later production factory is added, not deployed beside.**
   `proposeFactory(stagedProductionFactory, true)`, wait 48 hours, `executeFactory`.
   Merchants already registered are untouched.

---

# Part 1 — Network setup (once)

> **On Base, run `DeployNetworkStaged.s.sol` and skip the manual order below.** It resolves
> the circular dependency with `vm.computeCreateAddress`, wires `StagedTokenFactoryBeta`,
> and demands `PC_CREATE_NEW_NETWORK` first. The manual sequence is kept because it
> describes what the script does and because the constructor arguments are the same either
> way — but the atomic `TokenFactory` it names cannot onboard a merchant on Base. Substitute
> `StagedTokenFactoryBeta`; the constructor signature is identical.

`WindDownController` and the factory reference each other, so the order matters.

### The circular dependency
`WindDownController` needs the factory address; `TokenFactory` needs the controller
address. Resolve it one of two ways:

- **CREATE2** — pre-compute the factory address, pass it to the controller, then deploy
  the factory to that exact address. Clean, one pass, no throwaway contracts.
- **Deploy twice** — deploy a throwaway controller with any placeholder, deploy the
  factory against it, then deploy the *real* controller with the real factory address and
  point the factory at it. Simpler to execute, but leaves a dead controller on-chain;
  make sure the factory ends up referencing the real one.

### Order

**1. WindDownController**
```
_multisig  — PunchCard multisig
_factory   — TokenFactory address (pre-computed, or fixed up per above)
```

**2a. SuiteDeployer and 2b. LockerDeployer** — no constructor arguments
```
Construction helpers holding the suite contracts' creation bytecode. Deploy both, then
pass their addresses to TokenFactory. Order between them does not matter.
```
> They are permissionless by design. A contract deployed through them in isolation is
> inert — no distributed supply, no pools, not registered with the WindDownController.
> Merchant status comes from a MerchantDeployed event and WindDownController registration,
> nothing else.

**3. TokenFactory**
```
_multisig            — PunchCard multisig
_deployer            — PunchCard deployer hot wallet (the only caller of deploy())
_windDownController  — from step 1
_positionManager     — see deploy/network/base-mainnet.json
_usdc                — see deploy/network/base-mainnet.json
_weth                — see deploy/network/base-mainnet.json
_ethUsdOracle        — Chainlink ETH/USD feed, see the network file. Verified on-chain:
                       description() is "ETH / USD" and decimals() is 8
_punchcardFeeRecipient — receives the network fee — the pair-asset side of every merchant's trading fees
_suiteDeployer       — from step 2a
_lockerDeployer      — from step 2b
```

**4. PunchCardRouter**
```
_multisig            — PunchCard multisig
_windDownController  — from step 1
_swapRouter          — Uniswap SwapRouter02, see network file
_usdc / _weth        — see network file
_initialFeeRate      — basis points (30 = 0.30%)
_initialFeeRecipient — PunchCard operational wallet
```

Compiler: **0.8.24 or higher**, OpenZeppelin v4.x or v5.x.

> **Check every external address against the chain before deploying, not against a doc.**
> The position manager in the original README was one character off — `...34f4` instead of
> `...34f1` — and nothing is deployed at the wrong address, so `deploy()` would have
> reverted for every merchant. `cast code <addr>` takes seconds; a wrong address costs a
> redeploy of the whole network.

After deploying, record all five addresses in `deploy/network/base-mainnet.json` and verify all
three on Basescan.

---

# Part 2 — Merchant onboarding (repeat per business)

This is the path every business follows. Copy `deploy/merchants/_template.json`, fill it
in, and work down the checklist.

## Step 1 — Collect three wallets

These are the only merchant-specific addresses, and **two of them can never be changed**.

| Wallet | Controls | Mutable? |
|---|---|---|
| `ownerWallet` | Treasury releases, `perTxMax`, LP reserve, receives LP at wind-down | **Immutable** |
| `teamWallet` | Receives vested team tokens | **Immutable forever** |
| `operator` | POS signer — the only address that can distribute rewards | **Immutable** |

> Get these wrong and the only remedy is redeploying the merchant from scratch. Confirm
> each one on-chain with a test transaction before deploy day. `teamWallet` deserves a
> hardware wallet — it controls 15% of supply vesting over three years.

## Step 2 — Pin merchant metadata to IPFS

Name, symbol, logo. The resulting hash goes in `ipfsHash` as `bytes32` and is stored
immutably on the token. This is how the dapp discovers and displays the merchant, so pin
it somewhere that will stay pinned.

## Step 3 — Choose pool seed amounts

The factory seeds **both** a USDC pool and an ETH pool. Both are mandatory.

| Field | Rule |
|---|---|
| `usdcFeeTier` / `ethFeeTier` | 100 / 500 / 3000 / 10000 |
| `usdcPairAmount` | **Minimum $2,000.** USDC, 6 decimals |
| `ethPairAmount` | **Minimum $1,000** at the Chainlink price. Wei, sent as `msg.value` |

These are floors, not fixed sizes — the merchant, an outside investor, or PunchCard may
seed deeper pools, and deeper is better for price stability.

The USDC floor is the higher of the two on purpose: USDC carries customer purchases,
cross-merchant routing and merchant cash-out, while the ETH pool is the speculative venue.

**You no longer have to hand-match the two prices.** The launch token split used to be a
fixed 1.8M/1.2M, which meant any seed ratio other than exactly 1.5:1 opened the two pools
at different prices and handed the first trader free money. The factory now derives the
split from the USD value seeded into each pool, so both open at:

```
price per token = (usdcSeedUsd + ethSeedUsd) / 3,000,000
```

ETH is valued through a Chainlink ETH/USD feed. `deploy()` reverts if that feed is more
than **one hour** stale, so do not sit on a prepared transaction.

## Step 4 — Set reward bounds

| Field | Rule |
|---|---|
| `perTxFloor` | `> 0` and `<= DAILY_CAP`. Usually the token equivalent of ~$0.01 at launch price |
| `perTxMax` | `>= perTxFloor` and `<= DAILY_CAP` |

`perTxMax` is the one reward parameter the merchant can tune later via
`RewardEscrow.setPerTxMax()`. `perTxFloor` is fixed at deploy.

## Step 5 — Approve and deploy

**The merchant approves, PunchCard deploys.** `deploy()` pulls USDC from `ownerWallet`, not
from whoever sends the transaction, so the approval must come from the merchant's own
wallet. `deploy()` is `onlyDeployer`, so these are necessarily two different accounts and
two separate transactions.

**1. Merchant approves, from their own wallet, the exact amount:**

```bash
cast send $USDC "approve(address,uint256)" $TOKEN_FACTORY $USDC_SEED \
  --rpc-url $RPC --account merchant-wallet
```

Exact amount, immediately before the deploy. Never leave a standing allowance — `deploy()`
pulls from `ownerWallet`, so a lingering approval could be consumed by anyone able to call
the factory, with their own parameters, and the merchant would fund a suite they do not
control.

**2. PunchCard deploys:**

```bash
forge script script/DeployMerchant.s.sol:DeployMerchant \
  --rpc-url $RPC --broadcast --account punchcard-deployer
```

The script checks the merchant's allowance first and stops with a clear message if it is
missing, rather than failing deep inside the factory.

> **Testing only.** If you are deliberately broadcasting *as* `ownerWallet` — a local fork
> or a testnet where one wallet plays every role — set `MERCHANT_SELF_APPROVE=true` and the
> script will approve for you. The script does not try to detect this: `msg.sender` in a
> forge script is not reliably the broadcast signer before `vm.startBroadcast()`, so intent
> is declared rather than guessed. Get it wrong and the deploy reverts immediately on
> `transferFrom`, which is the failure mode you want.

`deploy()` is `onlyDeployer` — the merchant does not call it. It runs the entire sequence
in one transaction: mint, distribute 45/30/15/10 to the four contracts, create both pools,
mint both LP positions into the LPLocker, move the 27M reserve, register the suite with the
WindDownController, and emit `MerchantDeployed`.

## Step 6 — Verify and record

- [ ] Verify token + all five suite contracts on Basescan
- [ ] Confirm balances: escrow 45M, LP 30M (3M in positions, 27M reserve), vesting 15M, treasury 10M
- [ ] Confirm both pools quote the **same** price — they are derived to match, so a
      discrepancy means something is wrong
- [ ] Confirm `WindDownController.isRegistered(token) == true`
- [ ] Confirm both pools quote a sane price in each direction
- [ ] Save every address into the merchant's JSON file and commit it
- [ ] Confirm `ownerWallet` received **no merchant tokens** — only unused USDC/WETH comes
      back. Merchant-token dust stays locked in the LPLocker as reserve; any arriving at
      the merchant means allocation escaped the locked 30%

## Step 7 — Wire up the merchant

- [ ] POS signs reward distributions as `operator`
- [ ] Customer dapp reads the token via the factory's `MerchantDeployed` event
- [ ] Owner dashboard points at the escrow, treasury and LP locker
- [ ] Merchant briefed on: the 90-day treasury delay, the 30-day team cliff, and what
      wind-down means

---

# Part 3 — The pSKOOP pilot (once, and never again)

pSKOOP deploys through `StagedTokenFactoryPilot`, whose lockers have an LP hatch that
**never closes by itself**. No merchant may use this path. See `docs/staged-rollout.md`.

Use **`DeployNetworkStagedPilot.s.sol`**. It is a separate script rather than a flag on
`DeployNetworkStaged`, because the runbook used to say "substitute the pilot contracts" —
meaning hand-edit a deploy script on launch day, which is worse than a configuration flag
rather than better. It takes `PC_PILOT_LINEAGE=true` on top of `PC_CREATE_NEW_NETWORK=true`,
and `DeploymentInvariants.t.sol` asserts that the ordinary staged script can never reach the
pilot lineage.

## No authorisation step for the first network

`DeployNetworkStaged` constructs the `WindDownController` with the staged factory already
authorised, so the pSKOOP pilot network needs **no** `proposeFactory` / `executeFactory` at
all. That removes two 48-hour waits from the critical path.

The timelocked pair below applies only when adding a **later** factory to the controller
pSKOOP created — a production factory at Stage 2, for instance. Keep it for that.

Two things that do not change:

- **Do not deploy a second controller** once pSKOOP exists. A controller is the network.
- **Do not reuse the micro rehearsal controller** at
  `0x54BeC817f99f1a477944e84688bCeBEAF92175E7`. Registration is permanent; anything put
  there is stuck there.

## The 48-hour clock, for later factories only

`proposeFactory` / `executeFactory` are both multisig, with `FACTORY_TIMELOCK = 48 hours`
between them, and that applies to **authorising and to disabling**. None of it is needed for
the first staged network — see above — but it is exactly what a later factory costs, in both
directions. Plan the calendar before the day.

```
later, for a Stage 2 production factory added to the pSKOOP controller:

day 0   multisig: proposeFactory(stagedProductionFactory, true)
day 2   multisig: executeFactory(stagedProductionFactory)     ← path opens
```

- [ ] **Disabling does not orphan anyone.** `executeFactory(addr, false)` stops a factory
      registering *new* merchants. Merchants it already registered keep working, keep
      routing, and keep whatever hatch they have.
- [ ] **Neither direction touches an existing merchant's LP.** Only `lockLP()` locks a
      pilot hatch, and only when you decide.

## The pSKOOP launch sequence

No timelock anywhere in it. `DeployNetworkStaged` creates the controller with the staged
factory already authorised, so this is a single sitting.

```
1  DeployNetworkStagedPilot.s.sol   PC_CREATE_NEW_NETWORK=true PC_PILOT_LINEAGE=true
                                    -> controller, StagedTokenFactoryPilot, router
2  StageMerchant  PC_STAGE=1        stage the suite; nothing is live
3  merchant       approve USDC      from the OWNER wallet, to the factory
4  StageMerchant  PC_STAGE=2        pools created, LP minted, held by the factory
5  -- inspect everything --         allocations, pool prices, positions, wallets
6  StageMerchant  PC_STAGE=3        activate: LP to the locker, clocks start, registered
7  fill pilot-skoop config          controller, router, token, escrow, pools
8  confirm the page reads           "pSKOOP liquidity is not permanently locked."
9  later, when proven               lockLP() from the owner wallet
```

Step 5 is the one that staging exists for, and the only one with no transaction in it. If
something is wrong, `PC_STAGE=0` aborts and returns the seed; after step 6 there is no undo.

## The pilot token is `pSKOOP`, not `SKOOP`

Decided 2026-09-15. The live 2023 SKOOP keeps running, so both exist on Base at once and
every surface has to say which one it means. `SKOOP2` reads as a migration token; `pSKOOP`
reads as a pilot, which is what it is.

- [ ] Deploy with name `KOKOS SKOOPS Pilot`, symbol `pSKOOP`
- [ ] Launchpad slug `pilot-skoop`, `brand.shortName` = `pSKOOP`
- [ ] **The two pages still share artwork.** `merchants/pilot-skoop/assets/` is a copy of
      KOKOS's icon and logo, so an installed PWA looks the same on a home screen. The symbol
      and app title differ; the images do not. Supply pilot artwork before announcing, or
      accept that the two are told apart by text alone.
- [ ] Graduation is a later decision — keep `pSKOOP`, or redeploy as `SKOOP` once the live
      one is retired. Do not decide it now; ambiguity during testing is the thing being
      avoided.

## Basescan verification

A token customers hold should be readable. Verification is also where a launch quietly goes
wrong months later, so the commands live here rather than in somebody's history.

**Prerequisite:** a free Basescan API key, exported as `BASESCAN_API_KEY`. Nothing else —
verification needs no private key and deploys nothing.

### The five network contracts: verify at deploy time

`forge script` verifies as it broadcasts, using the arguments it just passed. Add `--verify`
to the deploy command and there is nothing to reconstruct:

```bash
forge script script/DeployNetworkStagedPilot.s.sol \
  --rpc-url https://mainnet.base.org --broadcast --verify
```

That covers `SuiteDeployer`, `LockerDeployerPilot`, `WindDownController`,
`StagedTokenFactoryPilot` and `PunchCardRouter`.

- [ ] Use `--verify` on the deploy. Retrofitting it afterwards means retyping twelve
      constructor arguments for the factory alone.

### The five merchant contracts: generated, never retyped

`stageSuite` builds the token, escrow, vesting, treasury and locker from the factory's own
constants and immutables. **Nobody typed those arguments, so nobody can retype them.**

```bash
PC_FACTORY=0x… PC_TOKEN=0x… \
  forge script script/VerifyMerchant.s.sol --rpc-url https://mainnet.base.org
```

Read-only. It prints five ready-to-paste `forge verify-contract` commands with
`--constructor-args` already ABI-encoded, reading every value off the chain — including
which locker lineage the factory produced, since production, beta and pilot are three
different contract paths.

- [ ] Run it and paste the commands. Do not assemble them by hand.

> **Why reading beats retyping, demonstrated.** Run against the 2026-09-15 rehearsal
> merchant, the generator emits a 180-day cliff and a 1080-day duration — because that
> factory was deployed before the schedule changed to 30 / 730. Anyone retyping from the
> current source would supply the new values, and the verification would fail without
> explaining why. The generator reads the deployment; the source describes the next one.

### Compiler settings must match the deployment

`foundry.toml` pins `via_ir = true` and `optimizer_runs = 200`, and verification reproduces
bytecode with whatever the working tree says. Verifying an old deployment from a tree whose
settings have moved produces a mismatch with an unhelpful error.

- [ ] Verify from the commit that deployed, not from `main`, if they have diverged.

## Wallets — all fresh, none shared with KOKOS's existing deployment

Decided 2026-09-15. The pilot reuses nothing. No script is ever handed authority over a
contract or position KOKOS already has.

- [ ] PunchCard multisig
- [ ] PunchCard deployer (the only caller of `deploy()`)
- [ ] PunchCard fee recipient
- [ ] KOKOS owner wallet — receives treasury releases, and **is the only wallet that can
      call `evacuateLP()` or `lockLP()`**. Hardware wallet.
- [ ] KOKOS team wallet — receives vesting. Hardware wallet, verified on-chain.
- [ ] KOKOS POS / operator wallet — the kiosk key, rotatable via `addOperator` /
      `removeOperator`, so it does not need to be a hardware wallet
- [ ] A couple of throwaway wallets for a test reward and a test swap

The owner wallet is the one to be careful about. For as long as the pilot hatch is open it
can move the entire pool, which is the point of the pilot and also its largest custody risk.

## Moving the old SKOOP LP — by hand, and not on the launch's critical path

Not a script and not a deploy step. Do it on its own schedule, after the new token is live
and tradeable, so the gap where a holder can see a drained pool and nothing else is as short
as possible.

- [ ] Announce first. Pulling the LP makes old SKOOP untradeable and a holder who finds a
      drained pool with no announcement assumes the worst, whatever the intent.
- [ ] Watch it on a fork before doing it live:
      `PC_SKOOP_LP_OWNER=0x… forge test --match-test test_phase1 --fork-url … -vv`
      That is a dry run for a human, not a gate — it shows exactly what `decreaseLiquidity`
      and `collect` do to those positions.
- [ ] Remove liquidity per position through the Uniswap UI, collecting fees in the same step.
- [ ] The recovered capital is **not** needed to fund the pilot. It is yours to redeploy,
      hold, or use for holder distribution.

## While the hatch is open

- [ ] The dapp shows *"pSKOOP liquidity is not permanently locked"* on the Swap screen.
      No "yet" — the pilot hatch has no expiry and may never be closed.
      Confirm it renders **before** announcing the pilot — `lpLockState()` reads the locker
      directly, so a misconfigured `windDownController` shows "status unavailable" rather
      than a false lock claim, but unavailable is not the message you want on day one.
- [ ] No PunchCard surface says SKOOP's liquidity is locked. Not the site, not the deck,
      not a reply to a holder. It is not locked and there is no date on which it becomes
      locked.
- [ ] Re-check the ETH floor if the gap between pulling the old LP and deploying runs long.
      The floor is USD-denominated against the Chainlink feed, so 0.762 WETH clears $1,000
      only above roughly $1,312/ETH. `deploy()` reverts rather than underfunding, so the
      failure is safe — just badly timed.

## Closing it

- [ ] `lockLP()` is one-way. Callable by the owner wallet in practice: it also names the
      controller, but no function on `WindDownController` ever calls it and the locker's
      controller address is immutable, so that path is unreachable.
- [ ] **Do not call it for SKOOP unless you are giving up migration forever.** Decided
      2026-09-15: SKOOP keeps permanent recoverability as the first-party network merchant.
      Future merchants get beta's self-closing window, then production's absence of one.
- [ ] Confirm the dapp flips to *"pSKOOP liquidity is permanently locked."* That sentence is
      a claim; it may only appear once the contract says so.
- [ ] Only then may the strong liquidity language be used anywhere else.

---

## Pre-flight checklist

- [ ] `teamWallet` is a hardware wallet, verified on-chain
- [ ] `ownerWallet` and `operator` verified on-chain
- [ ] IPFS metadata pinned and reachable
- [ ] USDC approval granted for exactly `usdcPairAmount`
- [ ] Deployer wallet funded with `ethPairAmount` + gas
- [ ] Agreed who is funding the seed — merchant, investor, or PunchCard
- [ ] Both seeds clear their minimums ($2,000 USDC / $1,000 ETH)
- [ ] Chainlink feed is live and fresh — `deploy()` reverts on an answer over an hour old
- [ ] `perTxFloor` / `perTxMax` inside `DAILY_CAP`
- [ ] Merchant JSON committed to `deploy/merchants/`
- [ ] Factory is the intended lineage — `HAS_UNLIMITED_LP_RECOVERY()` must **revert**
      for any merchant deployment. It answers only on `StagedTokenFactoryPilot`, which is
      for pSKOOP alone.
