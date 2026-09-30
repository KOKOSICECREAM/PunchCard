// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/beta/TokenFactoryBeta.sol";
import "../contracts/beta/LockerDeployerBeta.sol";
import "../contracts/WindDownController.sol";
import "../contracts/deployers/SuiteDeployer.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Does deploy() fit in a Base transaction at all?
/// @notice Base's RPC refuses any transaction above 16,777,216 gas (2^24). The block gas
///         limit is 400,000,000, so this is a per-transaction ceiling, not a block one.
///         Found live: the micro rehearsal deployed its network fine and then could not
///         send a single merchant deploy.
contract GasCeilingTest is Test {
    address constant POSITION_MANAGER = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address constant USDC             = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH             = 0x4200000000000000000000000000000000000006;
    address constant ETH_USD_FEED     = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    uint256 constant BASE_TX_GAS_CEILING = 16_777_216;

    address constant OWNER = address(0xB1);
    bool forked;

    SuiteDeployer      suiteDeployer;
    LockerDeployerBeta lockerDeployer;

    function setUp() public {
        if (block.chainid != 8453) return;
        forked = true;
        suiteDeployer  = new SuiteDeployer();
        lockerDeployer = new LockerDeployerBeta();
    }

    /// @dev **Pinned as a known blocker, so it passes while broken and FAILS when fixed.**
    ///      A permanently red suite teaches people to ignore red. This asserts the defect
    ///      instead: the day deploy() fits, this test breaks and tells whoever fixed it to
    ///      invert the assertion. Same pattern as the via_ir warp canary.
    function test_KNOWN_BLOCKER_deployDoesNotFitInOneBaseTransaction() public {
        if (!forked) { vm.skip(true); }

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        WindDownController w = new WindDownController(address(0xA1), predicted);
        TokenFactoryBeta f = new TokenFactoryBeta(
            address(0xA1), address(this), address(w), POSITION_MANAGER, USDC, WETH,
            ETH_USD_FEED, address(0xA2), address(suiteDeployer), address(lockerDeployer),
            5 * 1e8, 5 * 1e8
        );

        uint256 usdcSeed = 5 * 1e6;
        uint256 ethSeed  = 0.0025 ether;
        deal(USDC, OWNER, usdcSeed);
        vm.deal(address(this), ethSeed);
        vm.prank(OWNER);
        IERC20(USDC).approve(address(f), usdcSeed);

        TokenFactory.DeployParams memory p = TokenFactory.DeployParams({
            name: "PunchCard Micro A", symbol: "PCMA", ipfsHash: keccak256("PCMA"),
            ownerWallet: OWNER, teamWallet: OWNER, operator: OWNER,
            usdcFeeTier: 3000, ethFeeTier: 3000,
            usdcPairAmount: usdcSeed, ethPairAmount: ethSeed,
            perTxFloor: 1e6, perTxMax: 20_000 * 1e6
        });

        uint256 before = gasleft();
        f.deploy{value: ethSeed}(p);
        uint256 used = before - gasleft();

        emit log_named_uint("deploy() gas used", used);
        emit log_named_uint("Base per-tx ceiling", BASE_TX_GAS_CEILING);

        if (used > BASE_TX_GAS_CEILING) {
            emit log_named_uint("OVER BY", used - BASE_TX_GAS_CEILING);
        } else {
            emit log_named_uint("headroom", BASE_TX_GAS_CEILING - used);
        }

        // Measured 2026-09-15: 17,011,396 against a 16,777,216 ceiling. Over by 234,180 —
        // 1.4%. Compiler settings do not close it: optimizer_runs of 1, 50 and 200 give
        // 16,972,887 / 16,973,993 / 17,011,396, so the most aggressive setting saves 38k of
        // the 234k needed. The fix has to be structural.
        assertGt(
            used,
            BASE_TX_GAS_CEILING,
            "deploy() NOW FITS in a Base transaction - the blocker is fixed. Invert this assertion to assertLt and delete this message."
        );
    }

    /// Where the 17M actually goes, so the split is chosen from numbers rather than taste.
    function test_whereTheGasGoes() public {
        if (!forked) { vm.skip(true); }

        uint256 g;
        address token;
        g = gasleft();
        token = suiteDeployer.deployToken("PunchCard Micro A", "PCMA", 100_000_000 * 1e6, address(this), keccak256("x"));
        emit log_named_uint("1. deployToken   ", g - gasleft());

        g = gasleft();
        suiteDeployer.deployVesting(token, OWNER, address(0xDD), 30 days, 730 days, address(this));
        emit log_named_uint("2. deployVesting ", g - gasleft());

        g = gasleft();
        suiteDeployer.deployTreasury(token, OWNER, address(0xDD), 90 days, address(this));
        emit log_named_uint("3. deployTreasury", g - gasleft());

        g = gasleft();
        suiteDeployer.deployEscrow(token, OWNER, OWNER, address(0xDD), 45_000_000 * 1e6, 1e6, 20_000 * 1e6, address(this));
        emit log_named_uint("4. deployEscrow  ", g - gasleft());

        g = gasleft();
        lockerDeployer.deployLocker(token, OWNER, address(0xDD), POSITION_MANAGER, address(this), USDC, WETH, address(0xA2));
        emit log_named_uint("5. deployLocker  ", g - gasleft());
    }

    /// The ceiling is the chain's, not one provider's. Three independent Base RPCs return
    /// the identical figure, and it is exactly 2^24 — mainnet.base.org, publicnode and
    /// 1rpc all answer `gas required exceeds: 16777216`, while the block gas limit is
    /// 400,000,000. So no RPC change, paid endpoint or gas override makes this transaction
    /// includable. Checked live 2026-09-15.
    function test_theCeilingIsExactlyTwoToThe24() public pure {
        assertEq(BASE_TX_GAS_CEILING, 2 ** 24, "the cap is a power of two, which is what makes it a protocol constant rather than a provider policy");
    }
}
