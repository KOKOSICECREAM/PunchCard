# Micro-launch runbook — Base mainnet rehearsal

**Status: not yet run.** This is the script for a deliberately tiny live rehearsal on Base
mainnet, roughly $20 of seed across two merchants, using controlled wallets.

## What this is, and what it is not

**It is** a rehearsal of the machine against real contracts, real pools, real wallets, real
RPCs and the real dapp. It answers: does the deploy choreography work outside a fork, what
does it actually cost, do quotes match fills, and where does the customer flow snag.

**It is not** a merchant launch, and it is not economic validation. There are no customers
and no demand, so it teaches nothing about emission rate, drawer size, reward value or
merchant incentives — those need a real merchant with real foot traffic, which is a
separate decision. Do not let this rehearsal be cited later as evidence for any economic
constant.

> Keep the two doors distinct. "Small live test" and "real merchant launch" are different
> decisions with different risk, and the first quietly becoming the second is the failure
> mode to guard against.

### Everything deployed here is disposable

Seed floors are **immutable constructor arguments**. A factory built with $5 floors can
never become the production factory, and because `PunchCardRouter` binds to that factory's
`WindDownController`, the router is disposable with it.

So this leaves a dead `SuiteDeployer`, `LockerDeployer`, `WindDownController`,
`TokenFactory`, `PunchCardRouter` and two merchant suites on Base mainnet **permanently**.
That is fine — it is the cost of the rehearsal — but it is a loaded gun. Someone reading
the deploy record later must not point a real merchant at a factory with $5 floors.

- [ ] Record every rehearsal address in `deploy/network/base-mainnet-rehearsal.json`,
      **never** in `base-mainnet.json`
- [ ] First key in that file is `"_WARNING": "REHEARSAL ONLY — $5 seed floors. Never
      deploy a merchant against these addresses."`
- [ ] Do this in the **same commit** that records the addresses, not afterwards

### What this rehearsal does NOT exercise

State it plainly so it is not later assumed covered.

| Not covered | Why |
|---|---|
| Multisig flows | `PC_MULTISIG` will be an EOA. Wind-down initiation and the 48-hour param timelock go untested |
| Production seed floors | $5/$5, not $2,000/$1,000 |
| Wind-down completion | 365-day clock; cannot be reached |
| Real demand | No customers. See above |
| Contract verification | Deliberately unverified — keeping this quiet |

---

## Pre-flight

### Wallets

| Role | Env | Notes |
|---|---|---|
| Deployer (hot) | `PC_DEPLOYER` | Broadcasts everything. The only caller of `deploy()` |
| Multisig | `PC_MULTISIG` | EOA for the rehearsal. Record that it is not a multisig |
| Fee recipient | `PC_FEE_RECIPIENT` | Where the network fee and router skim land. **Use a distinct address** so fee arrival is unambiguous |
| Merchant owner | `MERCHANT_OWNER` | Holds and approves the USDC seed |
| Merchant team | `MERCHANT_TEAM` | Immutable forever, even here |
| Operator | `MERCHANT_OPERATOR` | Kiosk signer |

`PC_FEE_RECIPIENT` must not equal the deployer. If it does, fee arrival is indistinguishable
from gas refunds and change, and step 7 proves nothing.

### Funding

Two merchants at $5 USDC + $5 ETH each, plus gas.

```
needed:  ~20 USDC   (10 seed + headroom)
         ~0.01 ETH  (0.008 seed + gas + margin)
```

Measured: the merchant deploy is **~20M gas**, about **$0.30** of L2 execution at 0.006 gwei.
Gas is not the constraint; the seed is. Check the deploy wallet before starting:

```bash
cast balance $PC_DEPLOYER --rpc-url https://mainnet.base.org --ether
cast call $PC_USDC 'balanceOf(address)(uint256)' $MERCHANT_OWNER --rpc-url https://mainnet.base.org
```

### Abort conditions

Stop and diagnose rather than pushing through:

- Any address in step 2 has no code, or its identity check disagrees
- The predicted factory address does not match the deployed one
- The Chainlink feed is more than an hour stale (`deploy()` reverts anyway — do not sit on
  a prepared transaction)
- A pool initialises at a price that disagrees with the seeded USD value
- Fees do not arrive at `PC_FEE_RECIPIENT` in step 7

---

## Step 1 — Deploy the network

Every value below comes from `deploy/network/base-mainnet.json` **except the two seed
floors**, which are deliberately tiny for the rehearsal.

```bash
export PC_POSITION_MANAGER=0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1
export PC_SWAP_ROUTER=0x2626664c2603336E57B271c5C0b26F421741e481
export PC_USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
export PC_WETH=0x4200000000000000000000000000000000000006
export PC_ETH_USD_FEED=0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70
export PC_ROUTER_FEE_BPS=30

export PC_MIN_USDC_SEED_USD=500000000   # $5 — REHEARSAL ONLY (8 decimals)
export PC_MIN_ETH_SEED_USD=500000000    # $5 — REHEARSAL ONLY (8 decimals)

export PC_MULTISIG=<eoa>
export PC_DEPLOYER=<hot wallet>
export PC_FEE_RECIPIENT=<distinct address>

forge script script/DeployNetwork.s.sol \
  --rpc-url https://mainnet.base.org \
  --account pc-testnet \
  --broadcast
```

> The floors are 8-decimal, matching the Chainlink feed. `500000000` is $5. Writing plain
> dollars here sets the floor to a fraction of a cent — that exact bug was shipped in
> `base-mainnet.json` and caught only by a units audit.

Do **not** pass `--verify`.

## Step 2 — Verify every deployed address on-chain

The script fails loudly on empty code, but confirm identity, not just existence. One
character wrong in a position manager address once pointed at an address with no code.

