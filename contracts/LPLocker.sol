// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/ILPLocker.sol";
import "./interfaces/INonfungiblePositionManager.sol";

/// @title LPLocker
/// @notice Holds and manages merchant LP positions across USDC and ETH pools.
/// @dev Two Uniswap v3 NFT positions — USDC pool (60%) and ETH pool (40%).
///      Launch deploys 3% of supply split 60/40 across both pools.
///      Remaining 27% held as reserve, merchant adds over time via addLiquidity().
///      Wind-down: 90/10 split on each position independently.
///      Merchant token portions always burned. USDC + WETH to ownerWallet.
///      Reserve tokens burned at wind-down — no longer deployable.
///      addLiquidity() frozen at wind-down initiation.
contract LPLocker is ILPLocker, ReentrancyGuard {

    // ── IMMUTABLES ────────────────────────────────────────────────────────────

    address public immutable merchantToken;
    address public immutable override ownerWallet;
    address public immutable windDownController;
    address public immutable override positionManager;
    address public immutable factory;

    /// @notice Receives PunchCard's share of collected trading fees
    address public immutable punchcardFeeRecipient;
    address public immutable override usdcAddress;
    address public immutable override wethAddress;

    // ── STATE ─────────────────────────────────────────────────────────────────

    /// @notice PunchCard's share of Uniswap trading fees, in basis points.
    /// @dev A network constant, not a per-merchant term — every merchant is on identical
    ///      terms, the same way the allocations are. The merchant (or whoever seeded the
    ///      pools) keeps the remainder. Merchant-token fees are never shared: they are
    ///      burned, so PunchCard never accumulates a position in a merchant's token.
    uint256 public constant PUNCHCARD_FEE_SHARE_BPS = 2_000;   // 20%
    uint256 private constant BPS_DENOMINATOR        = 10_000;

    LPPosition private _usdcPosition;
    LPPosition private _ethPosition;
    uint256 private _reserveTokens;
    bool private _frozen;

    // ── CONSTRUCTOR ───────────────────────────────────────────────────────────

    constructor(
        address _merchantToken,
        address _ownerWallet,
        address _windDownController,
        address _positionManager,
        address _factory,
        address _usdc,
        address _weth,
        address _punchcardFeeRecipient
    ) {
        require(_merchantToken      != address(0), "Invalid token");
        require(_ownerWallet        != address(0), "Invalid owner");
        require(_windDownController != address(0), "Invalid controller");
        require(_positionManager    != address(0), "Invalid position manager");
        require(_factory            != address(0), "Invalid factory");
        require(_usdc               != address(0), "Invalid USDC");
        require(_weth               != address(0), "Invalid WETH");
        require(_punchcardFeeRecipient != address(0), "Invalid fee recipient");

        merchantToken      = _merchantToken;
        ownerWallet        = _ownerWallet;
        windDownController = _windDownController;
        positionManager    = _positionManager;
        factory            = _factory;
        usdcAddress        = _usdc;
        wethAddress        = _weth;
        punchcardFeeRecipient = _punchcardFeeRecipient;
    }

    // ── MODIFIERS ─────────────────────────────────────────────────────────────

    modifier onlyFactory() {
        require(msg.sender == factory, "Not factory");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == ownerWallet, "Not owner");
        _;
    }

    modifier onlyWindDown() {
        require(msg.sender == windDownController, "Not controller");
        _;
    }

    modifier notFrozen() {
        require(!_frozen, "Frozen");
        _;
    }

    // ── INITIALIZATION ────────────────────────────────────────────────────────

    /// @inheritdoc ILPLocker
    /// @dev Single positions() call per NFT — no double reads.
    ///      merchantIsToken0 stored at init — no runtime sort needed in release().
    ///      reserveTokens = full LP balance minus launch tokens already in pools.
    function initializeLP(
        uint256 usdcTokenId,
        uint256 ethTokenId,
        uint24  _usdcFeeTier,
        uint24  _ethFeeTier
    ) external onlyFactory {
        require(!_usdcPosition.initialized, "Already initialized");

        // Read USDC position
        (,, address usdcToken0,,,,, uint128 usdcLiquidity,,,,) =
            INonfungiblePositionManager(positionManager).positions(usdcTokenId);

        // Read ETH position
        (,, address ethToken0,,,,, uint128 ethLiquidity,,,,) =
            INonfungiblePositionManager(positionManager).positions(ethTokenId);

        _usdcPosition = LPPosition({
            tokenId:          usdcTokenId,
            feeTier:          _usdcFeeTier,
            initialLiquidity: usdcLiquidity,
            merchantIsToken0: usdcToken0 == merchantToken,
            initialized:      true,
            released:         false
        });

        _ethPosition = LPPosition({
            tokenId:          ethTokenId,
            feeTier:          _ethFeeTier,
            initialLiquidity: ethLiquidity,
            merchantIsToken0: ethToken0 == merchantToken,
            initialized:      true,
            released:         false
        });

        // Reserve = full token balance minus what went into pools
        // Factory transferred full LP alloc here before minting pools
        // Pool tokens are now in Uniswap — remaining balance is reserve
        _reserveTokens = IERC20(merchantToken).balanceOf(address(this));

        emit LPInitialized(
            merchantToken,
            usdcTokenId,
            ethTokenId,
            usdcLiquidity,
            ethLiquidity,
            _reserveTokens,
            block.timestamp
        );
    }

    // ── LIQUIDITY MANAGEMENT ──────────────────────────────────────────────────

    /// @inheritdoc ILPLocker
    /// @dev ownerWallet only. Pulls pair tokens from ownerWallet.
    ///      Merchant tokens sourced from reserve held here.
    ///      Goes into same NFT positions — no new positions.
    ///      Dust from increaseLiquidity returns to ownerWallet.
    function addLiquidity(
        uint256 usdcTokenAmount,
        uint256 ethTokenAmount,
        uint256 usdcPairAmount,
        uint256 ethPairAmount
    ) external onlyOwner notFrozen nonReentrant {
        require(_usdcPosition.initialized, "Not initialized");
        require(
            usdcTokenAmount + ethTokenAmount <= _reserveTokens,
            "Exceeds reserve"
        );
        require(
            usdcTokenAmount > 0 || ethTokenAmount > 0,
            "Zero amounts"
        );

        INonfungiblePositionManager pm = INonfungiblePositionManager(positionManager);
        uint128 usdcLiqAdded;
        uint128 ethLiqAdded;

        // Add to USDC pool
        if (usdcTokenAmount > 0 && usdcPairAmount > 0) {
            IERC20(usdcAddress).transferFrom(ownerWallet, address(this), usdcPairAmount);
            IERC20(merchantToken).approve(positionManager, usdcTokenAmount);
            IERC20(usdcAddress).approve(positionManager, usdcPairAmount);

            (uint256 amount0Desired, uint256 amount1Desired) = _usdcPosition.merchantIsToken0
                ? (usdcTokenAmount, usdcPairAmount)
                : (usdcPairAmount, usdcTokenAmount);

            (uint128 liq, uint256 used0, uint256 used1) = pm.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams({
                    tokenId:        _usdcPosition.tokenId,
                    amount0Desired: amount0Desired,
                    amount1Desired: amount1Desired,
                    amount0Min:     0,
                    amount1Min:     0,
                    deadline:       block.timestamp
                })
            );

            usdcLiqAdded = liq;

            // Return dust to ownerWallet
            uint256 dust0 = amount0Desired - used0;
            uint256 dust1 = amount1Desired - used1;
            if (dust0 > 0) IERC20(_usdcPosition.merchantIsToken0 ? merchantToken : usdcAddress).transfer(ownerWallet, dust0);
            if (dust1 > 0) IERC20(_usdcPosition.merchantIsToken0 ? usdcAddress : merchantToken).transfer(ownerWallet, dust1);
        }

        // Add to ETH pool
        if (ethTokenAmount > 0 && ethPairAmount > 0) {
            IERC20(wethAddress).transferFrom(ownerWallet, address(this), ethPairAmount);
            IERC20(merchantToken).approve(positionManager, ethTokenAmount);
            IERC20(wethAddress).approve(positionManager, ethPairAmount);

            (uint256 amount0Desired, uint256 amount1Desired) = _ethPosition.merchantIsToken0
                ? (ethTokenAmount, ethPairAmount)
                : (ethPairAmount, ethTokenAmount);

            (uint128 liq, uint256 used0, uint256 used1) = pm.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams({
                    tokenId:        _ethPosition.tokenId,
                    amount0Desired: amount0Desired,
                    amount1Desired: amount1Desired,
                    amount0Min:     0,
                    amount1Min:     0,
                    deadline:       block.timestamp
                })
            );

            ethLiqAdded = liq;

            // Return dust to ownerWallet
            uint256 dust0 = amount0Desired - used0;
            uint256 dust1 = amount1Desired - used1;
            if (dust0 > 0) IERC20(_ethPosition.merchantIsToken0 ? merchantToken : wethAddress).transfer(ownerWallet, dust0);
            if (dust1 > 0) IERC20(_ethPosition.merchantIsToken0 ? wethAddress : merchantToken).transfer(ownerWallet, dust1);
        }

        // Decrement reserve by tokens actually committed (dust already returned)
        _reserveTokens -= (usdcTokenAmount + ethTokenAmount);

        emit LiquidityAdded(
            merchantToken,
            usdcTokenAmount,
            ethTokenAmount,
            usdcLiqAdded,
            ethLiqAdded,
            _reserveTokens,
            block.timestamp
        );
    }

    // ── FEES ──────────────────────────────────────────────────────────────────

    /// @notice Sweeps accrued Uniswap trading fees from both positions.
    /// @dev Permissionless by design — every destination is fixed and immutable, so there
    ///      is nothing to gain by calling it and no key needed to keep fees moving.
    ///
    ///      Amounts come from collect()'s return values, never from this contract's
    ///      balance. The 27M LP reserve sits in this same contract, and a balance-based
    ///      implementation would burn it.
    ///
    ///      Disabled once frozen: during wind-down, release() returns accrued fees to the
    ///      merchant rather than splitting them.
    /// @return usdcToMerchant  USDC paid to the merchant
    /// @return wethToMerchant  WETH paid to the merchant
    /// @return merchantBurned  Merchant-token fees burned
    function collectFees()
        external
        notFrozen
        nonReentrant
        returns (uint256 usdcToMerchant, uint256 wethToMerchant, uint256 merchantBurned)
    {
        require(_usdcPosition.initialized, "Not initialized");
        require(!_usdcPosition.released,   "Already released");

        INonfungiblePositionManager pm = INonfungiblePositionManager(positionManager);

        uint256 merchantFees;
        uint256 usdcFees;
        uint256 wethFees;

        {
            (uint256 a0, uint256 a1) = pm.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId:    _usdcPosition.tokenId,
                    recipient:  address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
            if (_usdcPosition.merchantIsToken0) { merchantFees += a0; usdcFees = a1; }
            else                                { usdcFees = a0; merchantFees += a1; }
        }

        {
            (uint256 a0, uint256 a1) = pm.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId:    _ethPosition.tokenId,
                    recipient:  address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
            if (_ethPosition.merchantIsToken0) { merchantFees += a0; wethFees = a1; }
            else                               { wethFees = a0; merchantFees += a1; }
        }

        // Merchant-token fees are burned — deflationary, and it keeps PunchCard out of
        // every merchant's cap table.
        if (merchantFees > 0) {
            ERC20Burnable(merchantToken).burn(merchantFees);
            merchantBurned = merchantFees;
        }

        uint256 usdcToPunchcard = (usdcFees * PUNCHCARD_FEE_SHARE_BPS) / BPS_DENOMINATOR;
        uint256 wethToPunchcard = (wethFees * PUNCHCARD_FEE_SHARE_BPS) / BPS_DENOMINATOR;
        usdcToMerchant = usdcFees - usdcToPunchcard;
        wethToMerchant = wethFees - wethToPunchcard;

        if (usdcToPunchcard > 0) IERC20(usdcAddress).transfer(punchcardFeeRecipient, usdcToPunchcard);
        if (wethToPunchcard > 0) IERC20(wethAddress).transfer(punchcardFeeRecipient, wethToPunchcard);
        if (usdcToMerchant  > 0) IERC20(usdcAddress).transfer(ownerWallet, usdcToMerchant);
        if (wethToMerchant  > 0) IERC20(wethAddress).transfer(ownerWallet, wethToMerchant);

        emit FeesCollected(
            merchantToken,
            usdcToMerchant, usdcToPunchcard,
            wethToMerchant, wethToPunchcard,
            merchantBurned,
            block.timestamp
        );
    }

        // ── WIND-DOWN ─────────────────────────────────────────────────────────────

    /// @inheritdoc ILPLocker
    function freeze() external onlyWindDown {
        _frozen = true;
        emit LPFrozen(merchantToken, block.timestamp);
    }

    /// @inheritdoc ILPLocker
    /// @dev Settles both positions independently. Burns all merchant tokens.
    ///      Reserve tokens burned alongside position tokens.
    function release() external onlyWindDown nonReentrant {
        require(_usdcPosition.initialized, "Not initialized");
        require(!_usdcPosition.released,   "Already released");

        // CEI — mark released before all external calls
        _usdcPosition.released = true;
        _ethPosition.released  = true;

        INonfungiblePositionManager pm = INonfungiblePositionManager(positionManager);

        uint256 totalMerchantBurned;
        uint256 totalUsdcToMerchant;
        uint256 totalWethToMerchant;
        uint256 usdcPermanent;
        uint256 ethPermanent;

        // ── Settle USDC position ──────────────────────────────────────────────

        {
            (,,,,,,,uint128 usdcLiq,,,,) = pm.positions(_usdcPosition.tokenId);

            if (usdcLiq > 0) {
                uint128 usdcToRemove = uint128(uint256(usdcLiq) * 90 / 100);
                usdcPermanent = usdcLiq - usdcToRemove;

                pm.decreaseLiquidity(
                    INonfungiblePositionManager.DecreaseLiquidityParams({
                        tokenId:    _usdcPosition.tokenId,
                        liquidity:  usdcToRemove,
                        amount0Min: 0,
                        amount1Min: 0,
                        deadline:   block.timestamp
                    })
                );

                (uint256 amt0, uint256 amt1) = pm.collect(
                    INonfungiblePositionManager.CollectParams({
                        tokenId:    _usdcPosition.tokenId,
                        recipient:  address(this),
                        amount0Max: type(uint128).max,
                        amount1Max: type(uint128).max
                    })
                );

                uint256 usdcAmt     = _usdcPosition.merchantIsToken0 ? amt1 : amt0;

                totalUsdcToMerchant += usdcAmt;
            }
        }

        // ── Settle ETH position ───────────────────────────────────────────────

        {
            (,,,,,,,uint128 ethLiq,,,,) = pm.positions(_ethPosition.tokenId);

            if (ethLiq > 0) {
                uint128 ethToRemove = uint128(uint256(ethLiq) * 90 / 100);
                ethPermanent = ethLiq - ethToRemove;

                pm.decreaseLiquidity(
                    INonfungiblePositionManager.DecreaseLiquidityParams({
                        tokenId:    _ethPosition.tokenId,
                        liquidity:  ethToRemove,
                        amount0Min: 0,
                        amount1Min: 0,
                        deadline:   block.timestamp
                    })
                );

                (uint256 amt0, uint256 amt1) = pm.collect(
                    INonfungiblePositionManager.CollectParams({
                        tokenId:    _ethPosition.tokenId,
                        recipient:  address(this),
                        amount0Max: type(uint128).max,
                        amount1Max: type(uint128).max
                    })
                );

                uint256 wethAmt     = _ethPosition.merchantIsToken0 ? amt1 : amt0;

                totalWethToMerchant += wethAmt;
            }
        }

        // ── Burn every merchant token this contract holds ─────────────────────
        // Balance, not a running total. collect() above pays the withdrawn liquidity and
        // accrued fees into this contract, so the amounts returned by collect() are ALREADY
        // part of balanceOf. Adding them to the reserve double-counted them and made burn()
        // exceed the balance — which reverted release(), and since onExpiryReleaseLP is the
        // terminal step, it bricked the wind-down and stranded the merchant's LP for good.
        // It only triggered once a position had earned merchant-token fees, i.e. always.

        totalMerchantBurned = IERC20(merchantToken).balanceOf(address(this));
        if (totalMerchantBurned > 0) {
            ERC20Burnable(merchantToken).burn(totalMerchantBurned);
        }

        // Transfer USDC to merchant
        if (totalUsdcToMerchant > 0) {
            IERC20(usdcAddress).transfer(ownerWallet, totalUsdcToMerchant);
        }

        // Transfer WETH to merchant
        if (totalWethToMerchant > 0) {
            IERC20(wethAddress).transfer(ownerWallet, totalWethToMerchant);
        }

        emit LPReleased(
            merchantToken,
            totalUsdcToMerchant,
            totalWethToMerchant,
            totalMerchantBurned,
            usdcPermanent,
            ethPermanent,
            block.timestamp
        );
    }

    // ── VIEWS ─────────────────────────────────────────────────────────────────

    function getPositions() external view returns (DualPosition memory) {
        return DualPosition({
            usdc:         _usdcPosition,
            eth:          _ethPosition,
            reserveTokens: _reserveTokens
        });
    }

    function isInitialized() external view returns (bool) {
        return _usdcPosition.initialized;
    }

    function isReleased() external view returns (bool) {
        return _usdcPosition.released;
    }

    function isFrozen() external view returns (bool) {
        return _frozen;
    }

    function reserveTokens() external view returns (uint256) {
        return _reserveTokens;
    }

    function currentUsdcLiquidity() external view returns (uint128) {
        if (!_usdcPosition.initialized) return 0;
        (,,,,,,,uint128 liq,,,,) =
            INonfungiblePositionManager(positionManager).positions(_usdcPosition.tokenId);
        return liq;
    }

    function currentEthLiquidity() external view returns (uint128) {
        if (!_ethPosition.initialized) return 0;
        (,,,,,,,uint128 liq,,,,) =
            INonfungiblePositionManager(positionManager).positions(_ethPosition.tokenId);
        return liq;
    }

    function usdcFeeTier() external view returns (uint24) {
        return _usdcPosition.feeTier;
    }

    function ethFeeTier() external view returns (uint24) {
        return _ethPosition.feeTier;
    }
}
