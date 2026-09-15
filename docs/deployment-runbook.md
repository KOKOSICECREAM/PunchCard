# Deployment Runbook

Two distinct procedures. **Network setup** happens once, ever. **Merchant onboarding**
repeats identically for every business that joins.

---

# Part 1 — Network setup (once)

`WindDownController` and `TokenFactory` reference each other, so the order matters.

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
- [ ] Merchant briefed on: the 90-day treasury delay, the 180-day team cliff, and what
      wind-down means

---

# Part 3 — The SKOOP pilot (once, and never again)

KOKOS deploys through `TokenFactoryPilot`, whose lockers have an LP hatch that **never
closes by itself**. No merchant may use this path. See `docs/staged-rollout.md`.

## The 48-hour clock is the whole difficulty

`proposeFactory` / `executeFactory` are both multisig, with `FACTORY_TIMELOCK = 48 hours`
between them. That applies to **authorising and to disabling**, so the pilot factory is
reachable for at least 48 hours after you finish with it. Plan the calendar first; the
sequence below has two unavoidable two-day waits in it.

```
day 0   multisig: proposeFactory(TokenFactoryPilot, true)
day 2   multisig: executeFactory(TokenFactoryPilot)          ← path opens
day 2   deployer: TokenFactoryPilot.deploy(SKOOP)            ← do this the same day
day 2   multisig: proposeFactory(TokenFactoryPilot, false)   ← immediately, same session
day 4   multisig: executeFactory(TokenFactoryPilot)          ← path closes
later   owner:    LPLockerPilot.lockLP()                     ← when the pilot is proven
```

- [ ] **Deploy and propose-disable in the same session.** The gap between the path opening
      and the disable proposal is the only window in which a second pilot merchant could be
      created. Make it minutes, not days. Nothing enforces this — it is a habit, which is
      why it is written down.
- [ ] **Disabling does not orphan SKOOP.** `executeFactory(addr, false)` stops the factory
      registering *new* merchants. SKOOP keeps working, keeps routing, keeps its hatch.
- [ ] **The hatch is unaffected by any of this.** Disabling the factory does not lock the
      LP. Only `lockLP()` does, and only when you decide.

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

- [ ] The dapp shows *"SKOOP pilot liquidity is currently recoverable"* on the Swap screen.
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

- [ ] `lockLP()` is one-way and callable by the owner wallet or the controller. After it,
      `LPLockerPilot` behaves exactly as production does.
- [ ] Confirm the dapp flips to *"SKOOP liquidity is permanently locked."* That sentence is
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
      for any merchant deployment. It answers only on `TokenFactoryPilot`, which is
      for SKOOP alone.