```bash
for a in $SUITE_DEPLOYER $LOCKER_DEPLOYER $WIND_DOWN $FACTORY $ROUTER; do
  echo "$a -> $(cast codesize $a --rpc-url https://mainnet.base.org) bytes"
done

# identity, not just presence
cast call $FACTORY 'MIN_USDC_SEED_USD()(uint256)' --rpc-url https://mainnet.base.org   # 500000000
cast call $FACTORY 'MIN_ETH_SEED_USD()(uint256)'  --rpc-url https://mainnet.base.org   # 500000000
cast call $ROUTER  'feeRate()(uint256)'           --rpc-url https://mainnet.base.org   # 30
cast call $ROUTER  'windDownController()(address)' --rpc-url https://mainnet.base.org  # == $WIND_DOWN
```

- [ ] Factory floors read back as `500000000`, proving the units went in correctly
- [ ] Router's controller matches the deployed controller
- [ ] Addresses recorded in `base-mainnet-rehearsal.json` with the warning key

## Step 3 — Deploy merchant A

```bash
export PC_FACTORY=<factory from step 1>
export MERCHANT_NAME="PunchCard Micro A"
export MERCHANT_SYMBOL="PCMA"
export MERCHANT_IPFS=<pinned hash>
export MERCHANT_OWNER=<owner>
export MERCHANT_TEAM=<team>
export MERCHANT_OPERATOR=<operator>
export MERCHANT_USDC_SEED=5000000        # $5, 6dp
export MERCHANT_ETH_SEED=2000000000000000 # 0.002 ETH, ~$5
export MERCHANT_PER_TX_FLOOR=1000000
export MERCHANT_PER_TX_MAX=20000000

forge script script/DeployMerchant.s.sol \
  --rpc-url https://mainnet.base.org --account pc-testnet --broadcast
```

`ownerWallet` must have approved the factory for `MERCHANT_USDC_SEED`. If you are
deliberately broadcasting **as** the owner, set `MERCHANT_SELF_APPROVE=true` — the script
refuses otherwise, because a fork test once passed only because the owner happened to be
the broadcaster, masking a real approval bug.

- [ ] `MerchantDeployed` emitted; token, escrow, vesting, treasury, locker recorded
- [ ] Allocations exact: 45M escrow, 15M vesting, 10M treasury
- [ ] Factory drained: zero token balance, zero USDC balance
- [ ] Locker holds **at least** 27M (merchant-token dust sweeps in, so it reads slightly above)
- [ ] Both pools initialised, and both imply the **same** price

## Step 4 — Deploy merchant B

Same as step 3 with `PCMB`. **Not optional.** Cross-merchant routing is the least-proven
path in the system and carries the most novel code — the off-chain dual-midpoint quoting
has never run against a real pool. A single-merchant rehearsal skips exactly the part most
likely to be wrong.

## Step 5 — Exercise the machine

Record gas, price and outcome for each. Small amounts throughout.

- [ ] **1. Issue a reward** — operator draws from escrow to a customer wallet
- [ ] **2. Buy A with USDC** — through `PunchCardRouter`, not Uniswap directly
- [ ] **3. Buy A with native ETH** — one transaction, `msg.value == amountIn`. Confirm no
      wrap step and nothing stranded: `cast balance $ROUTER` reads 0
- [ ] **4. Sell A for USDC** — fee taken from output, post-fee minimum holds
- [ ] **5. Cross-merchant A → B** — confirm the chosen `midToken` matches what the dapp
      quoted, and that the fee was skimmed once at the midpoint
- [ ] **6. Quote vs fill** — for each, compare the dapp's displayed output to the actual
      received amount. This is the single most valuable number the rehearsal produces
- [ ] **7. Drawer limit** — attempt a draw above the daily allowance; confirm it reverts
- [ ] **8. Wind-down disclosure** — cannot be triggered without initiating wind-down on a
      throwaway merchant. If you do, note it is irreversible for that suite

## Step 6 — Collect fees and verify destination

```bash
cast send $LOCKER_A 'collectFees()' --rpc-url https://mainnet.base.org --account pc-testnet
```

`collectFees()` is permissionless by design — anyone can call it, and funds go to the
hardcoded recipients regardless.

- [ ] USDC and WETH arrived at `PC_FEE_RECIPIENT`
- [ ] Merchant-token side was **burned**, not transferred — total supply decreased
- [ ] Amounts are non-zero. If zero, the swaps in step 5 did not route through the pools
      the locker holds, which is itself the finding

## Step 7 — Both dapp modes

- [ ] KOKOS build renders and behaves unchanged (`uniswap` mode, zero partner tokens)
- [ ] A `punchcard`-mode build against merchant A quotes, swaps and shows partner B
- [ ] **Hosting gap:** `dist/` deploys nowhere. Localhost against mainnet covers quoting
      and swapping, but **not** wallet deep-links — Base App only routes through
      `go.cb-w.com/dapp?cb_url=` with a real https origin, so the mobile install-and-pay
      flow cannot be rehearsed until there is somewhere to serve it. Decide before step 7
      whether to stand up a throwaway origin or accept the gap and record it

## Step 8 — Write down what happened

In `docs/micro-launch-results.md`, while it is fresh:

- Actual gas and dollar cost per step
- Quote vs fill for every swap, with the delta
- Every UX snag, however small
- Anything that surprised you — that list is the real output of this exercise
- What remains unrehearsed, restated from the table above

---

## After

- [ ] Rehearsal addresses recorded with the `_WARNING` key, in their own file
- [ ] `ROADMAP.md` updated: what the rehearsal proved, and what it explicitly did not
- [ ] No rehearsal address copied into `base-mainnet.json`, the launchpad, or any merchant
      config
- [ ] Decide separately, and later, whether to open the other door
