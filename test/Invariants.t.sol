// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/RewardEscrow.sol";
import "../contracts/VestingWallet.sol";
import "../contracts/TreasuryTimelock.sol";
import "../contracts/LPLocker.sol";
import "../contracts/WindDownController.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract Tok is ERC20, ERC20Burnable {
    constructor(string memory n) ERC20(n, n) {}
    function mint(address a, uint256 v) external { _mint(a, v); }
    function decimals() public pure override returns (uint8) { return 6; }
}

contract PM {
    struct P { address t0; address t1; }
    mapping(uint256 => P) public pos;
    uint256 public fee0; uint256 public fee1;
    function setPos(uint256 id, address a, address b) external { pos[id] = P(a,b); }
    function setFees(uint256 a, uint256 b) external { fee0 = a; fee1 = b; }

    function positions(uint256 id) external view returns (
        uint96, address, address t0, address t1, uint24, int24, int24,
        uint128, uint256, uint256, uint128, uint128
    ) { P memory p = pos[id]; return (0, address(0), p.t0, p.t1, 3000, 0, 0, 1e6, 0, 0, 0, 0); }

    function increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams calldata p)
        external returns (uint128, uint256 used0, uint256 used1)
    {
        used0 = p.amount0Desired / 2;          // consume half, leave half as dust
        used1 = p.amount1Desired / 2;
        P memory q = pos[p.tokenId];
        if (used0 > 0) Tok(q.t0).transferFrom(msg.sender, address(this), used0);
        if (used1 > 0) Tok(q.t1).transferFrom(msg.sender, address(this), used1);
        return (1, used0, used1);
    }
    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata)
        external pure returns (uint256, uint256) { return (0, 0); }
    function collect(INonfungiblePositionManager.CollectParams calldata p)
        external returns (uint256 a0, uint256 a1)
    {
        a0 = fee0; a1 = fee1;
        P memory q = pos[p.tokenId];
        if (a0 > 0) Tok(q.t0).mint(p.recipient, a0);
        if (a1 > 0) Tok(q.t1).mint(p.recipient, a1);
    }
}

/// Drives the suite with bounded random actions. Every call is wrapped so a revert on an
/// unmet precondition does not end the run — the invariants must hold across whatever
/// sequence actually lands.
contract Handler is Test {
    Tok public token; Tok public usdc; Tok public weth;
    RewardEscrow public escrow; VestingWallet public vesting;
    TreasuryTimelock public treasury; LPLocker public locker;
    PM public pm;

    address public constant OWNER    = address(0x0B1);
    address public constant OPERATOR = address(0x0B3);
    address public constant PCFEE    = address(0xFEE5);
    address public constant CUSTOMER = address(0xC057E);

    uint256 public burned;

    constructor(Tok t, Tok u, Tok w, RewardEscrow e, VestingWallet v,
                TreasuryTimelock r, LPLocker l, PM p) {
        token = t; usdc = u; weth = w;
        escrow = e; vesting = v; treasury = r; locker = l; pm = p;
    }

    function warp(uint256 secs) public {
        vm.warp(block.timestamp + bound(secs, 1 hours, 30 days));
    }

    function distributeReward(uint256 amt) public {
        uint256 cap = escrow.drawerAvailable(OPERATOR);
        if (cap == 0) return;
        amt = bound(amt, escrow.perTxFloor(), cap < escrow.perTxMax() ? cap : escrow.perTxMax());
        vm.prank(OPERATOR);
        try escrow.distributeReward(CUSTOMER, amt) {} catch {}
    }

    function addLiquidity(uint256 tokAmt, uint256 pairAmt) public {
        uint256 res = locker.reserveTokens();
        if (res == 0) return;
        tokAmt  = bound(tokAmt, 1, res);
        pairAmt = bound(pairAmt, 1, 1e12);
        usdc.mint(OWNER, pairAmt);
        vm.startPrank(OWNER);
        usdc.approve(address(locker), type(uint256).max);
        try locker.addLiquidity(tokAmt, 0, pairAmt, 0, 0, 0, 0, 0) {} catch {}
        vm.stopPrank();
    }

    /// Fees accrue in the merchant token as well as the pair asset — the case where
    /// PunchCard could most plausibly end up holding merchant tokens.
    function collectFees(uint256 mFee, uint256 pFee) public {
        pm.setFees(bound(mFee, 0, 1e9), bound(pFee, 0, 1e9));
        uint256 before_ = token.totalSupply();
        try locker.collectFees() {} catch {}
        if (token.totalSupply() < before_) burned += before_ - token.totalSupply();
    }

    function releaseVesting() public { try vesting.release() {} catch {} }

    function treasuryFlow(uint256 amt) public {
        amt = bound(amt, 1, token.balanceOf(address(treasury)));
        if (amt == 0) return;
        vm.startPrank(OWNER);
        try treasury.submitRelease(amt) {} catch {}
        vm.stopPrank();
        try treasury.executeRelease() {} catch {}
    }
}

