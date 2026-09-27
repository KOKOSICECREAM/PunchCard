#!/usr/bin/env bash
# Step 8 — VerifyManualSuite in pilot mode. Read-only. Two warnings are expected and
# documented in skoop.json: treasury short 455,917 (pre-launch spend) and the locker reserve
# short by the SKOOP in the starter positions. Any FAIL stops the launch.
source "$(dirname "$0")/lib.sh"
need TEAM_WALLET OPERATOR
say "Step 8 — VerifyManualSuite (pilot)"
# The verifier is a PRE-registration check: once SKOOP is on the network it rightly fails
# "already registered". A rerun after registration has nothing left to verify.
if [ "$(call $WDC 'isRegistered(address)(bool)' $SKOOP)" = true ]; then echo "  - SKOOP is already registered; verification was a pre-registration check"; exit 0; fi
PC_WIND_DOWN_CONTROLLER=$WDC PC_TOKEN=$SKOOP PC_ESCROW=$(st_get suite.escrow) PC_VESTING=$(st_get suite.vesting) \
PC_TREASURY=$(st_get suite.treasury) PC_LOCKER=$(st_get suite.locker) PC_EXPECT_OWNER=$OWNER PC_EXPECT_TEAM=$TEAM_WALLET \
PC_EXPECT_OPERATOR=$OPERATOR PC_USDC_POOL=$USDC_POOL PC_ETH_POOL=$ETH_POOL PC_USDC=$USDC PC_WETH=$WETH \
PC_ETH_USD_FEED=$ETH_FEED PC_POSITION_MANAGER=$NPM PC_ROUTER=$ROUTER PC_MODE=pilot \
  forge script script/VerifyManualSuite.s.sol --rpc-url "$RPC" > "${TMPDIR:-/tmp}/skoop-verify.log" 2>&1 || true
REPORT=$(sed -n '/== Logs ==/,$p' "${TMPDIR:-/tmp}/skoop-verify.log" | grep -vE "^== Logs ==|^\s*$")
echo "$REPORT"
# Captured first, then checked: piping into `grep -q` let it exit early, and under pipefail
# the SIGPIPE upstream could make a passing report look like a failure.
if ! echo "$REPORT" | grep -q "PASSED" || echo "$REPORT" | grep -q "DO NOT REGISTER"; then die "verification did not pass — do not register"; fi
st_set progress.verified yes
echo "Next: bash script/deploy/skoop/11-register.sh  (registrar) — the only irreversible step"
