#!/usr/bin/env bash
# Runs script/deploy/skoop/add-lp.sh against the LIVE locker on a fork of Base, as the owner
# wallet via impersonation: $5 USDC, then 0.002 ETH (wrapped by the script), then both at once.
# Uses a copy of the state file; nothing is sent to Base.
#
#   bash script/rehearse/add-lp-fork.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
BASE_RPC=${BASE_RPC:-https://mainnet.base.org}; PORT=${PORT:-8547}
export SKOOP_RPC=http://127.0.0.1:$PORT SKOOP_UNLOCKED=1
export SKOOP_STATE=${TMPDIR:-/tmp}/skoop-suite-addlp.json; cp deploy/merchants/skoop-suite.json "$SKOOP_STATE"
OWNER=0x5426E59b783cd3b5083Ccc8cB571AA36e9f4a3be; USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913

anvil --fork-url "$BASE_RPC" --port "$PORT" --auto-impersonate --silent &
ANVIL=$!; trap 'kill $ANVIL 2>/dev/null' EXIT
for _ in $(seq 1 60); do cast block-number --rpc-url "$SKOOP_RPC" >/dev/null 2>&1 && break; sleep 0.5; done
echo "fork block $(cast block-number --rpc-url "$SKOOP_RPC")"
cast rpc --rpc-url "$SKOOP_RPC" anvil_setBalance $OWNER 0xDE0B6B3A7640000 >/dev/null       # 1 ETH
# USDC (FiatToken) balances live in mapping slot 9: give the owner $20.
SLOT=$(cast index address $OWNER 9)
cast rpc --rpc-url "$SKOOP_RPC" anvil_setStorageAt $USDC "$SLOT" "$(cast to-uint256 20000000)" >/dev/null
echo "owner USDC on fork: $(cast call --rpc-url "$SKOOP_RPC" $USDC 'balanceOf(address)(uint256)' $OWNER)"

for args in "--usdc 5" "--eth 0.002" "--usdc 5 --eth 0.002"; do
  printf '\n\033[1m######## add-lp.sh %s ########\033[0m\n' "$args"
  bash script/deploy/skoop/add-lp.sh $args || { echo "✗ add-lp.sh $args failed"; exit 1; }
done
printf '\n\033[1m######## refusals ########\033[0m\n'
bash script/deploy/skoop/add-lp.sh --usdc 100000 >/dev/null 2>&1 && { echo "✗ accepted more USDC than the owner holds"; exit 1; } || echo "  ✓ refuses more USDC than the owner holds"
bash script/deploy/skoop/add-lp.sh >/dev/null 2>&1 && { echo "✗ accepted no amounts"; exit 1; } || echo "  ✓ refuses an empty call"
python3 -c "import json;[print(' ',x) for x in json.load(open('$SKOOP_STATE'))['liquidityAdded']]"
echo "add-lp rehearsal complete — nothing was sent to Base"
