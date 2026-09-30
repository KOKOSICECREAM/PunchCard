#!/usr/bin/env bash
# SKOOP launch, step 2: deploy the PunchCard network to Base mainnet.
#
# Every value is fixed in this file so nothing has to be pasted: a long pasted command
# once arrived with the fee recipient truncated to "0x6588A9Fc752dd1". Checks before it
# sends anything:
#   1. the pc-deployer keystore exists and IS 0xEfaf... (asks the keystore password)
#   2. 0xEfaf... has not sent anything since the rehearsal (nonce 2): the controller
#      is built to expect the factory at an address predicted from that nonce
#   3. a dry run against live Base succeeds
#   4. you type DEPLOY
#
#   bash script/deploy/step2-network.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

RPC=https://mainnet.base.org
KEYSTORE=pc-deployer
DEPLOYER=0xEfafE621247fe74B269c6177665eB36C91f6C48b      # Rabby hot wallet, broadcasts + approved deployer
EXPECTED_NONCE=2

export PC_CREATE_NEW_NETWORK=true
export PC_MULTISIG=0x5478bab8986eb652D3083Db6bbb34FA3188AB9cb        # governance: Ledger #41
export PC_DEPLOYER=$DEPLOYER
export PC_FEE_RECIPIENT=0x6588A99071e0e988071dA4252e9499ddFc752dd1
export PC_POSITION_MANAGER=0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1   # NOT ...34f2
export PC_SWAP_ROUTER=0x2626664c2603336E57B271c5C0b26F421741e481
export PC_USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
export PC_WETH=0x4200000000000000000000000000000000000006
export PC_ETH_USD_FEED=0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70
export PC_MIN_USDC_SEED_USD=200000000000    # $2,000 at 8dp (future merchants' floor)
export PC_MIN_ETH_SEED_USD=100000000000     # $1,000 at 8dp
export PC_ROUTER_FEE_BPS=30                 # 0.3%

echo "== 1. keystore =="
if [ ! -f "$HOME/.foundry/keystores/$KEYSTORE" ]; then
  echo "No '$KEYSTORE' keystore. In a separate terminal (not through Claude):"
  echo "    cast wallet import $KEYSTORE --interactive"
  echo "paste 0xEfaf...'s private key from Rabby at the hidden prompt, choose a password, then rerun this."
  exit 1
fi
echo "Enter the $KEYSTORE keystore password to confirm which wallet it holds:"
GOT=$(cast wallet address --account "$KEYSTORE")
if [ "$(echo "$GOT" | tr A-F a-f)" != "$(echo "$DEPLOYER" | tr A-F a-f)" ]; then
  echo "STOP: keystore '$KEYSTORE' is $GOT, expected $DEPLOYER"; exit 1
fi
echo "ok: $GOT"

echo "== 2. deployer state =="
NONCE=$(cast nonce "$DEPLOYER" --rpc-url "$RPC")
BAL=$(cast balance "$DEPLOYER" --ether --rpc-url "$RPC")
echo "nonce $NONCE, $BAL ETH"
if [ "$NONCE" != "$EXPECTED_NONCE" ]; then
  echo "STOP: nonce is $NONCE, expected $EXPECTED_NONCE. Something was sent from this wallet"
  echo "since the rehearsal — check Basescan before going on (the network may already exist)."
  exit 1
fi

echo "== 3. dry run against live Base =="
forge script script/DeployNetworkStaged.s.sol --rpc-url "$RPC" --sender "$DEPLOYER" 2>&1 \
  | grep -E "Estimated amount|SIMULATION COMPLETE|Error|revert" || true

echo
echo "About to deploy the PunchCard network from $DEPLOYER:"
echo "  governance    $PC_MULTISIG"
echo "  fee           $PC_ROUTER_FEE_BPS bps -> $PC_FEE_RECIPIENT"
echo "  five contracts: SuiteDeployer, LockerDeployerBeta, WindDownController,"
echo "                  StagedTokenFactoryBeta, PunchCardRouter"
read -r -p "Type DEPLOY to broadcast: " ok
[ "$ok" = "DEPLOY" ] || { echo "Not deployed."; exit 1; }

echo "== 4. broadcast (asks the keystore password once more) =="
forge script script/DeployNetworkStaged.s.sol --rpc-url "$RPC" \
  --account "$KEYSTORE" --sender "$DEPLOYER" --broadcast

echo "== deployed =="
python3 - <<'PY'
import json
d=json.load(open('broadcast/DeployNetworkStaged.s.sol/8453/run-latest.json'))
for t in d['transactions']:
    if t['transactionType']=='CREATE': print(f"  {t['contractName']:24s} {t['contractAddress']}")
for r in d['receipts']: print(f"  tx {r['transactionHash']}  status {int(r['status'],16)}")
PY
echo "Tell Claude it's done — it will verify all five on-chain."
