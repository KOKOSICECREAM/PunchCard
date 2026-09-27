# Shared by every SKOOP launch step (script/deploy/skoop/*.sh). Sourced, not run.
#
# Launch plan: option B (decided 2026-09-26) — SKOOP's suite on the live network, two ~$10
# starter positions and the LP wallet's remaining SKOOP as reserve in the locker, the real
# launch positions (#6100109, #6100112) left in the LP wallet.
#
# Every value is fixed here so nothing is pasted. Each step:
#   - records progress in $STATE and skips anything already done on-chain (rerun = resume)
#   - checks the signing key IS the expected address before sending (Ledger path or keystore)
#   - tracks nonces itself and waits for the RPC to show each tx mined (load-balanced RPC)
#   - checks every receipt; a revert stops the step
#   - sends calls that nest into Uniswap with a 1,000,000 gas limit
#
# Rehearse any step on a fork:  SKOOP_RPC=http://127.0.0.1:8546 SKOOP_UNLOCKED=1 bash script/deploy/skoop/<step>.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."

RPC=${SKOOP_RPC:-https://mainnet.base.org}
STATE=${SKOOP_STATE:-deploy/merchants/skoop-suite.json}

# ── network (live, verified) ───────────────────────────────────────────────────
SKOOP=0xBa147713adF122A8Fc224e52Cb431D7919831939
WDC=0x7dbd9CA01fa60aB480f3A4AE7892970C97EF0cac
ROUTER=0xB64A96f69bE171FE2d81F03b6D3c4029367d4f08
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
WETH=0x4200000000000000000000000000000000000006
NPM=0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1
ETH_FEED=0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70
USDC_POOL=0x5185bef315Dee41727865AC26243bD62008d11b1
ETH_POOL=0x116d0a851632958AFD3B1a0B751089392bcb4e6A
FEE_RECIPIENT=0x6588A99071e0e988071dA4252e9499ddFc752dd1
REAL_USDC_NFT=6100109; REAL_ETH_NFT=6100112            # stay in the LP wallet under option B

# ── wallets ────────────────────────────────────────────────────────────────────
OWNER=0x5426E59b783cd3b5083Ccc8cB571AA36e9f4a3be;      OWNER_PATH="m/44'/60'/40'/0/0"   # admin, confirmed
LP_WALLET=0x6A9Ad1cE8d6256acd28fd8C50A6C72e0043C221F;  LP_PATH="m/44'/60'/25'/0/0"
GOVERNANCE=0x5478bab8986eb652D3083Db6bbb34FA3188AB9cb; GOV_PATH="m/44'/60'/41'/0/0"

# ── REQUIRED — not decided yet. Each step refuses to run while its values are empty. ──
TEAM_WALLET=${SKOOP_TEAM_WALLET:-}          # Ledger #42, to be confirmed on the device. PERMANENT.
# Activator: the owner wallet, Ledger #40 (decided 2026-09-26). Its only powers are activate()
# once per contract and initializeLP() once — both spent at step 5b, after which it can do
# nothing. The old "fresh hot key" plan assumed the key had to outlive launch; under option B
# it does not, and a Ledger beats a hot key.
ACTIVATOR=${SKOOP_ACTIVATOR:-$OWNER}
ACTIVATOR_SIGNER=${SKOOP_ACTIVATOR_SIGNER:-$OWNER_PATH}   # a Ledger path, or keystore:NAME
OPERATOR=${SKOOP_OPERATOR:-0x4eCc3f03c018208Ae5932eAB91bbD82F37F56D9B}   # the live POS signer, for now (2026-09-26). Owner can swap it.
REGISTRAR=${SKOOP_REGISTRAR:-0x3B44CF955Db742aEbCDC3260cb2599eE209E90dC}  # Ledger #43, read from the device 2026-09-26. Not GOVERNANCE.
REGISTRAR_PATH=${SKOOP_REGISTRAR_PATH:-"m/44'/60'/43'/0/0"}

# ── suite parameters ───────────────────────────────────────────────────────────
ESCROW_FUND=45000000000000                  # 45M
VESTING_FUND=15000000000000                 # 15M
# treasury: whatever the owner holds after those two - 9,544,083 (decided 2026-09-26)
PER_TX_FLOOR=1; PER_TX_MAX=50000000000      # 0.000001 and 50,000 SKOOP
STARTER_USDC=10000000                       # $10 of USDC into the starter USDC position
STARTER_WETH=4000000000000000               # 0.004 WETH (~$10) into the starter ETH position
GAS=(--gas-limit 1000000)

# ── helpers ────────────────────────────────────────────────────────────────────
say(){ printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
die(){ echo "  ✗ $*"; exit 1; }
lc(){ echo "$1" | tr A-F a-f; }
call(){ cast call --rpc-url "$RPC" "$@" | awk '{print $1}'; }
bal(){ call "$1" "balanceOf(address)(uint256)" "$2"; }
fmt6(){ python3 -c "print(f'{int(\"$1\")/1e6:,.6f}')"; }
has_code(){ [ "$(( ($(cast code "$1" --rpc-url "$RPC" | wc -c) - 3) / 2 ))" -gt 0 ]; }
need(){ local n; for n in "$@"; do [ -n "${!n}" ] || die "$n is not set yet — decide it, then fill it in lib.sh (or export SKOOP_$n for a rehearsal)"; done; }
same(){ [ "$(lc "$1")" = "$(lc "$2")" ] || die "$3: got $1, expected $2"; }

st_get(){ python3 - "$STATE" "$1" <<'PY'
import json,sys,os
p,k=sys.argv[1],sys.argv[2]
d=json.load(open(p)) if os.path.exists(p) else {}
v=d
for part in k.split('.'):
    v=v.get(part) if isinstance(v,dict) else None
print('' if v is None else v)
PY
}
st_set(){ python3 - "$STATE" "$1" "$2" <<'PY'
import json,sys,os,collections
p,k,v=sys.argv[1:4]
d=json.load(open(p),object_pairs_hook=collections.OrderedDict) if os.path.exists(p) else collections.OrderedDict(_note="Progress of the SKOOP suite launch (option B). Written by script/deploy/skoop/*.sh.")
cur=d; parts=k.split('.')
for part in parts[:-1]: cur=cur.setdefault(part,collections.OrderedDict())
cur[parts[-1]]=int(v) if v.isdigit() else v
json.dump(d,open(p,'w'),indent=2); open(p,'a').write('\n')
PY
}

# use_signer ADDR (PATH|keystore:NAME) — sets SIGN and FROM, checks the key, starts the nonce
use_signer(){
  FROM=$1; local how=$2
  if [ "${SKOOP_UNLOCKED:-0}" = 1 ]; then SIGN=(--unlocked --from "$FROM")
  elif [[ "$how" == keystore:* ]]; then
    local ks=${how#keystore:}
    [ -f "$HOME/.foundry/keystores/$ks" ] || die "no '$ks' keystore — create it first (see the step's header)"
    PWFILE=$(mktemp); chmod 600 "$PWFILE"; trap 'rm -f "$PWFILE"' EXIT
    read -r -s -p "Password for the $ks keystore: " PW; echo; printf '%s' "$PW" > "$PWFILE"; unset PW
    local got; got=$(cast wallet address --account "$ks" --password-file "$PWFILE") || die "wrong password for $ks"
    same "$got" "$FROM" "keystore $ks"
    SIGN=(--account "$ks" --password-file "$PWFILE")
  else
    local got; got=$(cast wallet address --ledger --mnemonic-derivation-path "$how" 2>&1 | tail -1)
    [[ "$got" == 0x* ]] || die "Ledger not reachable ($got) — unlock it, open the Ethereum app, close Rabby"
    same "$got" "$FROM" "Ledger $how"
    SIGN=(--ledger --mnemonic-derivation-path "$how")
  fi
  # forge script: --sender not --from, and the Ledger flag is plural (--mnemonic-derivation-paths)
  if   [ "${SKOOP_UNLOCKED:-0}" = 1 ]; then FORGE_SIGN=(--unlocked)
  elif [[ "$how" == keystore:* ]];   then FORGE_SIGN=("${SIGN[@]}")
  else FORGE_SIGN=(--ledger --mnemonic-derivation-paths "$how"); fi
  NONCE=$(cast nonce "$FROM" --block pending --rpc-url "$RPC")
  echo "  signer $FROM · nonce $NONCE · $(cast balance "$FROM" --ether --rpc-url "$RPC") ETH"
}
wait_mined(){ local i; for i in $(seq 1 90); do [ "$(cast nonce "$FROM" --rpc-url "$RPC")" -ge "$NONCE" ] && return 0; sleep 2; done; die "RPC never showed nonce $NONCE for $FROM"; }
# tx "what" <cast send args…>  — prints and returns the receipt JSON in $RECEIPT
tx(){ local what=$1; shift
  wait_mined
  RECEIPT=$(cast send --rpc-url "$RPC" "${SIGN[@]}" --nonce "$NONCE" "$@" --json) || die "$what: send failed"
  NONCE=$((NONCE+1))
  local st; st=$(echo "$RECEIPT" | python3 -c "import sys,json;r=json.load(sys.stdin);print(int(r['status'],16),r['transactionHash'])")
  [ "${st%% *}" = 1 ] || die "$what FAILED on-chain: tx ${st#* }"
  echo "  ✓ $what  tx ${st#* }"; }
