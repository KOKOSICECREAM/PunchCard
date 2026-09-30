#!/usr/bin/env bash
# Add liquidity to SKOOP's locked positions: pair USDC and/or ETH from the owner wallet with
# SKOOP from the locker's reserve. Signer: the owner wallet, Ledger #40.
#
#   bash script/deploy/skoop/add-lp.sh --usdc 500             # $500 USDC + matching reserve SKOOP
#   bash script/deploy/skoop/add-lp.sh --eth 0.25             # 0.25 ETH (wrapped first if needed)
#   bash script/deploy/skoop/add-lp.sh --usdc 500 --eth 0.25  # both pools in one tx
#
# The USDC/ETH must already be in the owner wallet (a donation goes to 0x5426…, not the locker).
# The SKOOP side comes from the reserve and is sized from each pool's live price. Uniswap takes
# the pair amount in full and the SKOOP it needs; unused SKOOP stays in the reserve, and unused
# USDC/WETH comes back to the owner wallet. Slippage: 1% on both sides of each pool.
#
# What this cannot undo: liquidity added here has no partial exit. It earns no fees for you —
# the locker's fees burn the SKOOP side and send the pair side to the PunchCard fee recipient.
# The real launch positions #6100109 / #6100112 in the LP wallet are not touched.
source "$(dirname "$0")/lib.sh"
LOCKER=$(st_get suite.locker); [ -n "$LOCKER" ] || die "no suite in $STATE"
SLIP_BPS=100     # 1%
PAD_BPS=200      # SKOOP desired = price × 1.02, so the pair side is the one that binds

USDC_IN=0; ETH_IN=0
while [ $# -gt 0 ]; do case $1 in
  --usdc) USDC_IN=$2; shift 2;;
  --eth)  ETH_IN=$2;  shift 2;;
  *) die "unknown argument $1 — use --usdc AMOUNT and/or --eth AMOUNT";;
esac; done
USDC_RAW=$(python3 -c "from decimal import Decimal as D; print(int(D('$USDC_IN')*10**6))")
WETH_RAW=$(python3 -c "from decimal import Decimal as D; print(int(D('$ETH_IN')*10**18))")
[ "$USDC_RAW" != 0 ] || [ "$WETH_RAW" != 0 ] || die "nothing to add — pass --usdc and/or --eth"

say "Locker state"
[ "$(call $LOCKER 'isInitialized()(bool)')" = true ] || die "locker not initialised"
[ "$(call $LOCKER 'isFrozen()(bool)')" = false ]     || die "locker is frozen (evacuated or winding down) — nothing can be added"
RESERVE=$(call $LOCKER 'reserveTokens()(uint256)')
LIQ_U0=$(call $LOCKER 'currentUsdcLiquidity()(uint128)'); LIQ_E0=$(call $LOCKER 'currentEthLiquidity()(uint128)')
echo "  reserve $(fmt6 "$RESERVE") SKOOP"

