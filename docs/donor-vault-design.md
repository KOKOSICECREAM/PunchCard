# SkoopDonorVault — design

Status: **design only.** Nothing is written, nothing is deployed, and no donation is
accepted until the rehearsals at the end of this document have passed.

The donor terms in `docs/SKOOP-Launch-Donations.pdf` promise an on-chain claim. This is the
contract that makes that true. It is the hardest piece of the launch: `LPLockerPilot` holds
liquidity for one owner, and this holds it for many, with a schedule and a fee split.

---

## What it has to do

Per `$1,000` donated, at launch price:

| | |
|---|---|
| `$250` of SKOOP | releases a thirtieth a day, days 1–30 |
| `$750` liquidity share | held 20 days, then a tenth a day, days 21–30 |
| trading fees | payable during the hold, not only at the end |

Two Uniswap v3 positions, one per pool. Donors hold claims, not NFTs.

---

## Why a single share number is enough

Every donation splits the same way — the same fraction to the USDC pool and the ETH pool,
at the same price. So **every donor has the same ratio between their two pool positions**,
and one number describes a donor's stake in both:

```
shares[donor]  /  totalShares
```

That collapses what looks like two independent accounting problems into one. A donor's
liquidity in each position is derived once, at seal time, and then fixed:

```
donorUsdcLiq = seededUsdcLiq * shares[donor] / totalShares
donorEthLiq  = seededEthLiq  * shares[donor] / totalShares
```

**Fixed, not recomputed.** If claims were computed against *current* position liquidity,
every withdrawal would change the denominator for everyone still holding, and the last
donor out would be entitled to a share of a position that earlier donors had already
drained. Snapshot at seal, then arithmetic that cannot drift.

---

## Fees: collect before you withdraw

The subtle one. In Uniswap v3, `decreaseLiquidity` does not pay out — it adds the released
principal to the position's `tokensOwed`, and `collect` sweeps `tokensOwed` **in full**,
fees included. So a naive claim pays the claiming donor every fee the whole position has
earned since the last sweep.

The fix is ordering, inside one transaction:

```
1. collect()                     → sweep outstanding fees, credit them to ALL donors
2. decreaseLiquidity(donorSlice) → tokensOwed now holds principal only
3. collect()                     → returns exactly that principal
4. transfer to the donor
```

Step 1 zeroes `tokensOwed`, so step 3 cannot over-pay. `LPLocker.release()` gets away
without this because everything it collects goes to one address; here it would be a
donor-on-donor theft.

Fees are credited with the standard accumulator, scaled by `1e18`:

```
accFeePerShare += collected * 1e18 / totalShares

pending(donor) = shares[donor] * (accFeePerShare - feeDebt[donor]) / 1e18
```

`feeDebt` is set on entry and reset on every settlement. This is what makes staggered exits
correct: a donor who leaves on day 21 stops earning on day 21, and a donor who stays to day
30 does not retroactively collect fees earned on liquidity that has already left.

Three accumulators, not four — USDC, WETH, and SKOOP, where SKOOP fees from **both**
positions feed one accumulator because both are denominated in the same token.

---

## Lifecycle

```
deploy          immutables set; no positions, no donors, no clocks
record          owner records each donor: shares + SKOOP allocation
seal            positions adopted, liquidity snapshotted, donor list frozen
activate        clocks start HERE, not at deploy  (Activatable)
claim           SKOOP, liquidity and fees, on the schedule
lockVault       one-way; closes the hatch when tests pass
```

`seal()` is the gate, and it is where every consistency check lives:

- `ownerOf(usdcTokenId) == address(this)` and the same for the ETH position.
  **`LPLocker.initializeLP` does not check this** — it cannot fail to be true on the factory
  path, and `VerifyManualSuite` covers it by hand for SKOOP. This contract is being written
  fresh, so it checks for itself.
- `balanceOf(SKOOP) >= totalSkoopAllocated` — otherwise the last donors to claim find an
  empty vault.
- `totalShares > 0`, both positions have non-zero liquidity, not already sealed.

After `seal()`, no donor can be added or changed. Before it, everything is editable.

---

## Interface

