# Staged handoff files

`StageMerchant.s.sol` writes `<chainid>-latest.json` here at `PC_STAGE=1` and reads it back
at stages 2, 3 and abort, so an operator does not retype a token address between
transactions.

**These files are gitignored, deliberately.** A fork run writes one that is byte-identical
to a live run's — same `chainId: 8453`, same shape, real-looking addresses that exist only
in a forked EVM. Committing them would put a file in the repo that looks like a deployment
record and is not one. This happened once, within an hour of the handoff being added.

The authoritative record of a real deployment is `deploy/network/*.json`, written
deliberately as described in `docs/deployment-runbook.md`. This directory is scratch between
two transactions, nothing more.

`PC_TOKEN` overrides the file whenever it is set.
