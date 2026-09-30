#!/usr/bin/env bash
# Step 6 — publish the suite's source on Sourcify BEFORE governance approves its codehashes:
# approving code nobody can read is a rubber stamp. No signer. Stops unless all four are
# exact matches (creation and runtime).
source "$(dirname "$0")/lib.sh"
[ "${SKOOP_UNLOCKED:-0}" = 1 ] && { echo "fork rehearsal: Sourcify cannot see fork contracts — skipped"; exit 0; }
say "Step 6 — verify the suite on Sourcify"
for pair in escrow:contracts/RewardEscrow.sol:RewardEscrow vesting:contracts/VestingWallet.sol:VestingWallet \
            treasury:contracts/TreasuryTimelock.sol:TreasuryTimelock locker:contracts/pilot/LPLockerPilot.sol:LPLockerPilot; do
  a=$(st_get suite.${pair%%:*}); id=${pair#*:}
  forge verify-contract "$a" "$id" --chain base --verifier sourcify --watch 2>&1 | grep -iE "exact_match|already verified|error" | head -1
done
for k in escrow vesting treasury locker; do
  m=$(curl -s -m 30 "https://sourcify.dev/server/v2/contract/8453/$(st_get suite.$k)" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('creationMatch'),d.get('runtimeMatch'))")
  [ "$m" = "exact_match exact_match" ] || die "$k is not an exact match on Sourcify ($m)"
  echo "  ✓ $k exact_match"
done
st_set progress.sourcify yes
echo "Next: bash script/deploy/skoop/7-approve.sh  (governance, Ledger #41)"
