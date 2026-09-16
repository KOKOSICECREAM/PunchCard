# Site copy proposal — network effect, and the rules every merchant token follows

**Draft for review. Not published.** Check every claim before anything ships, the way
`3c8c4d4` had to after the last round of copy went too far.

Kept plain on purpose. Contract names, constants and gas numbers belong in a sit-down
conversation and on GitHub, not on a page a shop owner reads on their phone.

**Scope, set 2026-09-15: the network effect and the rules merchant tokens follow.** An
earlier draft led with what happens when a business winds down. That is a real strength of
the protocol and the wrong thing for this site — opening a merchant page with how it ends is
a bad first move, and the question belongs in a conversation, not a headline.

## What the site already says

- **Network effect**, around line 939 — customers follow their tokens, merchants drive each
  other's traffic.
- **The allocation**, around line 1174 — 45 / 30 / 15 / 10.

Both good. Each is missing one thing, and the gaps are below.

---

## 1. The gap in the network-effect section

It describes the benefit and never says the mechanism. "A standing invitation to return" is
a feeling; the reason it works is that the tokens actually move.

> ### Your tokens are worth something at the shop next door.
>
> A customer earns at the coffee shop and wants to spend at your place. They do not need
> your token to have been given to them — they can trade the one they have for the one they
> want, in a couple of taps, without either of you arranging anything.
>
> That is what makes this a network instead of a pile of separate loyalty schemes. Every
> business that joins is somewhere every existing customer can now spend.
>
> — Nobody has to negotiate a partnership. It works the day you join.

**Why it is worth adding.** The current copy promises a network effect and leaves the reader
to take it on faith. This is the sentence that makes it concrete, and it is the part
competitors genuinely cannot copy — separate loyalty apps have no way to turn one shop's
points into another's.

**Verified live 2026-09-15:** two independent merchant tokens swapped for each other through
the network's router, two hops, the amount received matching the quote exactly. See
`docs/micro-launch-results.md`.

---

## 2. The gap in the tokenomics section

The split is published, which is good and rare. What is missing is why *sameness* is the
point rather than the specific numbers.

> ### Every business gets the same deal.
>
> Not a similar deal. The same one. The split, the schedules and the limits are the same for
> the first business on the network and the five-hundredth, and they are not up for
> negotiation — not by a big merchant with leverage, and not by us.
>
> So a customer who understands how one programme works understands all of them. Nobody has
> to read the fine print twice, because there is only one set.
>
> — We could not give someone a better deal than you even if we wanted to. It is the same
> code for everyone.

**Why it is worth adding.** "Here is our allocation" is a disclosure. "Nobody can get
different terms" is a promise, and it is the one that matters to a merchant wondering
whether they are getting the version offered to somebody with more leverage.

---

## 3. The rule that has no section at all

Membership is binary, and the site never says so.

> ### On the network, or not.
>
> There is no half-joined. A business is either running a full programme under the network's
> rules — swappable tokens, published limits, the same terms as everyone else — or it is not
> on the network and its token is not a network token.
>
> Nothing in between, and nothing we can wave through.
>
> — You can check which businesses are on it without asking us.

**Why it is worth adding.** It is what stops "PunchCard merchant" becoming a label that
means whatever the newest deal says. It also answers the question a careful merchant asks
second, after "what does it cost": *who else is on this, and what does their being on it
actually mean?*

---

## What must NOT go on the site

Written down so the next round of copy does not have to rediscover it.

- **Nothing about returns, appreciation, or holding.** Investment-adjacent claims were
  removed once already.
- **Never "permanently locked" for a programme whose opening period is still running.** It
  is not locked until it is. The dapp reads that state live; the site must not assert it.
- **No economics.** A live test with no customers proves the machine moves. It says nothing
  about what a reward should be worth, or whether anyone wants one.
- **No "audited".** It has not been.
- **No merchant count.** The only businesses ever deployed through the factory were two
  throwaways on a disposable test network, already retired.
- **Any number the contracts also know should be read from them, not typed twice.** The dapp
  already does this for the figures it quotes. A number that lives in two places eventually
  disagrees with itself, and then a disclosure is quietly false.

## The one status change that is newly sayable

The contracts have run on Base — a programme deployed, rewards issued, tokens swapped
between two businesses, fees collected, money recovered.

A fact, and a change from "never deployed". Not a pitch. If it appears at all it belongs as a
line in the status section rather than a banner, next to the sentence that keeps it honest:
**the machine works; whether the economics work is untested.**
