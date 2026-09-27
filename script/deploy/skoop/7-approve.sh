#!/usr/bin/env bash
# Step 7 — governance (Ledger #41) approves the five runtime codehashes and appoints the
# registrar. Up to six transactions; any already done are skipped. Needs ~0.0005 ETH on #41.
source "$(dirname "$0")/lib.sh"
need REGISTRAR
[ "$(lc "$REGISTRAR")" != "$(lc "$GOVERNANCE")" ] || die "the registrar must not be the governance key — review and admission are two keys"
[ "${SKOOP_UNLOCKED:-0}" = 1 ] || [ "$(st_get progress.sourcify)" = yes ] || die "publish the source first (step 6)"
ESCROW=$(st_get suite.escrow); VESTING=$(st_get suite.vesting); TREASURY=$(st_get suite.treasury); LOCKER=$(st_get suite.locker)

say "Step 7 — approve codehashes, appoint the registrar"
use_signer "$GOVERNANCE" "$GOV_PATH"
for pair in "MERCHANT_TOKEN:$SKOOP" "REWARD_ESCROW:$ESCROW" "VESTING_WALLET:$VESTING" "TREASURY_TIMELOCK:$TREASURY" "LP_LOCKER:$LOCKER"; do
  role=$(cast keccak "${pair%%:*}"); target=${pair#*:}
  hash=$(cast keccak "$(cast code --rpc-url "$RPC" "$target")")
  if [ "$(call $WDC 'approvedCode(bytes32,bytes32)(bool)' $role $hash)" = true ]; then echo "  - ${pair%%:*} already approved ($hash)"
  else tx "approve ${pair%%:*} $hash" $WDC "setApprovedCode(bytes32,bytes32,bool)" $role $hash true; fi
done
if [ "$(call $WDC 'registrars(address)(bool)' $REGISTRAR)" = true ]; then echo "  - $REGISTRAR already a registrar"
else tx "appoint registrar $REGISTRAR" $WDC "setRegistrar(address,bool)" $REGISTRAR true; fi
st_set progress.approved yes
echo "Next: bash script/deploy/skoop/8-verify.sh — then 4-fund.sh; the 60M goes in only once everything else is proven"
