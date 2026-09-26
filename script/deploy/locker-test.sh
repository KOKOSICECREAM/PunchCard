#!/usr/bin/env bash
# Live LPLockerPilot test with the two ~$1 positions the test wallet holds in SKOOP's own
# 1% pools. Three phases, so the locker can be inspected (and earn real fees) in between:
#
#   bash script/deploy/locker-test.sh setup      deploy, NFTs in, 50 SKOOP reserve, initializeLP, activate
#   bash script/deploy/locker-test.sh collect    collectFees: WETH/USDC side -> 0x6588, SKOOP side burned
#   bash script/deploy/locker-test.sh evacuate   everything back to the test wallet; locker bricked for good
#
# This locker is a throwaway. initializeLP is once-only and evacuateLP is terminal, so it can
# never become SKOOP's real locker; it exists to prove the contract by hand, on mainnet, first.
# Rehearsed step for step by script/rehearse/locker-test-fork.sh; this file was itself run
# against a fork with LOCKER_TEST_RPC + LOCKER_TEST_UNLOCKED=1 before being handed over.
#
# Signs with the pc-locker-test keystore (0x7Fe7..., imported from Rabby). Asks its password
# once per run. Every transaction's receipt is checked; a revert stops the script.
set -euo pipefail
cd "$(dirname "$0")/../.."
PHASE=${1:-}

RPC=${LOCKER_TEST_RPC:-https://mainnet.base.org}
KEYSTORE=${LOCKER_TEST_KEYSTORE:-pc-locker-test}
TESTER=${LOCKER_TEST_TESTER:-0x7Fe79Bc539d3e8a1B4b14e6788A8D80f3B0510Fd}
SKOOP=0xBa147713adF122A8Fc224e52Cb431D7919831939
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
WETH=0x4200000000000000000000000000000000000006
NPM=0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1
WDC=0x7dbd9CA01fa60aB480f3A4AE7892970C97EF0cac
FEE_RECIPIENT=0x6588A99071e0e988071dA4252e9499ddFc752dd1
USDC_NFT=6101973; ETH_NFT=6101969
RESERVE=50000000                      # 50 SKOOP
STATE=deploy/network/locker-test.json # records the locker address between phases
GAS=(--gas-limit 1000000)             # nested Uniswap calls: never send the bare estimate

call(){ cast call --rpc-url "$RPC" "$@" | awk '{print $1}'; }
bal(){ call "$1" "balanceOf(address)(uint256)" "$2"; }
liq(){ cast call --rpc-url "$RPC" $NPM 'positions(uint256)(uint96,address,address,address,uint24,int24,int24,uint128,uint256,uint256,uint128,uint128)' "$1" | sed -n 8p | awk '{print $1}'; }

if [ "${LOCKER_TEST_UNLOCKED:-0}" = 1 ]; then SIGN=(--unlocked --from $TESTER)   # fork rehearsal only
else
  [ -f "$HOME/.foundry/keystores/$KEYSTORE" ] || { echo "No '$KEYSTORE' keystore. In a separate terminal (not through Claude):"; echo "    cast wallet import $KEYSTORE --interactive"; echo "paste 0x7Fe7...'s private key from Rabby, choose a password, then rerun."; exit 1; }
  # The password goes to cast through a private temp file (mode 600, deleted on exit):
  # cast has no password env var, and a prompt inside $( ) cannot be answered.
  PWFILE=$(mktemp); chmod 600 "$PWFILE"; trap 'rm -f "$PWFILE"' EXIT
  read -r -s -p "Password for the $KEYSTORE keystore: " PW; echo; printf '%s' "$PW" > "$PWFILE"; unset PW
  GOT=$(cast wallet address --account "$KEYSTORE" --password-file "$PWFILE") || { echo "STOP: wrong password for $KEYSTORE"; exit 1; }
  [ "$(echo "$GOT" | tr A-F a-f)" = "$(echo "$TESTER" | tr A-F a-f)" ] || { echo "STOP: keystore is $GOT, expected $TESTER"; exit 1; }
  SIGN=(--account "$KEYSTORE" --password-file "$PWFILE")
fi
tx(){ local what=$1; shift
  local out st; out=$(cast send --rpc-url "$RPC" "${SIGN[@]}" "$@" --json)
  st=$(echo "$out" | python3 -c "import sys,json;r=json.load(sys.stdin);print(int(r['status'],16),r['transactionHash'])")
  [ "${st%% *}" = 1 ] || { echo "  ✗ $what FAILED on-chain: tx ${st#* }"; exit 1; }
  echo "  ✓ $what  tx ${st#* }"; }
locker(){ python3 -c "import json;print(json.load(open('$STATE'))['locker'])"; }

case "$PHASE" in
setup)
  [ -f "$STATE" ] && { echo "STOP: $STATE exists - setup already ran (locker $(locker))."; exit 1; }
  [ "$(call $NPM 'ownerOf(uint256)(address)' $USDC_NFT | tr A-F a-f)" = "$(echo $TESTER | tr A-F a-f)" ] || { echo "STOP: #$USDC_NFT is not in the test wallet"; exit 1; }
  [ "$(call $NPM 'ownerOf(uint256)(address)' $ETH_NFT  | tr A-F a-f)" = "$(echo $TESTER | tr A-F a-f)" ] || { echo "STOP: #$ETH_NFT is not in the test wallet"; exit 1; }
  echo "== deploy LPLockerPilot (owner and activator: the test wallet) =="
  LOCKER=$(forge create contracts/pilot/LPLockerPilot.sol:LPLockerPilot --rpc-url "$RPC" "${SIGN[@]}" --broadcast \
    --constructor-args $SKOOP $TESTER $WDC $NPM $TESTER $USDC $WETH $FEE_RECIPIENT | awk '/Deployed to:/{print $3}')
  [ -n "$LOCKER" ] || { echo "  ✗ deploy failed"; exit 1; }
  printf '{\n  "_note": "Throwaway LPLockerPilot for the live locker test. Never SKOOP'"'"'s real locker.",\n  "locker": "%s",\n  "owner": "%s",\n  "usdcNft": %s,\n  "ethNft": %s\n}\n' $LOCKER $TESTER $USDC_NFT $ETH_NFT > "$STATE"
  echo "  ✓ locker $LOCKER  (saved to $STATE)"
  echo "== NFTs in, then the reserve, then initializeLP (that order) =="
  tx "transfer #$USDC_NFT to the locker" $NPM "transferFrom(address,address,uint256)" $TESTER $LOCKER $USDC_NFT
  tx "transfer #$ETH_NFT to the locker"  $NPM "transferFrom(address,address,uint256)" $TESTER $LOCKER $ETH_NFT
  tx "send the 50 SKOOP reserve" $SKOOP "transfer(address,uint256)" $LOCKER $RESERVE
  tx "initializeLP" $LOCKER "initializeLP(uint256,uint256,uint24,uint24)" $USDC_NFT $ETH_NFT 10000 10000 "${GAS[@]}"
  tx "activate" $LOCKER "activate()"
  echo "== check =="
  echo "  initialized $(call $LOCKER 'isInitialized()(bool)') · reserve $(call $LOCKER 'reserveTokens()(uint256)') (expect $RESERVE) · evacuationOpen $(call $LOCKER 'evacuationOpen()(bool)')"
  echo "  #$USDC_NFT owner $(call $NPM 'ownerOf(uint256)(address)' $USDC_NFT) · #$ETH_NFT owner $(call $NPM 'ownerOf(uint256)(address)' $ETH_NFT)"
  echo "Done. Look at $LOCKER on Basescan; run 'collect' and 'evacuate' whenever you like." ;;
