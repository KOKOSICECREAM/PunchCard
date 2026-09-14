# Economics review against KOKOS

The contracts have had multiple review passes. The **numbers** had none. Emission rate,
drawer size, seed minimums and the fee share are all `constant` or `immutable`, so they are
expensive to change after merchant #1 — and all were reasoned from first principles rather
than from evidence.

KOKOS is the only evidence that exists. Measured on-chain 2026-09-14 from Base mainnet.

---

## What KOKOS actually does

Every SKOOP spent in-store is burned, so supply decline is a direct measure of in-store
SKOOP throughput.

| Window | SKOOP burned | Per day |
|---|---|---|
| 150–120d ago | 11,804 | 393 |
| 120–90d ago | 1,150,856 | **38,362** |
| 90–60d ago | 741,189 | 24,706 |
| 60–30d ago | 539,950 | 17,998 |
| **30–0d ago** | **6,963** | **232** |

**Rewards paid from the rewards vault in the last 90 days: zero.** The vault has sat at
486,899,824 SKOOP unchanged since it was funded.

Pool depth: the USDC/SKOOP pool holds **$720 of USDC** (~$1,440 TVL). SKOOP trades at
$0.00008558.

---

## What that says about each parameter

### Emission: 24,657/day is roughly 5.7× too fast

Normalised for the different supplies (SKOOP 889M, PunchCard 100M):

| | % of supply per day |
|---|---|
| KOKOS at peak | 0.0043% |
| KOKOS last 30 days | ~0.0000% |
| **PunchCard emission** | **0.0247%** |

At KOKOS-peak-equivalent volume a merchant would draw ~4,300 tokens/day, so the 45M
allocation lasts **28.6 years**, not five.

This is not dangerous — a merchant simply never reaches the ceiling — but it means the
emission schedule will **never be the binding constraint**, and describing it as a
"five-year runway" overstates what it does. If the intent is for emission to actually pace
a programme, it is an order of magnitude loose.

### Drawer: ~13× larger than the reference peak needs

At KOKOS's peak, 10% rewards on 38,362/day of spend is roughly 3,800 tokens/day of reward
issuance. The default drawer is 49,315/day. The theft ceiling is therefore ~13× higher than
a KOKOS-sized shop would ever need, which makes the "$100 cash drawer" framing generous
rather than tight. Worth considering a smaller default, since the drawer's whole purpose is
to cap loss.

### Seed minimums: conservative, and correctly so

PunchCard requires ~$2,000 USDC-side. KOKOS runs on **$720**. The minimum is 2.8× deeper
than the live reference — the one parameter that evidence says is set right, or even
generously.

### LP fee share: the finding that matters

20% of trading fees is a sound *mechanism*. But at KOKOS's current volume it earns
approximately nothing, and even at peak the pool was ~$1,440 deep.

**A loyalty token that customers earn and spend generates burns and transfers, not swaps.**
Swaps only happen when someone converts — and the cross-merchant routing that would drive
that needs network density which does not exist yet.

So revenue is genuinely back-loaded and density-dependent, and the **deployment fee is not
optional** — it is what funds the business until the network is dense enough for LP fees to
matter. It is still unbuilt.

---

## The thing to investigate before merchant #1

**In-store SKOOP throughput fell 98.7% in the last 30 days** — 17,998/day to 232/day.

A hypothesis worth checking rather than assuming: the customer dapp's price quoter has been
broken, falling back to raw spot price and **over-quoting by up to 58% on larger purchases**
(see `docs/audit-2026-09.md`). Customers shown one number and receiving materially less
would stop buying. That bug was fixed 2026-09-13; whether the timelines line up is a
question for KOKOS's own records, not something on-chain data can settle.

Other explanations are equally plausible — seasonality, the shop de-emphasising SKOOP,
customers paying with card instead. But a payments bug that mis-quotes in the merchant's
favour is the kind of thing that quietly kills usage, and it was live during the decline.

**Do not calibrate PunchCard's parameters against the last 30 days.** Use the 120–60 day
window, when the programme was actually running.

---

## Recommendations

1. **Reduce emission or stop calling it a five-year runway.** At realistic volume it is a
   28-year allocation. Either is fine; the mismatch between the two is not.
2. **Consider a smaller default drawer.** 13× headroom over peak need is loss ceiling given
   away for nothing.
3. **Keep the seed minimums.** Evidence says they are right.
4. **Build the deployment fee.** LP fees will not carry the business at merchant #1–10.
5. **Find out what happened to KOKOS volume** before assuming a second merchant behaves
   differently.
