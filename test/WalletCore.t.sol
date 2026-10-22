// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AdapterRegistry } from "../src/AdapterRegistry.sol";
import { FeeCollector } from "../src/FeeCollector.sol";
import { FeePolicy } from "../src/FeePolicy.sol";
import { RouterSwapAdapter } from "../src/adapters/RouterSwapAdapter.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockSwapRouter } from "../src/mocks/MockSwapRouter.sol";
import { WalletCore } from "../src/WalletCore.sol";
import { WalletFactory } from "../src/WalletFactory.sol";
import { ExecutionRequest, ServiceType } from "../src/types/WalletTypes.sol";
import { WalletCoreV2 } from "./mocks/WalletCoreV2.sol";

contract WalletCoreTest is Test {
    uint256 private constant UNIT = 1e6;
    uint256 private constant SWAP_AMOUNT = 100 * UNIT;
    uint256 private constant FEE = 1 * UNIT;
    uint256 private constant MAX_FEE = 10 * UNIT;

    address private admin = makeAddr("admin");
    address private operator = makeAddr("operator");
    address private upgrader = makeAddr("upgrader");
    address private treasury = makeAddr("treasury");
    address private attacker = makeAddr("attacker");

    MockERC20 private usdc;
    MockERC20 private usdt;
    MockSwapRouter private router;
    AdapterRegistry private registry;
    RouterSwapAdapter private adapter;
    FeePolicy private feePolicy;
    FeeCollector private feeCollector;
    WalletFactory private factory;
    WalletCore private wallet;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);
        router = new MockSwapRouter();
        registry = new AdapterRegistry(admin);
        adapter = new RouterSwapAdapter(admin);
        feeCollector = new FeeCollector(admin, address(usdt), treasury);
        feePolicy = new FeePolicy(admin, address(usdt), address(feeCollector), MAX_FEE);

        router.setRate(address(usdc), address(usdt), 1, 1);
        router.setRate(address(usdt), address(usdc), 1, 1);
        usdc.mint(address(router), 1_000_000 * UNIT);
        usdt.mint(address(router), 1_000_000 * UNIT);

        vm.startPrank(admin);
        adapter.setRouterAllowed(address(router), true);
        registry.registerAdapter(address(adapter), ServiceType.SWAP);
        WalletCore implementation = new WalletCore();
        factory = new WalletFactory(admin, address(implementation));
        vm.stopPrank();

        WalletFactory.WalletInitParams memory params = WalletFactory.WalletInitParams({
            admin: admin,
            operator: operator,
            upgrader: upgrader,
            adapterRegistry: address(registry),
            feePolicy: address(feePolicy),
            usdt: address(usdt)
        });

        address predicted = factory.predictWalletAddress(bytes32("wallet-1"), params);
        vm.prank(admin);
        address deployed = factory.deployWallet(bytes32("wallet-1"), params);

        assertEq(deployed, predicted);
        wallet = WalletCore(deployed);
    }

    function test_swapUsdcToUsdtAndCollectFee() public {
        usdc.mint(address(wallet), 1_000 * UNIT);

        ExecutionRequest memory request = _swapRequest(
            keccak256("quote-usdc-usdt"), 0, address(usdc), address(usdt), SWAP_AMOUNT, SWAP_AMOUNT, FEE
        );
        bytes32 expectedExecutionId = _executionId(request);

        vm.expectEmit(true, true, true, true, address(wallet));
        emit WalletCore.ExecutionSettled(
            request.quoteId,
            address(wallet),
            address(adapter),
            ServiceType.SWAP,
            address(usdc),
            address(usdt),
            SWAP_AMOUNT,
            SWAP_AMOUNT,
            FEE,
            expectedExecutionId
        );

        vm.prank(operator);
        wallet.execute(request);

        assertEq(usdc.balanceOf(address(wallet)), 900 * UNIT);
        assertEq(usdt.balanceOf(address(wallet)), SWAP_AMOUNT - FEE);
        assertEq(usdt.balanceOf(address(feeCollector)), FEE);
        assertEq(feeCollector.totalCollected(), FEE);
        assertEq(wallet.executionNonce(), 1);
        assertTrue(wallet.isQuoteExecuted(request.quoteId));
        assertEq(usdc.allowance(address(wallet), address(adapter)), 0);
        assertEq(usdt.allowance(address(wallet), address(feeCollector)), 0);
    }

    function test_swapUsdtToUsdcReservesFee() public {
        usdt.mint(address(wallet), 1_000 * UNIT);

        ExecutionRequest memory request = _swapRequest(
            keccak256("quote-usdt-usdc"), 0, address(usdt), address(usdc), SWAP_AMOUNT, SWAP_AMOUNT, FEE
        );

        vm.prank(operator);
        wallet.execute(request);

        assertEq(usdt.balanceOf(address(wallet)), 1_000 * UNIT - SWAP_AMOUNT - FEE);
        assertEq(usdc.balanceOf(address(wallet)), SWAP_AMOUNT);
        assertEq(usdt.balanceOf(address(feeCollector)), FEE);
    }

    function test_RevertWhen_CallerIsNotOperator() public {
        usdc.mint(address(wallet), SWAP_AMOUNT);

        ExecutionRequest memory request =
            _swapRequest(keccak256("unauthorized"), 0, address(usdc), address(usdt), SWAP_AMOUNT, 0, FEE);

        vm.expectRevert();
        vm.prank(attacker);
        wallet.execute(request);
    }

    function test_RevertWhen_QuoteIsExpired() public {
        usdc.mint(address(wallet), SWAP_AMOUNT);

        ExecutionRequest memory request =
            _swapRequest(keccak256("expired"), 0, address(usdc), address(usdt), SWAP_AMOUNT, 0, FEE);
        request.deadline = uint64(block.timestamp - 1);

        vm.expectRevert(abi.encodeWithSelector(WalletCore.QuoteExpired.selector, request.deadline));
        vm.prank(operator);
        wallet.execute(request);
    }

    function test_RevertWhen_QuoteIsReplayed() public {
        usdc.mint(address(wallet), 2 * SWAP_AMOUNT);

        ExecutionRequest memory request =
            _swapRequest(keccak256("replay"), 0, address(usdc), address(usdt), SWAP_AMOUNT, SWAP_AMOUNT, FEE);

        vm.prank(operator);
        wallet.execute(request);

        request.nonce = 1;
        vm.expectRevert(abi.encodeWithSelector(WalletCore.QuoteAlreadyExecuted.selector, request.quoteId));
        vm.prank(operator);
        wallet.execute(request);
    }

    function test_RevertWhen_FeeExceedsPolicyLimit() public {
        usdc.mint(address(wallet), SWAP_AMOUNT);

        ExecutionRequest memory request =
            _swapRequest(keccak256("fee-limit"), 0, address(usdc), address(usdt), SWAP_AMOUNT, 0, MAX_FEE + 1);
        request.maxFeeUSDT = MAX_FEE + 1;

        vm.expectRevert();
        vm.prank(operator);
        wallet.execute(request);
    }

    function test_RevertWhen_AdapterIsDisabled() public {
        usdc.mint(address(wallet), SWAP_AMOUNT);

        vm.prank(admin);
        registry.setAdapterEnabled(address(adapter), false);

        ExecutionRequest memory request =
            _swapRequest(keccak256("disabled-adapter"), 0, address(usdc), address(usdt), SWAP_AMOUNT, 0, FEE);

        vm.expectRevert(abi.encodeWithSelector(WalletCore.AdapterDisabled.selector, address(adapter)));
        vm.prank(operator);
        wallet.execute(request);
    }

    function test_RevertWhen_SlippageIsExceededAndBalancesStayUnchanged() public {
        usdc.mint(address(wallet), SWAP_AMOUNT);

        ExecutionRequest memory request =
            _swapRequest(keccak256("slippage"), 0, address(usdc), address(usdt), SWAP_AMOUNT, SWAP_AMOUNT + 1, FEE);

        vm.expectRevert();
        vm.prank(operator);
        wallet.execute(request);

        assertEq(usdc.balanceOf(address(wallet)), SWAP_AMOUNT);
        assertEq(usdt.balanceOf(address(wallet)), 0);
        assertEq(usdt.balanceOf(address(feeCollector)), 0);
        assertFalse(wallet.isQuoteExecuted(request.quoteId));
        assertEq(wallet.executionNonce(), 0);
    }

    function test_RevertWhen_MinimumOutputIsZero() public {
        usdc.mint(address(wallet), SWAP_AMOUNT);

        ExecutionRequest memory request =
            _swapRequest(keccak256("zero-min-output"), 0, address(usdc), address(usdt), SWAP_AMOUNT, 0, FEE);

        vm.expectRevert(WalletCore.InvalidMinBuyAmount.selector);
        vm.prank(operator);
        wallet.execute(request);
    }

    function test_RevertWhen_UnregisteredAdapterIsEnabled() public {
        RouterSwapAdapter otherAdapter = new RouterSwapAdapter(admin);

        vm.expectRevert(abi.encodeWithSelector(AdapterRegistry.AdapterNotConfigured.selector, address(otherAdapter)));
        vm.prank(admin);
        registry.setAdapterEnabled(address(otherAdapter), true);
    }

    function test_RevertWhen_RouterIsNotAllowed() public {
        MockSwapRouter otherRouter = new MockSwapRouter();
        otherRouter.setRate(address(usdc), address(usdt), 1, 1);
        usdt.mint(address(otherRouter), SWAP_AMOUNT);
        usdc.mint(address(wallet), SWAP_AMOUNT);

        ExecutionRequest memory request = _swapRequest(
            keccak256("router-not-allowed"), 0, address(usdc), address(usdt), SWAP_AMOUNT, SWAP_AMOUNT, FEE
        );
        bytes memory routerCall = abi.encodeCall(
            MockSwapRouter.swap, (address(usdc), address(usdt), SWAP_AMOUNT, SWAP_AMOUNT, address(adapter))
        );
        request.adapterData = abi.encode(address(otherRouter), routerCall);

        vm.expectRevert(abi.encodeWithSelector(RouterSwapAdapter.RouterNotAllowed.selector, address(otherRouter)));
        vm.prank(operator);
        wallet.execute(request);
    }

    function test_RevertWhen_NeitherTokenIsUSDT() public {
        MockERC20 dai = new MockERC20("Dai Stablecoin", "DAI", 18);
        usdc.mint(address(wallet), SWAP_AMOUNT);

        ExecutionRequest memory request =
            _swapRequest(keccak256("no-usdt"), 0, address(usdc), address(dai), SWAP_AMOUNT, SWAP_AMOUNT, FEE);

        vm.expectRevert(
            abi.encodeWithSelector(FeePolicy.InvalidTokenPair.selector, address(usdc), address(dai), address(usdt))
        );
        vm.prank(operator);
        wallet.execute(request);
    }

    function test_RevertWhen_SellBalanceIsInsufficient() public {
        ExecutionRequest memory request =
            _swapRequest(keccak256("no-balance"), 0, address(usdc), address(usdt), SWAP_AMOUNT, SWAP_AMOUNT, FEE);

        vm.expectRevert(abi.encodeWithSelector(WalletCore.InsufficientSellBalance.selector, SWAP_AMOUNT, 0));
        vm.prank(operator);
        wallet.execute(request);
    }

    function test_FeeCollectorRejectsDuplicateQuote() public {
        bytes32 quoteId = keccak256("collector-duplicate");
        usdt.mint(address(this), FEE);
        usdt.approve(address(feeCollector), FEE);

        feeCollector.collect(quoteId, FEE);

        vm.expectRevert(abi.encodeWithSelector(FeeCollector.QuoteAlreadyCollected.selector, quoteId));
        feeCollector.collect(quoteId, FEE);
    }

    function test_PauseBlocksExecution() public {
        usdc.mint(address(wallet), SWAP_AMOUNT);

        vm.prank(admin);
        wallet.pause();

        ExecutionRequest memory request =
            _swapRequest(keccak256("paused"), 0, address(usdc), address(usdt), SWAP_AMOUNT, 0, FEE);

        vm.expectRevert();
        vm.prank(operator);
        wallet.execute(request);
    }

    function test_UpgradePreservesState() public {
        usdc.mint(address(wallet), 1_000 * UNIT);

        WalletCoreV2 newImplementation = new WalletCoreV2();
        vm.prank(upgrader);
        wallet.upgradeToAndCall(address(newImplementation), "");

        WalletCoreV2 upgraded = WalletCoreV2(address(wallet));
        assertEq(upgraded.implementationVersion(), "2.0.0");
        assertEq(upgraded.newFeature(), "v2");
        assertTrue(upgraded.hasRole(upgraded.OPERATOR_ROLE(), operator));
        assertEq(usdc.balanceOf(address(wallet)), 1_000 * UNIT);
    }

    function test_NonUpgraderCannotUpgrade() public {
        WalletCoreV2 newImplementation = new WalletCoreV2();

        vm.expectRevert();
        vm.prank(attacker);
        wallet.upgradeToAndCall(address(newImplementation), "");
    }

    function _swapRequest(
        bytes32 quoteId,
        uint256 nonce,
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        uint256 minBuyAmount,
        uint256 fee
    ) private view returns (ExecutionRequest memory request) {
        bytes memory routerCall = abi.encodeCall(
            MockSwapRouter.swap, (sellToken, buyToken, sellAmount, minBuyAmount, address(adapter))
        );

        request = ExecutionRequest({
            quoteId: quoteId,
            wallet: address(wallet),
            serviceType: ServiceType.SWAP,
            adapter: address(adapter),
            sellToken: sellToken,
            buyToken: buyToken,
            sellAmount: sellAmount,
            minBuyAmount: minBuyAmount,
            feeUSDT: fee,
            maxFeeUSDT: fee,
            deadline: uint64(block.timestamp + 1 hours),
            nonce: nonce,
            adapterData: abi.encode(address(router), routerCall)
        });
    }

    function _executionId(ExecutionRequest memory request) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                address(wallet),
                address(router),
                request.sellToken,
                request.buyToken,
                request.sellAmount,
                request.minBuyAmount,
                request.adapterData
            )
        );
    }
}
