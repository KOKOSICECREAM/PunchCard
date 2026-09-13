// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/TokenFactory.sol";
import "../contracts/WindDownController.sol";
import "../contracts/RewardEscrow.sol";
import "../contracts/deployers/SuiteDeployer.sol";
import "../contracts/deployers/LockerDeployer.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Fork test — a real merchant deployment against live Base contracts
/// @dev Everything before this mocked Uniswap. TokenFactory.deploy() had never executed
///      at all: 0 of 135 lines covered. This runs it against the actual position manager,
///      swap router, USDC, WETH and Chainlink feed on Base mainnet.
///
///      Run with:  forge test --match-path test/ForkDeploy.t.sol --fork-url https://mainnet.base.org
///      Skips itself when no fork is available, so the normal suite stays offline.
contract ForkDeployTest is Test {
    // Verified on-chain 2026-09-13, chainId 8453 — see deploy/network/base-mainnet.json
    address constant POSITION_MANAGER = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address constant SWAP_ROUTER      = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant USDC             = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH             = 0x4200000000000000000000000000000000000006;
    address constant ETH_USD_FEED     = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    address constant MULTISIG  = address(0xA1);
    address constant FEE_RECIP = address(0xA2);
    address constant OWNER     = address(0xB1);
    address constant TEAM      = address(0xB2);
    address constant OPERATOR  = address(0xB3);

    TokenFactory        factory;
    WindDownController  wdc;
    SuiteDeployer       suiteDeployer;
    LockerDeployer      lockerDeployer;

    bool forked;

    function setUp() public {
        // Only run when pointed at a fork.
        if (block.chainid != 8453) return;
        forked = true;

        suiteDeployer  = new SuiteDeployer();
        lockerDeployer = new LockerDeployer();

        // WindDownController and TokenFactory reference each other, so predict the
        // factory's address rather than deploying a throwaway controller.
        address predictedFactory = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        wdc = new WindDownController(MULTISIG, predictedFactory);

        factory = new TokenFactory(
            MULTISIG,
            address(this),          // deployer — the only caller of deploy()
            address(wdc),
            POSITION_MANAGER,
            USDC,
            WETH,
            ETH_USD_FEED,
            FEE_RECIP,
            address(suiteDeployer),
            address(lockerDeployer)
        );
        assertEq(address(factory), predictedFactory, "factory landed where predicted");
    }

    function test_deployRealMerchantOnBase() public {
        if (!forked) { emit log("skipped: run with --fork-url for Base mainnet"); return; }

        uint256 usdcSeed = 2_500 * 1e6;   // above the $2,000 floor
        uint256 ethSeed  = 2 ether;       // comfortably above the $3,000 floor

        deal(USDC, OWNER, usdcSeed);
        vm.deal(address(this), ethSeed);

        vm.prank(OWNER);
        IERC20(USDC).approve(address(factory), usdcSeed);

        TokenFactory.DeployParams memory p = TokenFactory.DeployParams({
            name:           "Frothy Rewards",
            symbol:         "FROTH",
            ipfsHash:       keccak256("metadata"),
            ownerWallet:    OWNER,
            teamWallet:     TEAM,
            operator:       OPERATOR,
            usdcFeeTier:    3000,
            ethFeeTier:     3000,
            usdcPairAmount: usdcSeed,
            ethPairAmount:  ethSeed,
            perTxFloor:     1e6,
            perTxMax:       20_000 * 1e6
        });

        vm.recordLogs();
        factory.deploy{value: ethSeed}(p);

        // ── pull the deployed addresses out of MerchantDeployed ──
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address token; address escrow; address vesting; address treasury; address locker;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256(
                "MerchantDeployed(address,address,address,address,address,address,address,address,bytes32,uint256)"
            )) {
                token = address(uint160(uint256(logs[i].topics[1])));
                (,,escrow, vesting, treasury, locker,,) = abi.decode(
                    logs[i].data, (address,address,address,address,address,address,bytes32,uint256)
                );
            }
        }
        assertTrue(token != address(0), "MerchantDeployed emitted");

        // ── allocations landed exactly ──
        assertEq(IERC20(token).balanceOf(escrow),   45_000_000 * 1e6, "rewards 45M");
        assertEq(IERC20(token).balanceOf(vesting),  15_000_000 * 1e6, "team 15M");
        assertEq(IERC20(token).balanceOf(treasury), 10_000_000 * 1e6, "treasury 10M");
        assertEq(IERC20(token).totalSupply(),      100_000_000 * 1e6, "fixed supply");

        // ── the factory keeps nothing ──
        assertEq(IERC20(token).balanceOf(address(factory)), 0, "factory drained of tokens");
        assertEq(IERC20(USDC).balanceOf(address(factory)),  0, "factory drained of USDC");

        // ── LP: 27M reserve in the locker, both positions minted to it ──
        assertEq(IERC20(token).balanceOf(locker), 27_000_000 * 1e6, "27M reserve");
        assertEq(IERC721(POSITION_MANAGER).balanceOf(locker), 2, "two Uniswap positions");

        // ── registered on the network ──
        assertTrue(wdc.isRegistered(token), "registered with WindDownController");

        // ── and the merchant can actually issue a reward ──
        vm.warp(block.timestamp + 1 days);
        vm.prank(OPERATOR);
        RewardEscrow(escrow).distributeReward(address(0xCAFE), 1_000 * 1e6);
        assertEq(IERC20(token).balanceOf(address(0xCAFE)), 1_000 * 1e6, "reward delivered");

        emit log_named_address("token",    token);
        emit log("merchant deployed against live Uniswap");
    }
}

interface IERC721 { function balanceOf(address) external view returns (uint256); }
