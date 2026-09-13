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
