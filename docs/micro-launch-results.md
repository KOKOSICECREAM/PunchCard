# Micro-launch results — Base mainnet, 2026-09-15

`docs/micro-launch-runbook.md` has pointed at this file since before there was anything to
put in it. There is now.

> **Status change.** Before this run the staged design was theoretically deployable. After
> it, the full PunchCard loop is proven live on Base — deployment, activation, rewards,
> cross-merchant routing, fee flow and capital recovery — for about the cost of a coffee.

## Two runs, one day

The first run, earlier the same day, is the more valuable one.

| | run 1 | run 2 |
|---|---|---|
| Factory | atomic `TokenFactoryBeta` | `StagedTokenFactoryBeta` |
| Result | **failed** at transaction 6 | 13 of 13 succeeded |
| Error | `gas limit too high` | — |
| Cost | $0.17 | ~$1.20 |

Run 1 deployed a network and then could not deploy a single merchant into it.
`TokenFactory.deploy()` costs 17,325,962 gas and Base refuses any transaction above
**16,777,216** — a chain-level per-transaction cap, identical across every RPC and exactly
2^24. Compiler settings recover 38k of the 549k needed. That finding is what produced
`StagedTokenFactory`, and seventeen cents is what it cost to find before SKOOP existed.

## Deployed — disposable, never reuse

```
windDownController       0xE6345BF9f35E1aF812466401C717ad1CbDa1bAD1
stagedTokenFactoryBeta   0x5fe448c4E445AC0F0Ba4D85E39418737dbA39f4b
punchCardRouter          0x883DB5cEc3b3B4e9a9c9fD256ba5F95cc991E54C
suiteDeployer            0x9f9b4Df4941Aa0AB57c5994EE7DA4dd2D2AF5aef
lockerDeployerBeta       0xE05c25Dc6bBC858Af32DdAc42e8608d6d3F8D065

PCMA   token 0xb005A6e0C68849d42d187303a2A609089CCBcdC9
       escrow 0xbF5C068B1FE2a813E794C84c536F5d077975e51b
       locker 0x995Bc862968390648Aa5851279e2815604c96081
PCMB   token 0x74f3EAfA1921D41465EbeeD0827439e60Ff0C4B5
       escrow 0xc919bee0A059f417b1F9c74DA87f5947eFb85eb3
       locker 0xF3362c33e1985452dFe331B87E3C0fFA4F107334

wallet A (deployer/multisig/fee recipient) 0x187427810A6e3F86f20bB86386f38DBe553545aB
wallet B (merchant owner/team/operator)    0x7Fe79Bc539d3e8a1B4b14e6788A8D80f3B0510Fd
```

**This controller is not the network.** It has two registered merchants, and
`WindDownController.register()` has no undo — `_registered[token] = true` is set and nothing
anywhere clears it. Anything registered here is stuck here. It stays dead:

- never in `deploy/network/base-mainnet.json`
- never reused for SKOOP or any merchant
- never a `proposeFactory` target

There is also an earlier dead controller at `0x54BeC817f99f1a477944e84688bCeBEAF92175E7`
from run 1, with no merchants at all. Same rule.

## Gas per stage

Every figure is actual usage on Base, not an estimate.

| tx | function | gas | vs 16,777,216 |
|---|---|---|---|
| 0 | `SuiteDeployer` deploy | 4,789,128 | 29% |
| 1 | `LockerDeployerBeta` deploy | 3,132,459 | 19% |
| 2 | `WindDownController` deploy | 1,330,971 | 8% |
| 3 | `StagedTokenFactoryBeta` deploy | 3,548,191 | 21% |
| 4 | `PunchCardRouter` deploy | 1,826,130 | 11% |
| 5 | **`stageSuite`** | **6,676,899** | **40%** |
| 6 | `approve` (merchant) | 55,437 | 0.3% |
| 7 | **`fundAndMintLP`** | **10,520,746** | **63%** |
| 8 | **`activateMerchant`** | **633,074** | **4%** |
| 9–12 | second merchant, same shape | 17,845,430 | — |
| | **total** | **50,358,465** | 0.000252 ETH |

`fundAndMintLP` is the tightest at 63%, with **6.26M of headroom**. The fork predicted it
well: 10,673,916 on a fork against 10,520,746 live, about 1.5% high.

