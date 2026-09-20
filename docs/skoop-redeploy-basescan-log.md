# SKOOP Redeploy and BaseScan Handoff Log

Date: 2026-09-17

This note records the clean SKOOP token redeploy and BaseScan token-profile work so the next reviewer can see what changed without reconstructing it from chat.

## Clean SKOOP Token

The first clean SKOOP token was deployed, then replaced after we noticed the verified `MerchantToken.sol` NatSpec still described only the factory-minted path. The old token's supply was sent to the dead address.

Superseded token:

- Address: `0x38bdc0f357455C49486cb3871a3AA218aAd10D2B`
- Disposal transaction: `0xe1acba279c2ab35d1ad11d164e2446a734ac9b5fa87b007ce5baab5768827bc1`

> **It was sent to `0x…dEaD`, not burned.** Verified on-chain 2026-09-19: the transaction is
> `transfer(0x000...dEaD, 100000000e6)`, selector `0xa9059cbb`. `totalSupply()` on the
> superseded token still reads **100,000,000.000000** and always will, so BaseScan shows it
> as a live token with a single holder. The supply is unrecoverable — nobody holds that
> address's key — but it was never destroyed. `MerchantToken` is `ERC20Burnable` and
> `burn()` would have set supply to zero; it is no longer callable because the owner wallet
> no longer holds the tokens. Worth stating precisely, because "burned" and "100M supply on
> a block explorer" read as a contradiction to anyone who checks.

Current token:

- Address: `0xBa147713adF122A8Fc224e52Cb431D7919831939`
- Name: `SKOOP PunchCard`
- Symbol: `SKOOP`
- Decimals: `6`
- Total supply: `100,000,000.000000`
- Raw supply: `100000000000000`
- Mint recipient / SKOOP OA: `0x5426E59b783cd3b5083Ccc8cB571AA36e9f4a3be`
- Deployer: `0xEfafE621247fe74B269c6177665eB36C91f6C48b`
- Deploy transaction: `0xe8a7c4068ed227bfbc6e2803bb8c088629a87acd6ab0b63786ce29e7f3f0e020`
- Block: `51432107`
- Metadata CID: `QmPhJXCg7snZNMCzgSLME8eujLZ6KvcJT3nwJnLMftwv8k`
- Logo CID: `QmNoS9wwGj3zb2rz1Z2AMbZMBfh6VMjijSAon5xUt6mXfV`
- Metadata hash stored in token: `0x31308a8763f929446f17aaca38cc9538ff0380a5d36fe6c5cffa5e1f7787c6bb`

On-chain checks after deploy:

- `name()` returns `SKOOP PunchCard`
- `symbol()` returns `SKOOP`
- `decimals()` returns `6`
- `totalSupply()` is exactly `100,000,000e6`
- Full supply is held by `0x5426E59b783cd3b5083Ccc8cB571AA36e9f4a3be`
- No `mint()`
- No `owner()`
- No `pause()`
- No `transferOwnership()`
- All eight Uniswap v3 pools were clear at deploy time: USDC and WETH at fee tiers `100`, `500`, `3000`, `10000`

## MerchantToken.sol Change

`contracts/MerchantToken.sol` was updated locally so the verified source describes both valid deployment paths:

- Factory path: token mints to the factory, then allocations are distributed by the factory.
- Manual SKOOP path: token mints directly to the owner wallet, then allocations are assembled and reviewed by hand before network registration.

The reason for the redeploy was not bytecode behavior. The issue was source/comment accuracy on the verified contract. The new token is the clean one to use going forward.

## BaseScan Work

Source verification:

- The current token source was verified on BaseScan and returned `Pass - Verified`.

Address ownership:

- BaseScan ownership verification was completed for `0xBa147713adF122A8Fc224e52Cb431D7919831939`.
- The creator address verified was `0xEfafE621247fe74B269c6177665eB36C91f6C48b`.

Token update form:

- Submitted on BaseScan on 2026-09-17.
- Request type: `New/First Time Token Update`.
- We deliberately did not frame it as a migration in the BaseScan profile. This is the fresh SKOOP PunchCard token profile.
- BaseScan displayed: `Thank you for your submission. You will receive an email containing further instructions shortly.`
- Do not submit a duplicate request unless BaseScan asks for it. Their page says duplicate submissions can slow review, and only the latest ticket will be reviewed.

Submitted fields:

- Token: `0xBa147713adF122A8Fc224e52Cb431D7919831939`
- Requester name: `Sam Brooker`
- Requester email: `sambrooker22@gmail.com`
- Project name: `SKOOP PunchCard`
- Website: `https://punchcard.club`
- Official project email: `hello@punchcard.club`
- Sector: `Loyalty / Rewards`
- GitHub: `https://github.com/KOKOSICECREAM/PunchCard`
- Description: `SKOOP PunchCard is an ERC-20 loyalty token for KOKOS Ice Cream's PunchCard rewards program on Base, built for reward distribution, merchant liquidity, and future network routing.`

## BaseScan Logo

BaseScan requires a `32x32` SVG logo URL. The first quick vector redraw looked wrong, so it was replaced with an SVG wrapper around the real SKOOP logo scaled to `32x32`.

Correct logo URL submitted to BaseScan:

`https://raw.githubusercontent.com/KOKOSICECREAM/PunchCard/bdc759b6790468531cd6059238c865e0243f1e0a/deploy/merchants/skoop-logo.svg`

Notes:

- The commit-pinned raw URL was used because the branch raw URL was temporarily caching the rejected first SVG.
- Local file now exists at `deploy/merchants/skoop-logo.svg`.
- The same path was updated on GitHub through the GitHub API in commit `bdc759b6790468531cd6059238c865e0243f1e0a`.

## Current State

`deploy/merchants/skoop.json` has been updated for the current token and the superseded one's disposal.

Current status is token-only:

- The current SKOOP token exists.
- It is not yet registered in the PunchCard network.
- It has no pools yet.
- It has no escrow, vesting, treasury, or locker suite yet.
- Next protocol steps remain in `docs/skoop-launch-plan.md`.