collect)
  LOCKER=$(locker); U0=$(bal $USDC $FEE_RECIPIENT); W0=$(bal $WETH $FEE_RECIPIENT); S0=$(call $SKOOP 'totalSupply()(uint256)')
  tx "collectFees" $LOCKER "collectFees()" "${GAS[@]}"
  echo "  network fee -> 0x6588: +$(( $(bal $USDC $FEE_RECIPIENT) - U0 )) USDC raw, +$(( $(bal $WETH $FEE_RECIPIENT) - W0 )) WETH wei"
  echo "  SKOOP fees burned: $(( S0 - $(call $SKOOP 'totalSupply()(uint256)') )) raw · reserve still $(call $LOCKER 'reserveTokens()(uint256)')" ;;
evacuate)
  LOCKER=$(locker)
  read -r -p "evacuateLP is terminal: this locker can never be used again. Type EVACUATE: " ok
  [ "$ok" = EVACUATE ] || { echo "Not evacuated."; exit 1; }
  S0=$(bal $SKOOP $TESTER); U0=$(bal $USDC $TESTER); W0=$(bal $WETH $TESTER)
  tx "evacuateLP" $LOCKER "evacuateLP()" "${GAS[@]}"
  echo "  returned to the test wallet: +$(( $(bal $SKOOP $TESTER) - S0 )) SKOOP raw, +$(( $(bal $USDC $TESTER) - U0 )) USDC raw, +$(( $(bal $WETH $TESTER) - W0 )) WETH wei"
  echo "  positions: liquidity $(liq $USDC_NFT) / $(liq $ETH_NFT) · locker holds $(bal $SKOOP $LOCKER) SKOOP"
  echo "  lpPermanentlyLocked $(call $LOCKER 'lpPermanentlyLocked()(bool)') · evacuationOpen $(call $LOCKER 'evacuationOpen()(bool)')" ;;
*) echo "usage: bash script/deploy/locker-test.sh setup|collect|evacuate"; exit 1 ;;
esac
