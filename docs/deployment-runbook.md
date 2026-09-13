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

**2. TokenFactory**
```
_multisig            — PunchCard multisig
_deployer            — PunchCard deployer hot wallet (the only caller of deploy())
_windDownController  — from step 1
_positionManager     — see deploy/network/base-mainnet.json
_usdc                — see deploy/network/base-mainnet.json
_weth                — see deploy/network/base-mainnet.json
```

**3. PunchCardRouter**
```
_multisig            — PunchCard multisig
_windDownController  — from step 1
_swapRouter          — Uniswap SwapRouter02, see network file
_usdc / _weth        — see network file
_initialFeeRate      — basis points (30 = 0.30%)
_initialFeeRecipient — PunchCard operational wallet
```

Compiler: **0.8.24 or higher**, OpenZeppelin v4.x or v5.x.

After deploying, record every address in `deploy/network/base-mainnet.json` and verify all
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

## Step 3 — Choose pool parameters

The factory seeds **both** a USDC pool and an ETH pool. Both are required — neither amount
may be zero.

| Field | Notes |
|---|---|
| `usdcFeeTier` / `ethFeeTier` | 100 / 500 / 3000 / 10000 |
| `usdcPairAmount` | USDC seeding the USDC pool (6 decimals). Paired with 1,800,000 tokens |
| `ethPairAmount` | ETH seeding the ETH pool (wei). Paired with 1,200,000 tokens. Sent as `msg.value` |

The ratio of pair amount to fixed token count sets the launch price. Work out the implied
price for both pools before deploying and make sure they agree — a mismatch is an instant
arbitrage gift.

## Step 4 — Set reward bounds

| Field | Rule |
|---|---|
| `perTxFloor` | `> 0` and `<= DAILY_CAP`. Usually the token equivalent of ~$0.01 at launch price |
| `perTxMax` | `>= perTxFloor` and `<= DAILY_CAP` |

`perTxMax` is the one reward parameter the merchant can tune later via
`RewardEscrow.setPerTxMax()`. `perTxFloor` is fixed at deploy.

## Step 5 — Approve and deploy

```
ownerWallet  →  approve(TokenFactory, usdcPairAmount)      # USDC
deployer     →  TokenFactory.deploy(params)                # msg.value == ethPairAmount
```

`deploy()` is `onlyDeployer` — the merchant does not call it. It runs the entire sequence
in one transaction: mint, distribute 45/30/15/10 to the four contracts, create both pools,
mint both LP positions into the LPLocker, move the 27M reserve, register the suite with the
WindDownController, and emit `MerchantDeployed`.

## Step 6 — Verify and record

- [ ] Verify token + all five suite contracts on Basescan
- [ ] Confirm balances: escrow 45M, LP 30M (3M in positions, 27M reserve), vesting 15M, treasury 10M
- [ ] Confirm `WindDownController.isRegistered(token) == true`
- [ ] Confirm both pools quote a sane price in each direction
- [ ] Save every address into the merchant's JSON file and commit it
- [ ] Confirm any LP dust was returned to `ownerWallet`

## Step 7 — Wire up the merchant

- [ ] POS signs reward distributions as `operator`
- [ ] Customer dapp reads the token via the factory's `MerchantDeployed` event
- [ ] Owner dashboard points at the escrow, treasury and LP locker
- [ ] Merchant briefed on: the 90-day treasury delay, the 180-day team cliff, and what
      wind-down means

---

## Pre-flight checklist

- [ ] `teamWallet` is a hardware wallet, verified on-chain
- [ ] `ownerWallet` and `operator` verified on-chain
- [ ] IPFS metadata pinned and reachable
- [ ] USDC approval granted for exactly `usdcPairAmount`
- [ ] Deployer wallet funded with `ethPairAmount` + gas
- [ ] Implied launch price matches between the USDC and ETH pools
- [ ] `perTxFloor` / `perTxMax` inside `DAILY_CAP`
- [ ] Merchant JSON committed to `deploy/merchants/`