# SKOOP is token1 in both pools (0x8335… and 0x4200… both sort below 0xBa14…), so
# (sqrtPriceX96 / 2^96)^2 is raw SKOOP per raw pair token. Checked, not assumed:
[ "$(lc "$(call $USDC_POOL 'token1()(address)')")" = "$(lc $SKOOP)" ] || die "SKOOP is not token1 in the USDC pool"
[ "$(lc "$(call $ETH_POOL  'token1()(address)')")" = "$(lc $SKOOP)" ] || die "SKOOP is not token1 in the ETH pool"
# plan PAIR_RAW POOL → "desired min pairMin" in raw SKOOP / raw pair
plan(){ local sq; sq=$(call "$2" 'slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)' | head -1)
  python3 -c "
a=$1; p=($sq/2**96)**2
print(int(a*p*(10000+$PAD_BPS)/10000), int(a*p*(10000-$SLIP_BPS)/10000), a*(10000-$SLIP_BPS)//10000)"; }
price(){ local sq; sq=$(call "$1" 'slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)' | head -1)
  python3 -c "print(f'{1/(($sq/2**96)**2)*10**($2):.10f}'.rstrip('0'))"; }   # USD per SKOOP (0) / ETH per SKOOP (-12)

read -r U_DES U_MIN U_PMIN <<< "$( [ "$USDC_RAW" != 0 ] && plan "$USDC_RAW" $USDC_POOL || echo "0 0 0")"
read -r E_DES E_MIN E_PMIN <<< "$( [ "$WETH_RAW" != 0 ] && plan "$WETH_RAW" $ETH_POOL  || echo "0 0 0")"
ge "$RESERVE" $((U_DES + E_DES)) || die "needs $(fmt6 $((U_DES+E_DES))) SKOOP, reserve holds $(fmt6 "$RESERVE") — add less"

say "Plan"
[ "$USDC_RAW" != 0 ] && echo "  USDC pool: $USDC_IN USDC + ~$(fmt6 $(( U_DES*10000/(10000+PAD_BPS) ))) SKOOP  (pool price \$$(price $USDC_POOL 0))"
[ "$WETH_RAW" != 0 ] && echo "  ETH pool:  $ETH_IN ETH + ~$(fmt6 $(( E_DES*10000/(10000+PAD_BPS) ))) SKOOP  (pool price $(price $ETH_POOL -12) ETH)"
echo "  SKOOP from reserve at most $(fmt6 $((U_DES+E_DES))); reserve after ≈ $(fmt6 $((RESERVE - (U_DES+E_DES)*10000/(10000+PAD_BPS))))"

use_signer "$OWNER" "$OWNER_PATH"
if [ "$USDC_RAW" != 0 ]; then ge "$(bal $USDC $OWNER)" "$USDC_RAW" || die "owner wallet holds $(fmt6 "$(bal $USDC $OWNER)") USDC, needs $USDC_IN"; fi
if [ "$WETH_RAW" != 0 ]; then
  HAVE_W=$(bal $WETH $OWNER)
  if ! ge "$HAVE_W" "$WETH_RAW"; then
    WRAP=$(python3 -c "print($WETH_RAW-$HAVE_W)")
    ge "$(cast balance $OWNER --rpc-url "$RPC")" "$(python3 -c "print($WRAP+200000000000000)")" || die "owner wallet lacks $ETH_IN ETH plus gas"
  fi
fi

if [ "${SKOOP_UNLOCKED:-0}" != 1 ]; then
  read -r -p "Type ADD to send (owner Ledger #40 will ask to sign each tx): " ok; [ "$ok" = ADD ] || die "stopped — nothing sent"
fi

say "Send"
[ -n "${WRAP:-}" ] && tx "wrap $(python3 -c "print($WRAP/1e18)") ETH" $WETH "deposit()" --value "$WRAP"
# Exact allowances; the locker pulls exactly these and returns any unused part.
[ "$USDC_RAW" != 0 ] && { ge "$(call $USDC 'allowance(address,address)(uint256)' $OWNER $LOCKER)" "$USDC_RAW" || tx "approve $USDC_IN USDC to the locker" $USDC "approve(address,uint256)" $LOCKER "$USDC_RAW"; }
[ "$WETH_RAW" != 0 ] && { ge "$(call $WETH 'allowance(address,address)(uint256)' $OWNER $LOCKER)" "$WETH_RAW" || tx "approve $ETH_IN WETH to the locker" $WETH "approve(address,uint256)" $LOCKER "$WETH_RAW"; }
# addLiquidity(usdcTokenAmount, ethTokenAmount, usdcPairAmount, ethPairAmount,
#              usdcTokenMin, usdcPairMin, ethTokenMin, ethPairMin)
tx "addLiquidity" $LOCKER "addLiquidity(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)" \
  "$U_DES" "$E_DES" "$USDC_RAW" "$WETH_RAW" "$U_MIN" "$U_PMIN" "$E_MIN" "$E_PMIN" --gas-limit 1500000
TXH=$(echo "$RECEIPT" | python3 -c "import sys,json;print(json.load(sys.stdin)['transactionHash'])")

settle; say "Check"
RESERVE1=$(call $LOCKER 'reserveTokens()(uint256)')
LIQ_U1=$(call $LOCKER 'currentUsdcLiquidity()(uint128)'); LIQ_E1=$(call $LOCKER 'currentEthLiquidity()(uint128)')
USED=$((RESERVE - RESERVE1))
echo "  SKOOP from reserve $(fmt6 $USED) · reserve now $(fmt6 "$RESERVE1")"
echo "  USDC position liquidity $LIQ_U0 → $LIQ_U1 · ETH position liquidity $LIQ_E0 → $LIQ_E1"
[ "$USDC_RAW" = 0 ] || ge "$LIQ_U1" $((LIQ_U0 + 1)) || die "USDC position liquidity did not grow"
[ "$WETH_RAW" = 0 ] || ge "$LIQ_E1" $((LIQ_E0 + 1)) || die "ETH position liquidity did not grow"
same "$(call $NPM 'ownerOf(uint256)(address)' $REAL_USDC_NFT)" "$LP_WALLET" "real #$REAL_USDC_NFT"
same "$(call $NPM 'ownerOf(uint256)(address)' $REAL_ETH_NFT)"  "$LP_WALLET" "real #$REAL_ETH_NFT"
echo "  real #$REAL_USDC_NFT / #$REAL_ETH_NFT untouched in the LP wallet"

python3 - "$STATE" "$TXH" "$USDC_RAW" "$WETH_RAW" "$USED" "$RESERVE1" <<'PY'
import json,sys,collections,datetime
p,h,u,w,used,res=sys.argv[1:7]
d=json.load(open(p),object_pairs_hook=collections.OrderedDict)
d.setdefault('liquidityAdded',[]).append(collections.OrderedDict(
  date=datetime.date.today().isoformat(),tx=h,usdcRaw=int(u),wethRaw=int(w),skoopFromReserveRaw=int(used),reserveAfterRaw=int(res)))
json.dump(d,open(p,'w'),indent=2); open(p,'a').write('\n')
PY
echo "  recorded in $STATE → liquidityAdded"