One thing the fork could not show. Forge submits a gas *limit* of roughly 1.46× the
estimate, so `fundAndMintLP` went out with a limit of 15,386,590 — **91.7% of the cap**,
even though it consumed 63%. Actual usage would only need to reach ~11.5M for the submitted
limit to breach the cap and be rejected outright. **Watch the submitted limit, not the
consumption**, and re-read it whenever the seed size or fee tiers change.

## The behaviour proof

All of it on Base mainnet, against live Uniswap. Fee recipient started at 0/0/0/0.

| behaviour | evidence |
|---|---|
| Staged suite is not a merchant | not registered, router refuses, clocks stopped, locker empty |
| Allocations exact at launch | 45M / 15M / 10M / 27M+dust; owner 0; factory 0 |
| **Clocks start at activation** | escrow `emitted` was minutes of emission, not hours |
| Beta hatch runs from activation | deadline = activation + exactly 30.0 days |
| `RewardEscrow` pays from the drawer | 50 PCMA to the merchant wallet |
| Router wraps ETH and buys | 0.0005 ETH → 271,142 PCMA |
| **Cross-merchant swap, two hops** | 100,000 PCMA → 0.000173485 WETH → **105,495.327591 PCMB** |
| Quote matched the fill | to the base unit, across two pools |
| Router fee once, at the midpoint | 0.0000038 WETH |
| LP fees collect | 0.001631 USDC + WETH to the fee recipient |
| PunchCard takes pair assets only | USDC and WETH only |
| **PunchCard holds no merchant token** | PCMA 0, PCMB 0 — and supply fell |
| The merchant-token share is burned | 651.75 PCMA and 110.24 PCMB left circulation |

That last pair is the strongest evidence in the table. `collectFees` burns the
merchant-token portion rather than paying it to PunchCard, so the proof is not an empty
balance — it is a *reduced supply* with an empty balance beside it.

## Recovery

Both lockers evacuated and permanently bricked: `lpPermanentlyLocked true`,
`evacuationOpen false`, `isFrozen true`. Nothing left open, nothing to remember in 30 days.

| | recovered | seeded | |
|---|---|---|---|
| USDC | 10.484793 | 10.000000 | **104.8%** |
| WETH | 0.005251217 | 0.005000000 | **105.0%** |

Above 100% because both swaps pushed pair assets *into* the pools — ETH buying PCMA, then
PCMA routing to PCMB. The evacuation returned the seed plus trading proceeds plus fees.
A merchant whose token is being *sold* into would see the mirror of this and recover less.

```
gas spent       ~$1.20 across 20 transactions
recovered       $23.09 of ~$22 seeded
final           A 0.002832 ETH    B 0.002878 ETH + $10.48 + 0.00525 WETH
```

## Operational findings

**One transaction per paste. Wait for the receipt.** `cast send` does not wait for a
transaction to be mined before building the next, so two commands pasted together are built
against the same nonce and the node rejects one as `replacement transaction underpriced`.
It happened here on `approve` + `swap`: the approve won and the swap never reached the
chain, which is the harmless ordering. **The other ordering is not harmless** — a swap that
lands while its approval is silently dropped fails at `transferFrom`, and a stage 2 that
lands while the merchant's approval is dropped fails the same way, mid-launch.

**The dry-run writes a handoff file indistinguishable from a live one.** `StageMerchant`
records stage 1's addresses in `deploy/staged/<chainid>-latest.json`, and a fork run
produces one stamped `chainId: 8453` with real-looking addresses that exist only in a forked
EVM. Gitignored for that reason; `deploy/network/*.json` remains the authoritative record.

**`getPoolFeeTiers` gave a bare revert for unregistered tokens**, which the dapp calls
*before* quoting. Fixed before this run — it now gives `"Token not on network"`, matching the
swap path. Staging makes the unregistered-but-real state ordinary rather than exotic, so
this would have surfaced during every SKOOP inspection window.

## Conclusion

**The staged path is operationally viable.** The complexity that looked alarming in the
abstract turned out to be manageable in practice: four transactions per merchant, one status
field, one enum, and a script that takes `PC_STAGE=1|2|3`. The only friction in the whole run
was nonce sequencing, which is a paste habit rather than an architecture problem.

**Decision, 2026-09-15: keep the staged path for SKOOP.** The clean-launchpad idea remains
valid as a future simplified product, but there is no case for pivoting before SKOOP when
the staged path has just proven itself on mainnet.

It is also worth stating plainly that Base removed the alternative. Any design that deploys
five contracts and opens two Uniswap pools exceeds 16,777,216 gas in one transaction. The
choice was never atomic versus staged — it was **staged with protocol guarantees, or staged
with fewer**.