```solidity
contract SkoopDonorVault is Activatable, ReentrancyGuard, IERC721Receiver {

    // ── immutable ────────────────────────────────────────────────
    address public immutable skoop;
    address public immutable usdc;
    address public immutable weth;
    address public immutable positionManager;
    address public immutable ownerWallet;      // holds the hatch

    // ── schedule, in days from activation ────────────────────────
    uint256 public constant SKOOP_VEST_DAYS  = 30;
    uint256 public constant LP_HOLD_DAYS     = 20;
    uint256 public constant LP_RELEASE_DAYS  = 10;   // ends at day 30

    // ── setup, owner only, before seal ───────────────────────────
    function recordDonor(address donor, uint256 shares_, uint256 skoopAllocation) external;
    function seal(uint256 usdcTokenId, uint256 ethTokenId) external;

    // ── donor ────────────────────────────────────────────────────
    function claimSkoop() external returns (uint256);
    function claimLiquidity(uint256 usdcMin, uint256 wethMin, uint256 skoopMin)
        external returns (uint256 usdcOut, uint256 wethOut, uint256 skoopOut);
    function claimFees() external returns (uint256, uint256, uint256);

    // ── permissionless ───────────────────────────────────────────
    function collectFees() external;    // sweep into the accumulators; anyone may call

    // ── views ────────────────────────────────────────────────────
    function releasableSkoop(address) external view returns (uint256);
    function releasableLiquidity(address) external view returns (uint128, uint128);
    function pendingFees(address) external view returns (uint256, uint256, uint256);
    function evacuationOpen() external view returns (bool);

    // ── hatch, mirroring LPLockerPilot exactly ───────────────────
    function lockVault() external;      // one-way
    function evacuateVault() external;  // owner only, all-or-nothing, terminal
}
```

The hatch deliberately reuses `LPLockerPilot`'s shape and vocabulary — `evacuationOpen()`,
a one-way close, owner-only, all-or-nothing, loud — so there is one mental model across the
system and the dapp reads the same function name on both.

`claimLiquidity` takes slippage minimums. `LPLocker.release()` passes `0, 0` because it runs
once at a scheduled time under the merchant's own control; a donor claim is a public
transaction at a time an adversary can see coming, so it gets real bounds.

---

## Failure modes

| # | Failure | Guard |
|---|---|---|
| 1 | Recorded shares don't match seeded liquidity | snapshot at `seal()`, derive fixed per-donor liquidity, never recompute |
| 2 | A claim sweeps other donors' fees | collect-before-withdraw ordering |
| 3 | Vault doesn't own the NFTs | `ownerOf` checked in `seal()` |
| 4 | SKOOP grants underfunded | balance check in `seal()` |
| 5 | Rounding dust strands the last claimer | cap every payout at balance; sweep dust to owner only after the schedule ends |
| 6 | Clocks start at deploy, not launch | `Activatable`; `activate()` requires sealed |
| 7 | Donor recorded twice | `recordDonor` reverts on an existing donor; corrections are explicit |
| 8 | Claim sandwiched | donor-supplied minimums |
| 9 | Owner evacuates mid-schedule | claims revert with a named error, `VaultEvacuated` is loud, and the terms document discloses it |
| 10 | Re-entrancy via token callbacks | `nonReentrant` on every state-changing external |

Failure 1 is the one that loses money quietly, and failure 2 is the one that looks like it
works in every single-donor test.

---

## Test plan

Nothing is collected until all four stages pass.

**1 — Unit.** Boundary dates: day 0, 1, 20, 21, 30, 31. Zero before the cliff, exact at the
end, nothing extra after. Assert against contract getters, never against a recomputed
`block.timestamp` expression — under `via_ir` two identical reads fold into one, which has
already produced a false pass in this repo (`test/Activation.t.sol`).

**2 — Invariant.** With a handler driving random deposits, claims and swaps:

- the sum of all liquidity claimed never exceeds what was sealed
- the sum of all fees paid never exceeds what was collected
- no donor can claim the same slice twice
- the vault is never insolvent for SKOOP grants
- after every donor fully exits, residual liquidity is dust, not a balance

**3 — Fork, against live Base.** Real pools, real router, real fees. The case that matters
is **two donors exiting on different days with trades in between** — that is the only one
where the fee accumulator can be wrong, and the only one a single-donor test cannot see.
Also: evacuation mid-schedule returns everything, and claims revert cleanly afterwards.

**4 — Mainnet rehearsal.** Throwaway token, two wallets, ~$25, mirroring
`docs/micro-launch-results.md`. A 30-day schedule cannot be rehearsed on mainnet in 30
days of calendar time, so this uses `SkoopDonorVaultRehearsal` — the same contract with
minutes in place of days — following the existing beta/pilot variant pattern. The
production constants stay untouched and an invariant asserts the rehearsal variant is never
referenced by a production script.

---

## What this does not do

No transferable share token. Donors hold a recorded claim, not an ERC-20, so the hold
cannot be traded around. Simpler, and a transferable claim during a hold period is a hold
period with a secondary market in it.

No partial evacuation, for the same reason `LPLockerBeta` refuses one: partial withdrawal
means recomputing shares against liquidity that moved, which is the exact accounting that
produced a drain bug in that contract before.
