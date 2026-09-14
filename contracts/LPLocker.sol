// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/ILPLocker.sol";
import "./interfaces/INonfungiblePositionManager.sol";

/// @title LPLocker
/// @notice Holds and manages merchant LP positions across USDC and ETH pools.
/// @dev Two Uniswap v3 NFT positions — one against USDC, one against ETH.
///      Launch deploys 3% of supply across both, split in proportion to the USD value
///      seeded into each pool rather than at a fixed ratio, so both open at one price.
///      Remaining 27% held as reserve, merchant adds over time via addLiquidity().
///      Wind-down: 90/10 split on each position independently.
///      Merchant token portions always burned. USDC + WETH to ownerWallet.
///      Reserve tokens burned at wind-down — no longer deployable.
///      addLiquidity() frozen at wind-down initiation.
contract LPLocker is ILPLocker, ReentrancyGuard {

    using SafeERC20 for IERC20;

    // ── IMMUTABLES ────────────────────────────────────────────────────────────

    address public immutable merchantToken;
    address public immutable override ownerWallet;
    address public immutable windDownController;
    address public immutable override positionManager;
    address public immutable factory;

    /// @notice Receives PunchCard's network fee from collected trading fees
    address public immutable punchcardFeeRecipient;
    address public immutable override usdcAddress;
    address public immutable override wethAddress;

    // ── STATE ─────────────────────────────────────────────────────────────────

    /// @notice The network fee: PunchCard takes the pair-asset side of trading fees in full.
    /// @dev This is a toll on using the network, not a share of the merchant's LP yield, and
    ///      it is deliberately NOT all of the fee.
    ///
    ///      Uniswap charges the fee on the INPUT token of each swap, so fees accrue in both
    ///      assets. Someone buying the merchant's token with USDC pays in USDC; someone
    ///      selling it pays in the merchant token. PunchCard takes the first. The second is
    ///      BURNED — it reduces supply and lifts every token the merchant holds, including
    ///      their treasury and team allocations.
    ///
    ///      So sell pressure, the thing that hurts a merchant's token, converts into burn;
    ///      and PunchCard earns when people are buying in, which is when the merchant is
    ///      winning. PunchCard never holds a merchant token, ever.
    ///
    ///      It replaces a recurring platform fee rather than sitting on top of one: no
    ///      subscription and no cut of the merchant's sales.

    /// @notice Share of liquidity withdrawn at wind-down completion, as a percent.
    /// @dev Public and named because it is quoted to customers verbatim: the Swap screen
    ///      tells a buyer how much liquidity leaves on the expiry date. That disclosure is
    ///      the reason PunchCardRouter permits buying a winding-down token at all, so the
    ///      figure must be read from here rather than retyped in the interface. It used to
    ///      be a bare literal in two places with the app hardcoding a third copy beside
    ///      them, and changing the split would have quietly turned a financial disclosure
    ///      into a false statement.
    uint256 public constant WIND_DOWN_RELEASE_PCT = 90;

    /// @notice Share of liquidity left in the position permanently. Load-bearing: it is
    ///         what keeps a wound-down token tradable, which is what makes "you can still
    ///         hold or sell after the expiry date" true. Do not reclaim it without
    ///         changing that disclosure.
    uint256 public constant PERMANENT_LP_PCT = 100 - WIND_DOWN_RELEASE_PCT;

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
    ///      PAIR-token dust from increaseLiquidity returns to ownerWallet — that is the
    ///      merchant's own capital. Merchant-token dust stays here and stays counted as
    ///      reserve, and _reserveTokens decrements by tokens actually consumed, never by
    ///      the desired amounts. Returning merchant-token dust made the reserve drainable.
    /// @param usdcTokenMin Minimum merchant tokens to actually enter the USDC position
    /// @param usdcPairMin  Minimum USDC to actually enter the USDC position
    /// @param ethTokenMin  Minimum merchant tokens to actually enter the ETH position
    /// @param ethPairMin   Minimum WETH to actually enter the ETH position
    /// @dev The four *Min values are slippage bounds passed straight to Uniswap. They were
    ///      previously hardcoded to zero, which left a merchant deploying reserve open to
    ///      being sandwiched: the pool price can move between submission and inclusion, and
    ///      with no floor the mint accepts whatever ratio it lands on. Pass 0 only if you
    ///      genuinely do not care about the execution price.
    function addLiquidity(
        uint256 usdcTokenAmount,
        uint256 ethTokenAmount,
        uint256 usdcPairAmount,
        uint256 ethPairAmount,
        uint256 usdcTokenMin,
        uint256 usdcPairMin,
        uint256 ethTokenMin,
        uint256 ethPairMin
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
        // Each side needs BOTH halves or its mint is skipped below. Without this, a call
        // like addLiquidity(1_000_000, 0, 0, 0) added no liquidity at all yet still
        // decremented _reserveTokens, silently stranding those tokens: they stay in this
        // contract's balance but can never be deployed again, and are burned at wind-down.
        require(
            (usdcTokenAmount == 0) == (usdcPairAmount == 0),
            "USDC side needs both amounts"
        );
        require(
            (ethTokenAmount == 0) == (ethPairAmount == 0),
            "ETH side needs both amounts"
        );

        INonfungiblePositionManager pm = INonfungiblePositionManager(positionManager);
        uint128 usdcLiqAdded;
        uint128 ethLiqAdded;
        // Merchant tokens Uniswap ACTUALLY consumed. The reserve is decremented by these,
        // never by the desired amounts — see the note on dust below.
        uint256 usdcTokenUsed;
        uint256 ethTokenUsed;

        // Add to USDC pool
        if (usdcTokenAmount > 0 && usdcPairAmount > 0) {
            IERC20(usdcAddress).safeTransferFrom(ownerWallet, address(this), usdcPairAmount);
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
                    amount0Min:     _usdcPosition.merchantIsToken0 ? usdcTokenMin : usdcPairMin,
                    amount1Min:     _usdcPosition.merchantIsToken0 ? usdcPairMin  : usdcTokenMin,
                    deadline:       block.timestamp
                })
            );

            usdcLiqAdded = liq;

            // Only PAIR-token dust goes back to the merchant — that is their own capital.
            //
            // Merchant-token dust stays in this contract and stays counted as reserve.
            // Returning it was a complete bypass of the LP lock: supply a large token
            // amount against a trivial pair amount, Uniswap consumes almost none of the
            // tokens because liquidity is bounded by the smaller side, and the remainder
            // was transferred straight to ownerWallet while the reserve was decremented by
            // the desired amount. One call could drain the whole 27M.
            (uint256 tokenUsed, uint256 pairUsed) = _usdcPosition.merchantIsToken0
                ? (used0, used1)
                : (used1, used0);
            usdcTokenUsed = tokenUsed;

            uint256 pairDust = usdcPairAmount - pairUsed;
            if (pairDust > 0) IERC20(usdcAddress).safeTransfer(ownerWallet, pairDust);

            // Leave no standing allowance on the locker's own reserve.
            IERC20(merchantToken).approve(positionManager, 0);
            IERC20(usdcAddress).approve(positionManager, 0);
        }

        // Add to ETH pool
        if (ethTokenAmount > 0 && ethPairAmount > 0) {
            IERC20(wethAddress).safeTransferFrom(ownerWallet, address(this), ethPairAmount);
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
                    amount0Min:     _ethPosition.merchantIsToken0 ? ethTokenMin : ethPairMin,
                    amount1Min:     _ethPosition.merchantIsToken0 ? ethPairMin  : ethTokenMin,
                    deadline:       block.timestamp
                })
            );

            ethLiqAdded = liq;

            // Only PAIR-token dust goes back to the merchant — that is their own capital.
            //
            // Merchant-token dust stays in this contract and stays counted as reserve.
            // Returning it was a complete bypass of the LP lock: supply a large token
            // amount against a trivial pair amount, Uniswap consumes almost none of the
            // tokens because liquidity is bounded by the smaller side, and the remainder
            // was transferred straight to ownerWallet while the reserve was decremented by
            // the desired amount. One call could drain the whole 27M.
            (uint256 tokenUsed, uint256 pairUsed) = _ethPosition.merchantIsToken0
                ? (used0, used1)
                : (used1, used0);
            ethTokenUsed = tokenUsed;

            uint256 pairDust = ethPairAmount - pairUsed;
            if (pairDust > 0) IERC20(wethAddress).safeTransfer(ownerWallet, pairDust);

            // Leave no standing allowance on the locker's own reserve.
            IERC20(merchantToken).approve(positionManager, 0);
            IERC20(wethAddress).approve(positionManager, 0);
        }

        // Actual, not desired. Unused merchant tokens never left this contract, so they
        // are still reserve and must still be counted as such. (The old comment here said
        // 'dust already returned', which was true only while the reserve was drainable.)
        _reserveTokens -= (usdcTokenUsed + ethTokenUsed);

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
    /// @return usdcNetworkFee  USDC taken as the network fee
    /// @return wethNetworkFee  WETH taken as the network fee
    /// @return merchantBurned  Merchant-token fees burned — never taken, never held
    function collectFees()
        external
        notFrozen
        nonReentrant
        returns (uint256 usdcNetworkFee, uint256 wethNetworkFee, uint256 merchantBurned)
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

        // The whole pair-asset side is the network fee. No split, so nothing here can drift
        // out of step with a percentage declared somewhere else.
        if (usdcFees > 0) IERC20(usdcAddress).safeTransfer(punchcardFeeRecipient, usdcFees);
        if (wethFees > 0) IERC20(wethAddress).safeTransfer(punchcardFeeRecipient, wethFees);

        usdcNetworkFee = usdcFees;
        wethNetworkFee = wethFees;

        emit FeesCollected(
            merchantToken,
            0, usdcFees,          // nothing to the merchant; the whole pair side is the fee
            0, wethFees,
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
                uint128 usdcToRemove = uint128(uint256(usdcLiq) * WIND_DOWN_RELEASE_PCT / 100);
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
                uint128 ethToRemove = uint128(uint256(ethLiq) * WIND_DOWN_RELEASE_PCT / 100);
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
            IERC20(usdcAddress).safeTransfer(ownerWallet, totalUsdcToMerchant);
        }

        // Transfer WETH to merchant
        if (totalWethToMerchant > 0) {
            IERC20(wethAddress).safeTransfer(ownerWallet, totalWethToMerchant);
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
