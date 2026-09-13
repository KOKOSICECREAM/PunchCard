# Building the contracts

The suite had never been compiled as a set before 2026-09-13 — the only build artifact
that existed was `WindDownController`. Anything that compiles is therefore a recent
statement about the code, not a historical one. Always build before you reason about it.

```bash
forge install OpenZeppelin/openzeppelin-contracts@v4.9.6 --no-git
forge build            # compile
forge build --sizes    # check against the 24,576-byte EIP-170 runtime limit
```

## Settings are not negotiable

`via_ir = true` with the optimizer on is **required** — `TokenFactory.deploy()` fails with
"Stack too deep" otherwise. The same settings must be used when verifying on Basescan or
the bytecode will not match the source.

## Known blockers

See `docs/audit-2026-09.md`. As of that audit the suite compiles only after structural
fixes, and `TokenFactory` still exceeds the deployable size limit. **Do not attempt a
mainnet deployment until that file says the blockers are cleared.**

## The fork test

`test/ForkDeploy.t.sol` runs a real merchant deployment against live Base contracts — the
actual position manager, swap router, USDC, WETH and Chainlink feed. No wallet, no keys, no
broadcast: forge forks chain state locally and fabricates balances with `deal`.

```bash
forge test --match-path test/ForkDeploy.t.sol --fork-url https://mainnet.base.org -vv
```

It skips itself when not pointed at a fork, so the offline suite stays fast.

This is the only test that exercises `TokenFactory.deploy()` — every other test mocks
around it. **Run it before any deployment, and after any change to the factory, the
deployers or LPLocker.** Until it existed, `deploy()` had never executed once, and it
carried two defects that no amount of reading had caught: pools were never initialised,
and the position manager address was one character wrong.

Deploying a merchant costs roughly **16.5M gas**. Cheap on Base, but worth knowing when
budgeting an onboarding.
