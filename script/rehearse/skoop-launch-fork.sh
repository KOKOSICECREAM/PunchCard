#!/usr/bin/env bash
# SKOOP launch, steps 2–11, rehearsed on a local fork of live Base.
#
# Runs the REAL deploy scripts (DeployNetworkStaged, DeploySkoopSuite, VerifyManualSuite)
# from the REAL addresses — governance key, deployer, owner wallet, LP wallet — via anvil's
# account impersonation, against today's chain: the token as deployed, the two 1% pools as
# seeded on 2026-09-25, the owner wallet's balance as it actually is. Nothing is broadcast
# to Base. The manual steps between the scripts are the same `cast` calls the real launch
# makes, so this file doubles as the runbook.
#
# Placeholders stand in for the wallets not yet chosen (activator, team, registrar); every
# other address is real. Addresses of deployed contracts come from the fork's nonces and
# will differ on the real run.
#
#   bash script/rehearse/skoop-launch-fork.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

BASE_RPC=${BASE_RPC:-https://mainnet.base.org}
PORT=${PORT:-8546}
RPC=http://127.0.0.1:$PORT

# ── real addresses ───────────────────────────────────────────────────────────────
SKOOP=0xBa147713adF122A8Fc224e52Cb431D7919831939
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
WETH=0x4200000000000000000000000000000000000006
NPM=0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1
SWAP_ROUTER=0x2626664c2603336E57B271c5C0b26F421741e481
ETH_FEED=0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70
USDC_POOL=0x5185bef315Dee41727865AC26243bD62008d11b1
ETH_POOL=0x116d0a851632958AFD3B1a0B751089392bcb4e6A
USDC_NFT=6100109
ETH_NFT=6100112

MULTISIG=0x5478bab8986eb652D3083Db6bbb34FA3188AB9cb   # governance: Ledger #41, an EOA
DEPLOYER=0xEfafE621247fe74B269c6177665eB36C91f6C48b   # factory deployer / network broadcaster
FEE_RECIPIENT=0x6588A99071e0e988071dA4252e9499ddFc752dd1
OWNER=0x5426E59b783cd3b5083Ccc8cB571AA36e9f4a3be      # holds the supply
LP_WALLET=0x6A9Ad1cE8d6256acd28fd8C50A6C72e0043C221F  # holds both LP NFTs + the 27M reserve
OPERATOR=0x4eCc3f03c018208Ae5932eAB91bbD82F37F56D9B   # the live POS signer, as first drawer

# ── placeholders for wallets not chosen yet ──────────────────────────────────────
ACTIVATOR=0x00000000000000000000000000000000000Ac701
TEAM=0x0000000000000000000000000000000000007Ea3
REGISTRAR=0x00000000000000000000000000000000000BE617
CUSTOMER=0x00000000000000000000000000000000000c0571

say(){ printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
# cast send exits 0 even when the transaction REVERTS on-chain, so check the receipt:
# a failed step must stop the rehearsal, not be read past. Calls that nest into Uniswap
# (initializeLP, addLiquidity, collectFees, evacuateLP, swaps) pass --gas-limit: cast
# sends the bare estimate, which is the minimum that just succeeds, and the 63/64 rule
# on the nested calls can then run it out of gas — seen once here on evacuateLP
# (estimate 514,751; used 410,040 on success; failed at the limit on the first try).
tx(){ local from=$1; shift
  local st; st=$(cast send --unlocked --from "$from" --rpc-url "$RPC" "$@" --json | python3 -c "import sys,json;print(int(json.load(sys.stdin)['status'],16))")
  [ "$st" = 1 ] || { echo "  ✗ transaction FAILED on-chain: $*"; exit 1; }; }
NESTED=(--gas-limit 1000000)
call(){ cast call --rpc-url "$RPC" "$@"; }
num(){ awk '{print $1}'; }
skoop(){ python3 -c "print(f'{int(\"$1\")/1e6:,.6f}')"; }
addr_of(){ python3 - "$1" "$2" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print(next(t['contractAddress'] for t in d['transactions'] if t['contractName']==sys.argv[2] and t['transactionType']=='CREATE'))
PY
}

# ── fork ─────────────────────────────────────────────────────────────────────────
say "Forking Base at the current block"
anvil --fork-url "$BASE_RPC" --port "$PORT" --auto-impersonate --silent &
ANVIL=$!; trap 'kill $ANVIL 2>/dev/null' EXIT
for _ in $(seq 1 60); do cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.5; done
echo "fork block $(cast block-number --rpc-url "$RPC")"
for a in $MULTISIG $DEPLOYER $OWNER $LP_WALLET $OPERATOR $ACTIVATOR $REGISTRAR $CUSTOMER; do
  cast rpc --rpc-url "$RPC" anvil_setBalance "$a" 0xDE0B6B3A7640000 >/dev/null   # 1 ETH gas on the fork
done

OWNER_BAL=$(call $SKOOP "balanceOf(address)(uint256)" $OWNER | num)
LP_BAL=$(call $SKOOP "balanceOf(address)(uint256)" $LP_WALLET | num)
echo "owner wallet SKOOP : $(skoop $OWNER_BAL)"
echo "LP wallet SKOOP    : $(skoop $LP_BAL)"
echo "LP NFTs            : #$USDC_NFT owner $(call $NPM 'ownerOf(uint256)(address)' $USDC_NFT) · #$ETH_NFT owner $(call $NPM 'ownerOf(uint256)(address)' $ETH_NFT)"

# ── step 2: the network ─────────────────────────────────────────────────────────
say "Step 2 — DeployNetworkStaged (from the deployer wallet)"
PC_CREATE_NEW_NETWORK=true PC_MULTISIG=$MULTISIG PC_DEPLOYER=$DEPLOYER PC_FEE_RECIPIENT=$FEE_RECIPIENT \
PC_POSITION_MANAGER=$NPM PC_SWAP_ROUTER=$SWAP_ROUTER PC_USDC=$USDC PC_WETH=$WETH PC_ETH_USD_FEED=$ETH_FEED \
PC_MIN_USDC_SEED_USD=200000000000 PC_MIN_ETH_SEED_USD=100000000000 PC_ROUTER_FEE_BPS=30 \
  forge script script/DeployNetworkStaged.s.sol --rpc-url "$RPC" --broadcast --unlocked --sender $DEPLOYER >/dev/null
NET=broadcast/DeployNetworkStaged.s.sol/8453/run-latest.json
WDC=$(addr_of $NET WindDownController); ROUTER=$(addr_of $NET PunchCardRouter); FACTORY=$(addr_of $NET StagedTokenFactoryBeta)
echo "controller $WDC"; echo "router     $ROUTER"; echo "factory    $FACTORY"
[ "$(call $WDC 'multisig()(address)')" = "$MULTISIG" ] || { echo "controller multisig mismatch"; exit 1; }

# ── step 3: the suite ───────────────────────────────────────────────────────────
say "Step 3 — DeploySkoopSuite (from the activator — which it makes permanent on all four)"
PC_TOKEN=$SKOOP PC_WIND_DOWN_CONTROLLER=$WDC PC_OWNER_WALLET=$OWNER PC_TEAM_WALLET=$TEAM PC_OPERATOR=$OPERATOR \
PC_POSITION_MANAGER=$NPM PC_USDC=$USDC PC_WETH=$WETH PC_FEE_RECIPIENT=$FEE_RECIPIENT \
PC_PER_TX_FLOOR=1 PC_PER_TX_MAX=50000000000 \
  forge script script/DeploySkoopSuite.s.sol --rpc-url "$RPC" --broadcast --unlocked --sender $ACTIVATOR >/dev/null
SUITE=broadcast/DeploySkoopSuite.s.sol/8453/run-latest.json
ESCROW=$(addr_of $SUITE RewardEscrow); VESTING=$(addr_of $SUITE VestingWallet)
TREASURY=$(addr_of $SUITE TreasuryTimelock); LOCKER=$(addr_of $SUITE LPLockerPilot)
echo "escrow   $ESCROW"; echo "vesting  $VESTING"; echo "treasury $TREASURY"; echo "locker   $LOCKER"

# ── step 4: fund — from what the owner wallet actually holds ────────────────────
say "Step 4 — fund escrow 45M, vesting 15M, treasury with what is left"
ESC_AMT=45000000000000; VEST_AMT=15000000000000
TSY_AMT=$(python3 -c "print($OWNER_BAL-$ESC_AMT-$VEST_AMT)")
tx $OWNER $SKOOP "transfer(address,uint256)" $ESCROW $ESC_AMT
tx $OWNER $SKOOP "transfer(address,uint256)" $VESTING $VEST_AMT
tx $OWNER $SKOOP "transfer(address,uint256)" $TREASURY $TSY_AMT
echo "treasury funded with $(skoop $TSY_AMT) (target 10,000,000 — short by $(skoop $((10000000000000-TSY_AMT))))"

# ── step 5: the live pools go into the locker, then the reserve, then initializeLP ──
say "Step 5 — move the seeded positions and the reserve into the locker"
for id in $USDC_NFT $ETH_NFT; do        # uncollected fees first: they belong to the LP wallet, not the locker
  tx $LP_WALLET $NPM "collect((uint256,address,uint128,uint128))" "($id,$LP_WALLET,340282366920938463463374607431768211455,340282366920938463463374607431768211455)" "${NESTED[@]}"
  tx $LP_WALLET $NPM "transferFrom(address,address,uint256)" $LP_WALLET $LOCKER $id
done
# The reserve is what the LP wallet held BEFORE collecting — the collected fees are its own.
tx $LP_WALLET $SKOOP "transfer(address,uint256)" $LOCKER $LP_BAL
tx $ACTIVATOR $LOCKER "initializeLP(uint256,uint256,uint24,uint24)" $USDC_NFT $ETH_NFT 10000 10000 "${NESTED[@]}"
echo "locker owns #$USDC_NFT: $(call $NPM 'ownerOf(uint256)(address)' $USDC_NFT)"
echo "locker reserve: $(skoop "$(call $SKOOP 'balanceOf(address)(uint256)' $LOCKER | num)")"

say "Step 5b — activate all four (starts every clock)"
for c in $ESCROW $VESTING $TREASURY $LOCKER; do tx $ACTIVATOR $c "activate()"; done

# ── step 7: governance approves the five code hashes ────────────────────────────
say "Step 7 — multisig approves the five codehashes"
for pair in "MERCHANT_TOKEN:$SKOOP" "REWARD_ESCROW:$ESCROW" "VESTING_WALLET:$VESTING" "TREASURY_TIMELOCK:$TREASURY" "LP_LOCKER:$LOCKER"; do
  role=$(cast keccak "${pair%%:*}"); target=${pair##*:}
  hash=$(cast keccak "$(cast code --rpc-url "$RPC" $target)")
  tx $MULTISIG $WDC "setApprovedCode(bytes32,bytes32,bool)" $role $hash true
  echo "  ${pair%%:*} $hash"
done

# ── step 8: the verifier ────────────────────────────────────────────────────────
say "Step 8 — VerifyManualSuite (pilot mode)"
PC_WIND_DOWN_CONTROLLER=$WDC PC_TOKEN=$SKOOP PC_ESCROW=$ESCROW PC_VESTING=$VESTING PC_TREASURY=$TREASURY \
PC_LOCKER=$LOCKER PC_EXPECT_OWNER=$OWNER PC_EXPECT_TEAM=$TEAM PC_EXPECT_OPERATOR=$OPERATOR \
PC_USDC_POOL=$USDC_POOL PC_ETH_POOL=$ETH_POOL PC_USDC=$USDC PC_WETH=$WETH PC_ETH_USD_FEED=$ETH_FEED \
PC_POSITION_MANAGER=$NPM PC_ROUTER=$ROUTER PC_MODE=pilot \
  forge script script/VerifyManualSuite.s.sol --rpc-url "$RPC" 2>&1 | sed -n '/== Logs ==/,$p' | grep -vE "^== Logs ==|^\s*$"

# ── step 11: register ───────────────────────────────────────────────────────────
say "Step 11 — multisig appoints a registrar; registrar calls registerManual"
tx $MULTISIG $WDC "setRegistrar(address,bool)" $REGISTRAR true
tx $REGISTRAR $WDC "registerManual(address,address,address,address,address)" $SKOOP $ESCROW $VESTING $TREASURY $LOCKER
echo "isRegistered: $(call $WDC 'isRegistered(address)(bool)' $SKOOP)"

# ── step 12: it works ───────────────────────────────────────────────────────────
say "Step 12 — the router serves SKOOP, the POS drawer pays a reward, a customer sells"
echo "router fee tiers: $(call $ROUTER 'getPoolFeeTiers(address)(uint24,uint24)' $SKOOP | tr '\n' ' ')"
cast rpc --rpc-url "$RPC" evm_increaseTime 86400 >/dev/null; cast rpc --rpc-url "$RPC" evm_mine >/dev/null
echo "operator drawer available after 1 day: $(skoop "$(call $ESCROW 'drawerAvailable(address)(uint256)' $OPERATOR | num)")"
tx $OPERATOR $ESCROW "distributeReward(address,uint256)" $CUSTOMER 1000000000
echo "customer SKOOP after a 1,000 reward: $(skoop "$(call $SKOOP 'balanceOf(address)(uint256)' $CUSTOMER | num)")"
tx $CUSTOMER $SKOOP "approve(address,uint256)" $ROUTER 1000000000
DEADLINE=$(( $(cast block --rpc-url "$RPC" -f timestamp) + 600 ))
tx $CUSTOMER $ROUTER "swap((address,address,uint256,uint256,uint256,address,address,uint256))" \
  "($SKOOP,$USDC,1000000000,0,0,0x0000000000000000000000000000000000000000,$CUSTOMER,$DEADLINE)" "${NESTED[@]}"
echo "customer USDC after selling 1,000 SKOOP through the router: $(python3 -c "print($(call $USDC 'balanceOf(address)(uint256)' $CUSTOMER | num)/1e6)")"
echo "fee recipient USDC: $(python3 -c "print($(call $USDC 'balanceOf(address)(uint256)' $FEE_RECIPIENT | num)/1e6)")"
say "Rehearsal complete — nothing was sent to Base"
