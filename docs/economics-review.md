# Economics: still unvalidated

**Status: no usage evidence exists.** This document previously drew conclusions from KOKOS's
on-chain activity. That was an error — KOKOS is in beta and barely used, and its
transactions are correctness checks rather than commerce. The numbers below are recorded so
nobody mistakes them for demand data a second time.

Emission rate, drawer size, seed minimums and the fee share are all `constant` or
`immutable`, so they are expensive to change after merchant #1. All were reasoned from first
principles. **None has been tested against a real shop, and none can be until one runs.**

---

## What is actually on-chain (2026-09-14, Base mainnet)

Every SKOOP spent in-store is burned, so supply decline tracks SKOOP throughput.

| Window | SKOOP burned | Per day |
|---|---|---|
| 150–120d ago | 11,804 | 393 |
| 120–90d ago | 1,150,856 | 38,362 |
| 90–60d ago | 741,189 | 24,706 |
| 60–30d ago | 539,950 | 17,998 |
| 30–0d ago | 6,963 | 232 |

Rewards paid from the rewards vault in the last 90 days: zero. USDC pool depth: $720.
SKOOP at $0.00008558.

**This is beta test traffic.** It measures how often someone exercised the system, not how
often a customer bought ice cream with SKOOP. The shape — a burst, then a taper — is what
testing looks like, not what a business looks like. It cannot be used to calibrate anything,
and the earlier reading of it as a demand signal (and of the taper as a possible symptom of
the quoter bug) was wrong.

---

## What can still be said, on logic rather than data

**Loyalty tokens produce burns and transfers, not swaps — and swaps are what pay LP fees.**
A customer earns a token and spends it at the counter. That is a transfer and a burn.
Neither touches a pool. LP fees arrive only when someone *converts*, and the cross-merchant
routing that would drive conversion needs network density that does not exist at merchant
#1.

This is structural, not empirical, so beta usage does not weaken it:

- **The deployment fee is load-bearing, not optional.** It is what funds onboarding until
  density arrives. Still unbuilt, and still the highest-value item on the roadmap.
- **Revenue is back-loaded and density-dependent.** Plan the first several merchants
  assuming LP fees contribute approximately nothing.

**Seed minimums are defensible on arithmetic.** A $5,000 pool moves ~5% on a ~$100 swap.
That is workable for a $20 coffee-to-ice-cream conversion and poor for anything larger,
which is why the 27M reserve exists and why merchants need a reason to deploy it.

---

## What genuinely cannot be answered yet

None of these is knowable without a merchant doing real volume:

| Parameter | Question |
|---|---|
| Emission 24,657/day | Is that generous, tight, or irrelevant at real throughput? |
| Drawer default ~$82/day | Does it cover a real day's rewards, or throttle the till? |
| 45/30/15/10 split | Does 45% rewards last, at a rate customers notice? |
| 20% LP fee share | Is there enough swap volume for the share to matter? |
| 5-year emission period | Right horizon, or an order of magnitude out? |

**The first real merchant is the experiment.** Instrument them from day one — rewards issued
per day, drawer utilisation, swap volume, and the dollar value of a typical reward — because
those numbers are the calibration data, and the parameters are immutable per merchant once
deployed.

A practical consequence: **merchant #1 should be treated as a pilot whose parameters may be
wrong**, not as the template. Redeploying a suite is cheap compared with locking a bad
constant across a network.
