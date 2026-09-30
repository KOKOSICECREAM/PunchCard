#!/usr/bin/env bash
# Step 5 — option B liquidity. Signer: the LP wallet, Ledger #25.
#   mint a ~$1 full-range USDC/SKOOP position and a ~$1 ETH/SKOOP position in SKOOP's own
#   1% pools, move both NFTs to the locker, then send every SKOOP the LP wallet has left as the
#   reserve. The real launch positions #6100109 / #6100112 are NOT touched.
# initializeLP and activate() follow in 5b (activator) — the reserve must be in before init.
source "$(dirname "$0")/lib.sh"
LOCKER=$(st_get suite.locker); [ -n "$LOCKER" ] || die "no suite in $STATE — run step 3 first"
[ "$(call $LOCKER 'isInitialized()(bool)')" = true ] && { echo "locker already initialized — nothing to do"; exit 0; }

say "Step 5 — starter positions + reserve into the locker"
use_signer "$LP_WALLET" "$LP_PATH"
same "$(call $NPM 'ownerOf(uint256)(address)' $REAL_USDC_NFT)" "$LP_WALLET" "real #$REAL_USDC_NFT stays in the LP wallet"
same "$(call $NPM 'ownerOf(uint256)(address)' $REAL_ETH_NFT)"  "$LP_WALLET" "real #$REAL_ETH_NFT stays in the LP wallet"

mint(){  # key pair amount skoopDesired pairMin skoopMin
  local key=$1 id; id=$(st_get starter.$key)
  if [ -n "$id" ]; then echo "  - starter $key position already minted: #$id"; return; fi
  local dl=$(( $(cast block --rpc-url "$RPC" -f timestamp) + 1200 ))
  tx "mint starter $key position" $NPM \
    "mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))" \
    "($2,$SKOOP,10000,-887200,887200,$3,$4,$5,$6,$LP_WALLET,$dl)" "${GAS[@]}"
  id=$(echo "$RECEIPT" | python3 -c "
import sys,json
r=json.load(sys.stdin); T='0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef'
print(next(int(l['topics'][3],16) for l in r['logs'] if l['address'].lower()=='$NPM'.lower() and l['topics'][0]==T and int(l['topics'][1],16)==0))")
  st_set starter.$key "$id"; echo "    -> #$id"; }

if [ -z "$(st_get starter.usdc)" ] || [ -z "$(st_get starter.eth)" ]; then
  ge "$(bal $USDC $LP_WALLET)" $STARTER_USDC || die "LP wallet needs $STARTER_USDC raw USDC"
  ge "$(call $SKOOP 'allowance(address,address)(uint256)' $LP_WALLET $NPM)" 2700000000 || tx "approve SKOOP" $SKOOP "approve(address,uint256)" $NPM 2700000000
  ge "$(call $USDC 'allowance(address,address)(uint256)' $LP_WALLET $NPM)" $STARTER_USDC || tx "approve USDC" $USDC "approve(address,uint256)" $NPM $STARTER_USDC
  ge "$(bal $WETH $LP_WALLET)" $STARTER_WETH || tx "wrap ETH" $WETH "deposit()" --value $STARTER_WETH
  ge "$(call $WETH 'allowance(address,address)(uint256)' $LP_WALLET $NPM)" $STARTER_WETH || tx "approve WETH" $WETH "approve(address,uint256)" $NPM $STARTER_WETH
fi
# The pair side is the limit; SKOOP desired is set high and the unused part stays in the wallet.
mint usdc $USDC $STARTER_USDC 1300000000 950000 900000000
mint eth  $WETH $STARTER_WETH 1400000000 380000000000000 900000000
for key in usdc eth; do id=$(st_get starter.$key)
  if [ "$(lc "$(call $NPM 'ownerOf(uint256)(address)' $id)")" = "$(lc $LOCKER)" ]; then echo "  - #$id already in the locker"
  else tx "move #$id into the locker" $NPM "transferFrom(address,address,uint256)" $LP_WALLET $LOCKER $id; fi
done
LEFT=$(bal $SKOOP $LP_WALLET)
if ! ge 0 "$LEFT"; then tx "send the reserve ($(fmt6 "$LEFT") SKOOP)" $SKOOP "transfer(address,uint256)" $LOCKER "$LEFT"
else echo "  - LP wallet has no SKOOP left; locker holds $(fmt6 "$(bal $SKOOP $LOCKER)")"; fi

settle; say "Check"
echo "  locker holds $(fmt6 "$(bal $SKOOP $LOCKER)") SKOOP · starter #$(st_get starter.usdc) / #$(st_get starter.eth) owned by the locker"
echo "  real #$REAL_USDC_NFT / #$REAL_ETH_NFT still owned by $(call $NPM 'ownerOf(uint256)(address)' $REAL_USDC_NFT)"
echo "Next: bash script/deploy/skoop/5b-init-activate.sh  (owner/activator, Ledger #40)"
