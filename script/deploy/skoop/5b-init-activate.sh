#!/usr/bin/env bash
# Step 5b — initializeLP with the starter positions, then activate() all four contracts,
# which starts every clock: emission, vesting, treasury, the locker's (pilot: open) hatch.
# Signer: the activator keystore. Skips whatever is already done.
source "$(dirname "$0")/lib.sh"
need ACTIVATOR
ESCROW=$(st_get suite.escrow); VESTING=$(st_get suite.vesting); TREASURY=$(st_get suite.treasury); LOCKER=$(st_get suite.locker)
U=$(st_get starter.usdc); E=$(st_get starter.eth)
[ -n "$U" ] && [ -n "$E" ] || die "no starter positions in $STATE — run step 5 first"
same "$(call $NPM 'ownerOf(uint256)(address)' $U)" "$LOCKER" "starter #$U owner"
same "$(call $NPM 'ownerOf(uint256)(address)' $E)" "$LOCKER" "starter #$E owner"

say "Step 5b — initialise and activate"
use_signer "$ACTIVATOR" "keystore:$ACTIVATOR_KEYSTORE"
if [ "$(call $LOCKER 'isInitialized()(bool)')" = true ]; then echo "  - locker already initialized"
else
  [ "$(bal $SKOOP $LOCKER)" -gt 0 ] || die "the reserve is not in the locker — initializeLP would record zero forever"
  tx "initializeLP(#$U, #$E)" $LOCKER "initializeLP(uint256,uint256,uint24,uint24)" $U $E 10000 10000 "${GAS[@]}"
fi
for pair in escrow:$ESCROW vesting:$VESTING treasury:$TREASURY locker:$LOCKER; do
  c=${pair#*:}
  if [ "$(call $c 'activatedAt()(uint256)')" != 0 ]; then echo "  - ${pair%%:*} already activated"
  else tx "activate ${pair%%:*}" $c "activate()"; fi
done

say "Check"
echo "  locker initialized $(call $LOCKER 'isInitialized()(bool)') · reserve $(fmt6 "$(call $LOCKER 'reserveTokens()(uint256)')") · evacuationOpen $(call $LOCKER 'evacuationOpen()(bool)')"
for c in $ESCROW $VESTING $TREASURY $LOCKER; do [ "$(call $c 'activatedAt()(uint256)')" != 0 ] || die "$c not activated"; done
st_set progress.activated yes
echo "Next: bash script/deploy/skoop/6-sourcify.sh"
