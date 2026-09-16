# Site copy proposal — three things worth saying that the site does not say

**Draft for review. Not published.** Check every claim against the contracts before anything
ships, the way `3c8c4d4` had to after the last round of copy went too far.

The site mentions winding down **once** and the reward till **once**. Those are the two most
distinctive things the protocol does. A third — that you can check the terms yourself rather
than trust this website — is not mentioned at all.

Kept plain on purpose. The contract names, the constants and the gas numbers belong in a
sit-down conversation and on GitHub, not on a page a shop owner reads on their phone. Each
block below is a claim, a paragraph, and one closing line in the same register as the
existing *PunchCard Promise* copy.

---

## 1. What happens if the shop closes

> ### Even the ending is written down.
>
> Most loyalty programmes just stop. An app goes dark, a card stops scanning, and whatever
> you had is gone with nobody to ask.
>
> A PunchCard programme has an ending, and it is written down before anyone accepts a single
> token. If a business winds down it takes a year, not a weekend. Rewards that were never
> handed out are destroyed rather than dumped. The money behind the token goes back to the
> business that put it there.
>
> — None of it is decided in the moment, because all of it was decided at the start.

**Why this is the strongest of the three.** It is the question every merchant and every
customer eventually asks, almost nobody in this space answers it, and here the answer is
readable in advance. It costs nothing to claim because it is already built.

---

## 2. The till behind the counter

> ### Built for a Saturday shift.
>
> Rewards come out of a till, not a vault. Every register has its own. It refills through
> the day instead of resetting at midnight, and it has a limit nobody can raise — not you,
> not us.
>
> If a phone goes missing, you switch off that till and carry on. Every other register keeps
> working. Nothing else about your programme is touched.
>
> — You can slow a till down or stop the whole programme. Neither you nor we can move a
> customer's tokens.

**Why it is worth saying.** It is the only part of the design that is visibly about a real
shop rather than about tokens, and it answers something every owner wonders whether or not
they ask.

---

## 3. Don't take our word for it

> ### You can check for yourself.
>
> Every business on the network runs the same programme, with the same numbers. Not the same
> policy — the same code, so the terms cannot quietly be different for one shop and not
> another.
>
> Where a programme really is different, you can ask it directly instead of taking our word
> for it. A new programme still in its opening period will say so. One that is locked for
> good will say that instead.
>
> — Anyone can look. You do not need our permission and you do not need to ask us.

**Why this matters more than it sounds.** It is the reason a programme's differences are
built into separate contracts rather than settings. A guarantee that varies by setting looks
identical from the outside to one that does not.

---

## What must NOT go on the site

Written down so the next round of copy does not have to rediscover it.

- **Nothing about returns, appreciation, or holding.** Investment-adjacent claims were
  removed once already.
- **Never "permanently locked" for a programme whose opening period is still running.** It
  is not locked until it is. The dapp reads that state live; the site must not assert it.
- **No economics.** A live test with no customers proves the machine moves. It says nothing
  about how much a reward should be worth, or whether anyone wants one.
- **No "audited".** It has not been.
- **No merchant count.** The only businesses ever deployed through the factory were two
  throwaways on a disposable test network, already retired.

## The one status change that is newly sayable

The contracts have run on Base — a programme deployed, rewards issued, tokens swapped
between two businesses, fees collected, money recovered.

That is a fact and a change from "never deployed". It is not a pitch. If it appears at all
it belongs as a line in the status section rather than a banner, and it sits next to the
sentence that keeps it honest: **the machine works; whether the economics work is untested.**
