#!/usr/bin/env bash
# Step 11 — the registrar admits SKOOP to the network. THE ONLY IRREVERSIBLE STEP: register()
# sets a flag nothing clears; the only exit afterwards is a 365-day wind-down. Reruns the
# verifier first and requires a typed REGISTER.
source "$(dirname "$0")/lib.sh"
need REGISTRAR
[ "$(call $WDC 'isRegistered(address)(bool)' $SKOOP)" = true ] && { echo "SKOOP is already registered."; exit 0; }
bash script/deploy/skoop/8-verify.sh >/dev/null 2>&1 || die "the verifier does not pass now — run 8-verify.sh to see why"

ESCROW=$(st_get suite.escrow); VESTING=$(st_get suite.vesting); TREASURY=$(st_get suite.treasury); LOCKER=$(st_get suite.locker)
say "Step 11 — registerManual"
echo "  token $SKOOP"; echo "  escrow $ESCROW"; echo "  vesting $VESTING"; echo "  treasury $TREASURY"; echo "  locker $LOCKER"
if [ "${SKOOP_UNLOCKED:-0}" = 1 ]; then use_signer "$REGISTRAR" unlocked
elif [ -n "$REGISTRAR_PATH" ]; then use_signer "$REGISTRAR" "$REGISTRAR_PATH"
else die "set REGISTRAR_PATH (its Ledger path) in lib.sh"; fi
if [ "${SKOOP_UNLOCKED:-0}" != 1 ]; then
  read -r -p "This cannot be undone. Type REGISTER to admit SKOOP to the PunchCard Network: " ok
  [ "$ok" = REGISTER ] || { echo "Not registered."; exit 1; }
fi
tx "registerManual" $WDC "registerManual(address,address,address,address,address)" $SKOOP $ESCROW $VESTING $TREASURY $LOCKER
[ "$(call $WDC 'isRegistered(address)(bool)' $SKOOP)" = true ] || die "not registered after the tx"
echo "  ✓ SKOOP is on the PunchCard Network · router fee tiers: $(cast call --rpc-url "$RPC" $ROUTER 'getPoolFeeTiers(address)(uint24,uint24)' $SKOOP | tr '\n' ' ')"
st_set progress.registered yes
