#!/usr/bin/env bash
# Step 4 — fund the escrow (45M), vesting (15M) and treasury (the rest: 9,544,083).
# Signer: the owner wallet, Ledger #40. Three transfers; each is skipped if already done.
source "$(dirname "$0")/lib.sh"
ESCROW=$(st_get suite.escrow); VESTING=$(st_get suite.vesting); TREASURY=$(st_get suite.treasury)
[ -n "$TREASURY" ] || die "no suite in $STATE — run 3-deploy-suite.sh first"

say "Step 4 — fund the suite from the owner wallet"
use_signer "$OWNER" "$OWNER_PATH"
fund(){ local name=$1 to=$2 want=$3 have; have=$(bal $SKOOP "$to")
  if ge "$have" "$want"; then echo "  - $name already holds $(fmt6 "$have")"; return; fi
  tx "fund $name with $(fmt6 $((want-have)))" $SKOOP "transfer(address,uint256)" "$to" $((want-have)); }
fund escrow  "$ESCROW"  $ESCROW_FUND
fund vesting "$VESTING" $VESTING_FUND
REST=$(bal $SKOOP $OWNER)
if ! ge 0 "$REST"; then tx "fund treasury with the remaining $(fmt6 "$REST")" $SKOOP "transfer(address,uint256)" "$TREASURY" "$REST"
else echo "  - owner holds nothing more; treasury holds $(fmt6 "$(bal $SKOOP "$TREASURY")")"; fi

settle; say "Check"
echo "  escrow $(fmt6 "$(bal $SKOOP "$ESCROW")") · vesting $(fmt6 "$(bal $SKOOP "$VESTING")") · treasury $(fmt6 "$(bal $SKOOP "$TREASURY")") · owner left $(fmt6 "$(bal $SKOOP $OWNER)")"
[ "$(bal $SKOOP $OWNER)" = 0 ] || die "owner still holds SKOOP"
st_set progress.funded yes
echo "Next: bash script/deploy/skoop/8-verify.sh, then 11-register.sh  (registrar, Ledger #43)"
