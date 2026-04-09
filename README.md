# PunchCard Network — Contract Suite

## Deployment Order

Deploy in this exact order. Each contract depends on the previous.

### 1. WindDownController
```
Constructor args:
  _multisig   — PunchCard multisig address
  _factory    — TokenFactory address (deploy factory first, or use CREATE2)
```
> Note: WindDownController and TokenFactory have a circular dependency.
> Resolve with CREATE2 (pre-compute factory address) or deploy WindDownController
> with a placeholder factory, then update after factory is deployed.
> Simplest path: deploy WindDownController with your EOA as factory temporarily,
> deploy TokenFactory, then redeploy WindDownController with real factory address.

### 2. TokenFactory
```
Constructor args:
  _multisig            — PunchCard multisig
  _deployer            — PunchCard deployer hot wallet
  _windDownController  — WindDownController address (from step 1)
  _positionManager     — 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f4  (Base mainnet)
  _usdc                — 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913  (Base mainnet)
  _weth                — 0x4200000000000000000000000000000000000006  (Base mainnet)
```

### 3. PunchCardRouter
```
Constructor args:
  _multisig            — PunchCard multisig
  _windDownController  — WindDownController address
  _swapRouter          — 0x2626664c2603336E57B271c5C0b26F421741e481  (Base mainnet SwapRouter02)
  _usdc                — 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
  _weth                — 0x4200000000000000000000000000000000000006
  _initialFeeRate      — 30  (0.3% = 30 basis points)
  _initialFeeRecipient — PunchCard operational wallet
```

---

## Merchant Deployment (via TokenFactory.deploy())

The factory deploys the full suite in one transaction:
- PunchCardToken
- VestingWallet
- TreasuryTimelock
- RewardEscrow
- LPLocker

### DeployParams

| Field | Type | Notes |
|---|---|---|
| name | string | Token name e.g. "Frothy Monkey Rewards" |
| symbol | string | Token symbol e.g. "FROTHY" |
| ipfsHash | bytes32 | IPFS hash of merchant metadata |
| ownerWallet | address | Merchant wallet — controls treasury, receives LP at wind-down |
| teamWallet | address | Team vesting recipient — immutable |
| operator | address | POS signer — authorized to distribute rewards |
| pairType | uint8 | 0 = ETH, 1 = USDC |
| feeTier | uint24 | 100 / 500 / 3000 / 10000 |
| pairAmount | uint256 | ETH or USDC amount for LP |
| perTxFloor | uint256 | Min reward per tx in tokens ($0.01 equivalent at deploy price) |
| perTxMax | uint256 | Max reward per tx in tokens |

**For ETH pairs:** send `msg.value == pairAmount`
**For USDC pairs:** ownerWallet must approve factory for `pairAmount` before calling

---

## Base Mainnet Addresses

| Contract | Address |
|---|---|
| Uniswap v3 NonfungiblePositionManager | 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f4 |
| Uniswap v3 SwapRouter02 | 0x2626664c2603336E57B271c5C0b26F421741e481 |
| USDC | 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 |
| WETH | 0x4200000000000000000000000000000000000006 |

---

## OpenZeppelin Dependencies

All contracts import from `@openzeppelin/contracts`. In Remix:

1. The imports will resolve automatically if you use the Remix OpenZeppelin plugin
2. Or manually set compiler to fetch from npm: `@openzeppelin/contracts` v4.x or v5.x

Pragma: `^0.8.24` — use Solidity compiler 0.8.24 or higher.

---

## Network Constants (hardcoded in factory)

| Constant | Value |
|---|---|
| TOTAL_SUPPLY | 100,000,000 tokens (6 decimals) |
| REWARDS_ALLOC | 45,000,000 (45%) |
| LP_ALLOC | 30,000,000 (30%) |
| TEAM_ALLOC | 15,000,000 (15%) |
| TREASURY_ALLOC | 10,000,000 (10%) |
| DAILY_CAP | 500,000 tokens |
| CLIFF_DURATION | 180 days |
| VEST_DURATION | 1,080 days |
| TIMELOCK_DURATION | 90 days |

---

## Wind-Down Process

1. Multisig calls `WindDownController.initiate(merchantToken)`
   - Freezes RewardEscrow and TreasuryTimelock immediately
   - Starts 12-month timer
2. After 12 months, anyone can call (in any order):
   - `onExpiryBurnEscrow(merchantToken)`
   - `onExpiryBurnTreasury(merchantToken)`
   - `onExpirySettleVesting(merchantToken)`
3. After all three complete, anyone can call:
   - `onExpiryReleaseLP(merchantToken)` — 90% to merchant, 10% permanent
