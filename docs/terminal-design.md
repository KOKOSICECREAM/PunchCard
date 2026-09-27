# PunchCard Terminal — design

Drafted 2026-09-26. Supersedes "PunchCard Terminal — the payment surface, deliberately out of
scope" in `ROADMAP.md` as the plan; that section's caution still stands: this is the contract
that holds customer money, so it is built after SKOOP is registered, not alongside it.

## The goal

A merchant configures a till with **one on-chain value — their token address** — plus the
things that are genuinely theirs (menu, tax rate, store name). Everything else the POS needs is
read from the chain. The customer app is a PunchCard wallet, not a merchant app: it shows every
network token the customer holds, where each can be spent, and swaps any one for any other.

The logic is KOKOS's working payment system — signed checkout, refund window, settlement —
generalised into one blueprint and hardened where production showed the gaps.

## What already exists and is reused

| Need | Where it comes from |
|---|---|
| Is this token on the network? | `WindDownController.isRegistered(token)` |
| List every merchant | `SuiteRegistered` / `ManualSuiteRegistered` events on the controller |
| The merchant's escrow, locker | `WindDownController.getSuite(token)` |
| Pools and fee tiers | `LPLocker.usdcFeeTier()` / `ethFeeTier()` → Uniswap factory `getPool` |
| Name, symbol, decimals | the ERC-20 itself |
| Logo, description | metadata file whose CID hash is `MerchantToken.ipfsHash` — see *Directory* |
| Cross-merchant swaps | `PunchCardRouter` |
| Reward limits | `RewardEscrow` drawers and emission — enforced on-chain |

## Contracts (new)

### `TerminalFactory` — one per network

- `createTerminal(token)`: requires `controller.isRegistered(token)`; deploys a
  `PunchCardTerminal` for it; records `terminalOf[token]`. One terminal per token.
- The terminal's owner is **read from the suite** (`RewardEscrow(suite.rewardEscrow).ownerWallet()`),
  so creating one needs no input but the token. Anyone may call it — it only ever creates the
  terminal the merchant's own suite implies.
- The POS and the dapp find a merchant's terminal here. (`WindDownSuite` has no terminal slot
  and the deployed controller cannot gain one, so this mapping is the registry.)

### `PunchCardTerminal` — one per merchant, identical bytecode apart from immutables

Accepts payment in **the merchant's token** or **USDC**. Nothing else.

**Checkout**
- The till signs a checkout intent: receipt id, order id, token, amount, USD totals, item count,
  cart hash, deadline, **reward amount**. Signed as **EIP-712** with the domain bound to the chain
  and the terminal's address — the KOKOS digest bound to neither, so an intent signed for one
  escrow was valid on another.
- `pay(intent, signature)`: the customer's own transaction. Checks the signer is an authorised till,
  the deadline, one-time receipt and order ids; pulls the funds into the terminal; records the
  receipt; emits the redemption event the network's measurement needs (`PaymentCaptured`,
  keeping KOKOS's fields).
- **Reward in the same transaction.** The terminal is an operator on the merchant's `RewardEscrow`
  and calls `distributeReward(payer, intent.rewardAmount)`. The escrow's drawer and emission limits
  apply unchanged. If either refuses, the payment still succeeds and the terminal emits
  `RewardDeferred(receipt, payer, amount)`; the till queues it exactly as the KOKOS pending list
  does today. No till polls for payments or holds a token float.

**Refund window** — owner-set within fixed bounds (KOKOS: 1–7 days). Inside it the owner can void:
funds return to the payer.

**Settlement — follows the tokenomics.** After the window, **anyone** may settle a receipt:
- Merchant-token payment → **burned**.
- USDC payment → **buys the merchant's token in its own USDC pool, and the tokens bought are
  burned.** The merchant does not keep the USDC; it becomes buy pressure and burn. The buy pays
  the pool's fee, whose USDC side is PunchCard's network fee via the locker — commerce earns the
  network from merchant #1, as the README intends.
- Token settlement is price-free, so it is open to anyone. USDC settlement is a swap into a thin
  pool, so it needs a slippage floor: it takes a caller-supplied minimum (quoted off-chain, as the
  Reporting page now does) and settles in batches small enough that impact stays bounded. Whether
  it can safely be fully permissionless is an open question below.

**Owner controls** — add/remove till signers, set the refund window, void inside it. None move
funds anywhere but back to the payer or into the burn.

**Wind-down** — once the controller initiates, the terminal stops taking payments; settlement of
existing receipts continues.

## The POS (one app, every merchant)

Config: **token address**, plus menu, tax rate, store name, terminal id. Derived on load:
terminal, escrow, pools, price (two-pool agreement check, as the KOKOS POS now does), name,
symbol, logo. Till key: signs checkouts and pays cash/card rewards from its own escrow drawer;
holds no merchant token.

## The customer dapp (PunchCard wallet)

- Every network token the wallet holds, with logo, balance and USD value.
- Where each can be spent (directory).
- Swap any token for any other through `PunchCardRouter` (network fee applies).
- Scan a terminal's QR to pay. If the customer does not hold that merchant's token, offer
  **swap-and-pay**: route through the router, then `pay`. (A single-transaction `payWithSwap` on
  the terminal is a later optimisation.)

## Directory

A JSON file served by the network (e.g. `punchcard.club/directory.json`): token → metadata CID,
business name, location, category. The dapp and POS **verify every entry**:
`keccak256(CID) == token.ipfsHash()`. A tampered logo cannot pass; business details, which the
immutable metadata deliberately omits because a shop can move or rename, live only here.

## Defaults taken, to confirm

1. **All** of a USDC payment is bought and burned — the README's rule. KOKOS's current treasury
   sends 40% into its own LP position instead.
2. Rewards are paid inside `pay`, not by the till afterwards.

## Open questions

- Can USDC settlement be permissionless without a trusted floor? A TWAP on a $3k pool is cheap to
  move; a cap per settlement plus a keeper may be the honest answer.
- Should `pay` accept any network token and swap internally, so cross-merchant spending is one
  transaction? Better UX, more surface in the contract that holds money.
- Deployment fee and who pays gas for `createTerminal`.

## Sequencing

SKOOP's suite and registration first — a terminal can only be created for a registered token.
The KOKOS POS keeps running on `KOKOSPaymentEscrowV3` meanwhile. SKOOP is the terminal's first
merchant; its till moves over when the terminal has been rehearsed on a fork and tested live with
small amounts, as the locker was.
