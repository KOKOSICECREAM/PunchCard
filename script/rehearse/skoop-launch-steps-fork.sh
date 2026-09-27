#!/usr/bin/env bash
# Runs the real launch steps (script/deploy/skoop/*.sh) end to end on a fork of Base, as the
# real wallets via impersonation, with the REAL addresses from lib.sh — no placeholders.
# Then runs every step a second time: each must find its work done and change nothing.
# Uses its own state file; the real deploy/merchants/skoop-suite.json is never touched.
#
#   bash script/rehearse/skoop-launch-steps-fork.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
BASE_RPC=${BASE_RPC:-https://mainnet.base.org}; PORT=${PORT:-8546}
export SKOOP_RPC=http://127.0.0.1:$PORT SKOOP_UNLOCKED=1
export SKOOP_STATE=${TMPDIR:-/tmp}/skoop-suite-rehearsal.json; rm -f "$SKOOP_STATE"

anvil --fork-url "$BASE_RPC" --port "$PORT" --auto-impersonate --silent &
ANVIL=$!; trap 'kill $ANVIL 2>/dev/null' EXIT
for _ in $(seq 1 60); do cast block-number --rpc-url "$SKOOP_RPC" >/dev/null 2>&1 && break; sleep 0.5; done
echo "fork block $(cast block-number --rpc-url "$SKOOP_RPC")"
for a in 0x3B44CF955Db742aEbCDC3260cb2599eE209E90dC 0x5478bab8986eb652D3083Db6bbb34FA3188AB9cb 0x5426E59b783cd3b5083Ccc8cB571AA36e9f4a3be 0x6A9Ad1cE8d6256acd28fd8C50A6C72e0043C221F; do
  cast rpc --rpc-url "$SKOOP_RPC" anvil_setBalance $a 0x2386F26FC10000 >/dev/null     # 0.01 ETH of gas on the fork
done

for pass in first "second (must resume and change nothing)"; do
  printf '\n\033[1m######## %s pass ########\033[0m\n' "$pass"
  for step in 3-deploy-suite 4-fund 5-starter-lp 5b-init-activate 6-sourcify 7-approve 8-verify 11-register; do
    bash script/deploy/skoop/$step.sh || { echo "✗ $step failed on the $pass pass"; exit 1; }
  done
done
printf '\n\033[1m######## state file ########\033[0m\n'; cat "$SKOOP_STATE"
echo "Steps rehearsal complete — nothing was sent to Base"
