# What beta must measure, and whether the chain can answer it

Events are part of the immutable ABI. Anything not emitted at deploy time can never be
recovered for the merchants deployed then — so this is a pre-deploy checklist, not an
analytics backlog.

## Metric 1 — the network thesis

> Did a reward earned at Merchant A cause activity at Merchant B?

This is the number that decides whether PunchCard is a company or a token deployer. Three
links in the chain:

| Link | Event | Status |
|---|---|---|
| Earned at A | `RewardDistributed(token, operator, recipient, amount, ts)` | **covered** — carries the kiosk and the customer |
| Moved A → B | `Swapped(tokenIn, tokenOut, recipient, …)` | **covered** — `recipient` indexed, so a customer is followable |
| Redeemed at B | — | **NOT COVERED. The POS contract does not exist yet.** |

**The gap is the last link, and it is the one that closes the loop.** Earning and swapping
are observable today; spending is not, because merchant redemption is still KOKOS's bespoke
POS escrow and PunchCard has no payment contract of its own (Phase 2).

So this is a hard requirement on Phase 2, recorded here because it will be easy to build a
POS that works perfectly and measures nothing:

- [ ] The POS payment contract MUST emit a redemption event carrying at minimum the
      merchant token, the customer address, and the amount.
- [ ] Without it, "18% of members visited another network merchant" cannot be computed from
      chain data for any merchant deployed before the POS exists.

## Metric 2 — is the ETH pool worth its fragmentation?

> Do WETH routes actually win, get used, and earn enough to justify a second pool per
> merchant?

100 merchants means 200 pools. The floors are already weighted toward USDC; whether the
second pool earns its keep is a measurement, not an argument.

| Question | Source | Status |
|---|---|---|
| Which pool earned more? | `FeesCollected(merchantToken, usdcNetworkFee, wethNetworkFee, …)` | **covered** |
| Did a cross-merchant swap route via WETH or USDC? | `Swapped.feeToken` — the fee is skimmed at the midpoint, so `feeToken` *is* the chosen midpoint | **covered** |
| How often did the app quote WETH as better? | off-chain, in the dapp's quoting | **not instrumented** — the dapp picks the better midpoint client-side and keeps no record |

**Decision rule to set before beta, not after:** if `wethNetworkFee` stays negligible
against `usdcNetworkFee` across real merchants, and WETH rarely wins as a midpoint, the ETH
pool is fragmenting liquidity for nothing and the second pool should be dropped from the
production factory. Write the threshold down before the data arrives, so it is not
rationalised afterwards.

## Fixed before deploy

`FeesCollected` used to carry `usdcToMerchant` and `wethToMerchant` alongside the network
fees — leftovers from the superseded 80/20 LP fee share, hardcoded to zero at the only call
site. Two dead fields, and names implying a merchant split that no longer exists. Anyone
building analytics against the ABI would have read `usdcToMerchant` and concluded the
merchant receives a share. Corrected while the contracts are still changeable.
