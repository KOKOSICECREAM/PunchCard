#!/usr/bin/env bash
# LPLockerPilot, exercised end to end with the two ~$1 test positions, on a fork of Base.
#
# The test wallet added #6101973 (USDC/SKOOP) and #6101969 (ETH/SKOOP) to SKOOP's own 1%
# pools — the same token, pools, tier and full range as SKOOP's real positions — so this
# is the real shape at a thousandth of the size. The locker is a throwaway: initializeLP is
# once-only and evacuateLP bricks it, so it can never become SKOOP's locker.
#
# Everything runs from the real test wallet via anvil impersonation. Nothing is sent to Base.
#
#   bash script/rehearse/locker-test-fork.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

BASE_RPC=${BASE_RPC:-https://mainnet.base.org}; PORT=${PORT:-8548}; RPC=http://127.0.0.1:$PORT

SKOOP=0xBa147713adF122A8Fc224e52Cb431D7919831939
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
WETH=0x4200000000000000000000000000000000000006
NPM=0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1
SWAP02=0x2626664c2603336E57B271c5C0b26F421741e481
WDC=0x7dbd9CA01fa60aB480f3A4AE7892970C97EF0cac          # the live controller; it never touches this locker
FEE_RECIPIENT=0x6588A99071e0e988071dA4252e9499ddFc752dd1
TESTER=0x7Fe79Bc539d3e8a1B4b14e6788A8D80f3B0510Fd       # owner, activator and NFT holder
USDC_NFT=6101973; ETH_NFT=6101969
RESERVE=50000000                                         # 50 SKOOP reserve
STRANGER=0x000000000000000000000000000000000000dEaD
TRADER=0x00000000000000000000000000000000000C0571

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
must_fail(){ local what=$1 from=$2; shift 2
  local st; st=$(cast send --unlocked --from "$from" --rpc-url "$RPC" "$@" --gas-limit 1000000 --json 2>/dev/null | python3 -c "import sys,json;print(int(json.load(sys.stdin)['status'],16))" 2>/dev/null || echo 0)
  if [ "$st" = 1 ]; then echo "  ✗ $what was ALLOWED"; exit 1; else echo "  ✓ refused: $what"; fi; }
call(){ cast call --rpc-url "$RPC" "$@" | awk '{print $1}'; }
bal(){ call "$1" "balanceOf(address)(uint256)" "$2"; }
liq(){ cast call --rpc-url "$RPC" $NPM 'positions(uint256)(uint96,address,address,address,uint24,int24,int24,uint128,uint256,uint256,uint128,uint128)' "$1" | sed -n 8p | awk '{print $1}'; }

say "Forking Base"
anvil --fork-url "$BASE_RPC" --port "$PORT" --auto-impersonate --silent &
ANVIL=$!; trap 'kill $ANVIL 2>/dev/null' EXIT
for _ in $(seq 1 60); do cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.5; done
echo "fork block $(cast block-number --rpc-url "$RPC")"
for a in $TESTER $STRANGER $TRADER; do cast rpc --rpc-url "$RPC" anvil_setBalance $a 0x8AC7230489E80000 >/dev/null; done  # 10 ETH on the fork
echo "tester: $(bal $SKOOP $TESTER) SKOOP raw; NFTs #$USDC_NFT liq $(liq $USDC_NFT), #$ETH_NFT liq $(liq $ETH_NFT)"

say "1. Deploy LPLockerPilot (tester = owner AND activator)"
LOCKER=$(forge create contracts/pilot/LPLockerPilot.sol:LPLockerPilot --rpc-url "$RPC" --unlocked --from $TESTER --broadcast \
  --constructor-args $SKOOP $TESTER $WDC $NPM $TESTER $USDC $WETH $FEE_RECIPIENT 2>/dev/null | awk '/Deployed to:/{print $3}')
echo "locker $LOCKER  evacuationOpen=$(call $LOCKER 'evacuationOpen()(bool)')  HAS_UNLIMITED_LP_RECOVERY=$(call $LOCKER 'HAS_UNLIMITED_LP_RECOVERY()(bool)')"

say "2. Move both NFTs in, then the reserve, then initializeLP — in that order"
tx $TESTER $NPM "transferFrom(address,address,uint256)" $TESTER $LOCKER $USDC_NFT
tx $TESTER $NPM "transferFrom(address,address,uint256)" $TESTER $LOCKER $ETH_NFT
tx $TESTER $SKOOP "transfer(address,uint256)" $LOCKER $RESERVE
must_fail "initializeLP by a stranger" $STRANGER $LOCKER "initializeLP(uint256,uint256,uint24,uint24)" $USDC_NFT $ETH_NFT 10000 10000
tx $TESTER $LOCKER "initializeLP(uint256,uint256,uint24,uint24)" $USDC_NFT $ETH_NFT 10000 10000 "${NESTED[@]}"
echo "  initialized=$(call $LOCKER 'isInitialized()(bool)')  reserve=$(call $LOCKER 'reserveTokens()(uint256)') (sent $RESERVE)  fee tiers $(call $LOCKER 'usdcFeeTier()(uint24)')/$(call $LOCKER 'ethFeeTier()(uint24)')"
echo "  NFT owners: $(call $NPM 'ownerOf(uint256)(address)' $USDC_NFT) $(call $NPM 'ownerOf(uint256)(address)' $ETH_NFT)"
must_fail "initializeLP a second time" $TESTER $LOCKER "initializeLP(uint256,uint256,uint24,uint24)" $USDC_NFT $ETH_NFT 10000 10000

say "3. Activate"
must_fail "activate by a stranger" $STRANGER $LOCKER "activate()"
tx $TESTER $LOCKER "activate()"
echo "  activatedAt=$(call $LOCKER 'activatedAt()(uint256)')  evacuationOpen=$(call $LOCKER 'evacuationOpen()(bool)') (pilot: no deadline)"

say "4. Real trading through the pools, then collectFees (callable by anyone)"
for i in 1 2 3; do
  tx $TRADER $SWAP02 "exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))" "($WETH,$SKOOP,10000,$TRADER,50000000000000000,0,0)" --value 0.05ether "${NESTED[@]}"
  SK=$(bal $SKOOP $TRADER); tx $TRADER $SKOOP "approve(address,uint256)" $SWAP02 $SK
  tx $TRADER $SWAP02 "exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))" "($SKOOP,$USDC,10000,$TRADER,$SK,0,0)" "${NESTED[@]}"
done
F_USDC0=$(bal $USDC $FEE_RECIPIENT); F_WETH0=$(bal $WETH $FEE_RECIPIENT); SUP0=$(call $SKOOP 'totalSupply()(uint256)')
tx $STRANGER $LOCKER "collectFees()" "${NESTED[@]}"
echo "  network fee to 0x6588: +$(( $(bal $USDC $FEE_RECIPIENT) - F_USDC0 )) USDC raw, +$(( $(bal $WETH $FEE_RECIPIENT) - F_WETH0 )) WETH wei"
echo "  SKOOP fees burned: $(( SUP0 - $(call $SKOOP 'totalSupply()(uint256)') )) raw  (reserve untouched: $(call $LOCKER 'reserveTokens()(uint256)'))"

say "5. addLiquidity from the reserve (owner supplies the pair side)"
tx $TESTER $WETH "deposit()" --value 0.001ether
tx $TESTER $WETH "approve(address,uint256)" $LOCKER 1000000000000000
must_fail "addLiquidity by a stranger" $STRANGER $LOCKER "addLiquidity(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)" 0 10000000 0 1000000000000000 0 0 0 0
L0=$(liq $ETH_NFT)
tx $TESTER $LOCKER "addLiquidity(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)" 0 10000000 0 1000000000000000 0 0 0 0 "${NESTED[@]}"
echo "  ETH position liquidity $L0 -> $(liq $ETH_NFT); reserve now $(call $LOCKER 'reserveTokens()(uint256)')"

say "6. evacuateLP — everything back to the owner, locker bricked"
must_fail "evacuateLP by a stranger" $STRANGER $LOCKER "evacuateLP()"
S0=$(bal $SKOOP $TESTER); U0=$(bal $USDC $TESTER); W0=$(bal $WETH $TESTER)
tx $TESTER $LOCKER "evacuateLP()" "${NESTED[@]}"
echo "  owner received: +$(( $(bal $SKOOP $TESTER) - S0 )) SKOOP raw, +$(( $(bal $USDC $TESTER) - U0 )) USDC raw, +$(( $(bal $WETH $TESTER) - W0 )) WETH wei"
echo "  positions now liquidity $(liq $USDC_NFT) / $(liq $ETH_NFT); locker holds $(bal $SKOOP $LOCKER) SKOOP, $(bal $USDC $LOCKER) USDC, $(bal $WETH $LOCKER) WETH"
echo "  evacuationOpen=$(call $LOCKER 'evacuationOpen()(bool)')  lpPermanentlyLocked=$(call $LOCKER 'lpPermanentlyLocked()(bool)')"
must_fail "evacuateLP a second time" $TESTER $LOCKER "evacuateLP()"
must_fail "collectFees after evacuation" $STRANGER $LOCKER "collectFees()"
say "Locker rehearsal complete — nothing was sent to Base"
