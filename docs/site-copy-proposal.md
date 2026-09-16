# Site copy proposal — three things worth saying that the site does not say

**Draft for review. Not published.** Nothing here should reach punchcard.club until someone
has checked every claim against the contracts, the way `3c8c4d4` had to after the last round
of copy went too far.

The site currently mentions wind-down **once** and the drawer **once**. Those are the two
most distinctive things the protocol does, and both are buried. A third — that a stranger
can verify which promises apply to them without trusting this website — is not mentioned at
all.

Written in the voice of the existing *PunchCard Promise* section: a claim in plain language,
a paragraph a shop owner would read, then a dash line with the fact that makes it true.

---

## 1. What happens if the shop closes

> ### Even the ending is written down.
>
> Most loyalty programmes just stop. An app goes dark, a card stops scanning, and whatever
> you had is gone with no one to ask. A token nobody can end is not better — it is the same
> silence with extra steps.
>
> So a PunchCard programme has an ending, and the ending is in the contract before anyone
> accepts a single token. If a business winds down, it takes a year. Rewards that were never
> handed out are burned rather than dumped. The pooled liquidity is returned, most of it to
> the merchant who put it there. Nothing about it is decided in the moment, because all of it
> was decided at the start.
>
> — `WindDownController` runs a 365-day settlement with four independent legs. Undistributed
> escrow burns, unclaimed treasury burns, vesting settles to what was actually earned, and
> liquidity releases only after the other three complete. PunchCard can start it; nobody can
> alter its terms.

**Why this is the strongest thing to say.** It is the question every merchant and every
customer eventually asks, almost nobody in this space answers, and the answer here is
checkable in advance. It costs nothing to claim because it is already built.

**Check before publishing:** the 90/10 release split, and that "most of it to the merchant"
matches `LPLocker.release()`.

---

## 2. The till behind the counter

> ### Built for a Saturday shift.
>
> Rewards are issued from a till, not a vault. Each point of sale gets its own, it refills
> gradually through the day rather than resetting at midnight, and it has a ceiling that
> nobody — not you, not us — can raise past what the programme can afford.
>
> If a phone goes missing, you remove that till and carry on. The other registers never
> stop. Nothing about the rest of the programme is touched.
>
> — Per-operator drawers with continuous linear replenishment, a hard `MAX_DRAWER_DAYS`
> ceiling enforced in immutable code, and `removeOperator` for rotation. The owner key can
> lower a drawer or halt the programme; it can never move a token to itself.

**Why this is worth saying.** It is the only part of the design that is visibly about
physical retail rather than about tokens, and it answers a question every owner has whether
or not they ask it. The continuous refill is a real design decision — a midnight reset has a
boundary worth gaming, and this has none.

---

## 3. Don't take our word for it

> ### You can check, without asking us.
>
> Every business on the network runs the same contracts, with the same numbers. Not "the
> same policy" — the same code, so the terms cannot be quietly different for one shop.
>
> Where a programme is genuinely different, the difference is a question you can ask the
> contract directly rather than a promise on a website. A programme still in its launch
> window will tell you so. One that is permanently locked will tell you that instead.
>
> — Allocation, cliff, treasury delay and reward ceilings are `constant` in the factory.
> Lineages differ by which functions answer — `HAS_LP_RECOVERY`, `HAS_UNLIMITED_LP_RECOVERY`
> — rather than by configuration, so a programme's guarantees are readable from the chain by
> anyone.

**Why this matters more than it sounds.** It is the reason the beta and pilot lineages are
separate contracts instead of a constructor argument. A guarantee that varies by
configuration looks identical in a block explorer to one that does not, and this repo kept
producing exactly that failure until the distinction was made structural.

---

## What must NOT go on the site

Written down so a future round of copy does not have to rediscover it.

- **Nothing about returns, appreciation, or holding.** `3c8c4d4` removed
  investment-adjacent claims once already.
- **No "permanently locked liquidity" for a merchant whose window is still open.** Beta and
  pilot programmes are not locked until `lockLP()` or expiry. The dapp reads the state; the
  site must not assert it.
- **No economics.** A live micro-launch with no customers proves the machine moves. It says
  nothing about emission rate, reward size, drawer sizing or demand. See
  `docs/economics-review.md`.
- **No "audited".** It has not been.
- **No merchant count implying real businesses.** The only merchants ever deployed through
  the factory are two throwaways on a disposable network, already retired. See
  `docs/micro-launch-results.md`.

## The one status change that is newly sayable

The contracts have executed on Base mainnet — deployment, activation, rewards,
cross-merchant routing, fee collection and capital recovery. That is a fact and a change
from "never deployed."

It is also not a pitch. If it appears at all it belongs as a line in the status section, not
a banner, and it must sit next to the sentence that keeps it honest: **the machine is proven,
the economics are not.**
