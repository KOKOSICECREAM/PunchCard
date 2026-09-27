#!/usr/bin/env bash
# Step 3 — deploy SKOOP's four suite contracts. Signer: the ACTIVATOR keystore, which the
# contracts record as their activator forever (only it can initializeLP and activate()).
#
# Create the activator first, in a separate terminal:
#   cast wallet new                                  # note the address and private key
#   cast wallet import pc-skoop-activator --interactive
# then fund it with ~0.001 ETH on Base.
#
# Every constructor value is read back on-chain afterwards and compared.
source "$(dirname "$0")/lib.sh"
need TEAM_WALLET ACTIVATOR OPERATOR

say "Step 3 — deploy the suite"
if [ -n "$(st_get suite.locker)" ]; then
  for k in escrow vesting treasury locker; do has_code "$(st_get suite.$k)" || die "state names suite.$k but it has no code"; done
  echo "  already deployed — checking it"
else
  use_signer "$ACTIVATOR" "keystore:$ACTIVATOR_KEYSTORE"
  # forge script takes --sender, not cast's --from: in rehearsal mode pass only --unlocked.
  if [ "${SKOOP_UNLOCKED:-0}" = 1 ]; then FORGE_SIGN=(--unlocked); else FORGE_SIGN=("${SIGN[@]}"); fi
  wait_mined
  PC_TOKEN=$SKOOP PC_WIND_DOWN_CONTROLLER=$WDC PC_OWNER_WALLET=$OWNER PC_TEAM_WALLET=$TEAM_WALLET \
  PC_OPERATOR=$OPERATOR PC_POSITION_MANAGER=$NPM PC_USDC=$USDC PC_WETH=$WETH PC_FEE_RECIPIENT=$FEE_RECIPIENT \
  PC_PER_TX_FLOOR=$PER_TX_FLOOR PC_PER_TX_MAX=$PER_TX_MAX \
    forge script script/DeploySkoopSuite.s.sol --rpc-url "$RPC" "${FORGE_SIGN[@]}" --sender "$ACTIVATOR" --broadcast \
      > "${TMPDIR:-/tmp}/skoop-deploy-suite.log" 2>&1 || { tail -20 "${TMPDIR:-/tmp}/skoop-deploy-suite.log"; die "DeploySkoopSuite failed"; }
  B=broadcast/DeploySkoopSuite.s.sol/8453/run-latest.json
  for pair in escrow:RewardEscrow vesting:VestingWallet treasury:TreasuryTimelock locker:LPLockerPilot; do
    a=$(python3 -c "import json;d=json.load(open('$B'));print(next(t['contractAddress'] for t in d['transactions'] if t['contractName']=='${pair#*:}' and t['transactionType']=='CREATE'))")
    st_set suite.${pair%%:*} "$(cast to-check-sum-address "$a")"
  done
  st_set suite.deployBlock "$(cast block-number --rpc-url "$RPC")"
fi
ESCROW=$(st_get suite.escrow); VESTING=$(st_get suite.vesting); TREASURY=$(st_get suite.treasury); LOCKER=$(st_get suite.locker)
echo "  escrow $ESCROW · vesting $VESTING · treasury $TREASURY · locker $LOCKER"

say "Constructor values, read back"
for c in $ESCROW $VESTING $TREASURY $LOCKER; do same "$(call $c 'activator()(address)')" "$ACTIVATOR" "activator of $c"; done
same "$(call $ESCROW 'token()(address)')"              "$SKOOP"  "escrow.token"
same "$(call $ESCROW 'ownerWallet()(address)')"        "$OWNER"  "escrow.ownerWallet"
same "$(call $ESCROW 'windDownController()(address)')" "$WDC"    "escrow.windDownController"
[ "$(call $ESCROW 'REWARDS_ALLOCATION()(uint256)')" = "$ESCROW_FUND" ] || die "escrow allocation"
[ "$(call $ESCROW 'perTxFloor()(uint256)')" = "$PER_TX_FLOOR" ] && [ "$(call $ESCROW 'perTxMax()(uint256)')" = "$PER_TX_MAX" ] || die "escrow per-tx bounds"
cast call --rpc-url "$RPC" $ESCROW 'getDrawer(address)((uint128,uint128,uint64,bool))' $OPERATOR | grep -q true || die "operator drawer not active"
same "$(call $VESTING 'teamWallet()(address)')"         "$TEAM_WALLET" "vesting.teamWallet"
same "$(call $VESTING 'windDownController()(address)')" "$WDC"         "vesting.windDownController"
[ "$(call $VESTING 'CLIFF_DURATION()(uint256)')" = 2592000 ] && [ "$(call $VESTING 'VEST_DURATION()(uint256)')" = 63072000 ] || die "vesting schedule"
same "$(call $TREASURY 'ownerWallet()(address)')"        "$OWNER" "treasury.ownerWallet"
same "$(call $TREASURY 'windDownController()(address)')" "$WDC"   "treasury.windDownController"
[ "$(call $TREASURY 'TIMELOCK_DURATION()(uint256)')" = 604800 ] || die "treasury delay (7 days)"
same "$(call $LOCKER 'merchantToken()(address)')"         "$SKOOP"         "locker.merchantToken"
same "$(call $LOCKER 'ownerWallet()(address)')"           "$OWNER"         "locker.ownerWallet"
same "$(call $LOCKER 'windDownController()(address)')"    "$WDC"           "locker.windDownController"
same "$(call $LOCKER 'punchcardFeeRecipient()(address)')" "$FEE_RECIPIENT" "locker.punchcardFeeRecipient"
same "$(call $LOCKER 'positionManager()(address)')"       "$NPM"           "locker.positionManager"
[ "$(call $LOCKER 'HAS_UNLIMITED_LP_RECOVERY()(bool)')" = true ] || die "locker is not the pilot lineage"
echo "  ✓ all constructor values match"
echo "Next: bash script/deploy/skoop/4-fund.sh  (owner, Ledger #40)"