contract InvariantsTest is Test {
    Tok token; Tok usdc; Tok weth;
    RewardEscrow escrow; VestingWallet vesting; TreasuryTimelock treasury; LPLocker locker;
    WindDownController wdc;
    PM pm;
    Handler handler;

    uint256 constant REWARDS = 45_000_000 * 1e6;
    uint256 constant TEAM_A  = 15_000_000 * 1e6;
    uint256 constant TREAS_A = 10_000_000 * 1e6;
    uint256 constant RESERVE = 27_000_000 * 1e6;

    uint256 initialSupply;

    function setUp() public {
        token = new Tok("MERCH"); usdc = new Tok("USDC"); weth = new Tok("WETH");
        pm = new PM();
        wdc = new WindDownController(address(0xA1), address(0xFAC7));

        escrow   = new RewardEscrow(address(token), handlerOperator(), handlerOwner(), address(wdc), REWARDS, 1e6, 20_000*1e6);
        vesting  = new VestingWallet(address(token), address(0x7EA3), address(wdc), 180 days, 1080 days);
        treasury = new TreasuryTimelock(address(token), handlerOwner(), address(wdc), 90 days);
        locker   = new LPLocker(address(token), handlerOwner(), address(wdc), address(pm), address(0xFAC7),
                                address(usdc), address(weth), address(0xFEE5));

        token.mint(address(escrow), REWARDS);
        token.mint(address(vesting), TEAM_A);
        token.mint(address(treasury), TREAS_A);
        token.mint(address(locker), RESERVE);
        initialSupply = token.totalSupply();

        pm.setPos(1, address(token), address(usdc));
        pm.setPos(2, address(weth), address(token));
        vm.prank(address(0xFAC7));
        locker.initializeLP(1, 2, 3000, 3000);

        handler = new Handler(token, usdc, weth, escrow, vesting, treasury, locker, pm);
        targetContract(address(handler));
    }

    function handlerOwner() internal pure returns (address) { return address(0x0B1); }
    function handlerOperator() internal pure returns (address) { return address(0x0B3); }

    /// THE published claim: PunchCard receives no piece of any merchant's token.
    /// Merchant-token LP fees are burned rather than shared, so the fee recipient must
    /// never hold a single unit.
    function invariant_punchcardNeverHoldsMerchantTokens() public view {
        assertEq(token.balanceOf(address(0xFEE5)), 0,
            "PunchCard fee recipient holds merchant tokens");
    }

    /// Fixed supply, burn-only. Nothing may mint.
    function invariant_supplyNeverGrows() public view {
        assertLe(token.totalSupply(), initialSupply, "supply grew");
    }

    /// Emission is the ceiling on spend, whatever the drawers allow.
    function invariant_distributedNeverExceedsEmitted() public view {
        assertLe(escrow.totalDistributed(), escrow.emitted(), "spent beyond the schedule");
    }

    /// Accounted reserve can never exceed tokens actually held — the invariant the
    /// addLiquidity drain broke.
    function invariant_reserveIsBackedByBalance() public view {
        assertLe(locker.reserveTokens(), token.balanceOf(address(locker)),
            "reserve accounting exceeds tokens held");
    }

    /// The escrow can only ever pay out what it holds.
    function invariant_escrowSolvent() public view {
        assertLe(escrow.spendable(), token.balanceOf(address(escrow)), "escrow oversold");
    }
}
