// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IAdapterRegistry } from "./interfaces/IAdapterRegistry.sol";
import { IFeeCollector } from "./interfaces/IFeeCollector.sol";
import { IFeePolicy } from "./interfaces/IFeePolicy.sol";
import { IServiceAdapter } from "./interfaces/IServiceAdapter.sol";
import { AdapterExecution, ExecutionRequest, ServiceType } from "./types/WalletTypes.sol";

/**
 * @notice Operator-driven wallet used to execute allowlisted service adapters.
 * @dev Custom state uses an ERC-7201 namespace so future implementations can add
 *      storage without relying on inherited storage gap ordering.
 */
contract WalletCore is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant CONFIG_ADMIN_ROLE = keccak256("CONFIG_ADMIN_ROLE");

    error ZeroAddress();
    error WalletMismatch(address expected, address actual);
    error ZeroQuote();
    error QuoteAlreadyExecuted(bytes32 quoteId);
    error InvalidNonce(uint256 expected, uint256 actual);
    error QuoteExpired(uint64 deadline);
    error ServiceTypeMismatch(ServiceType expected, ServiceType actual);
    error AdapterDisabled(address adapter);
    error InvalidTokenPair(address sellToken, address buyToken);
    error InvalidMinBuyAmount();
    error InsufficientSellBalance(uint256 required, uint256 available);
    error InsufficientBuyAmount(uint256 received, uint256 required);
    error InsufficientFeeBalance(uint256 required, uint256 available);

    event ExecutionSettled(
        bytes32 indexed quoteId,
        address indexed wallet,
        address indexed adapter,
        ServiceType serviceType,
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        uint256 buyAmount,
        uint256 feeUSDT,
        bytes32 executionId
    );
    event AdapterRegistryChanged(address indexed previousRegistry, address indexed newRegistry);
    event FeePolicyChanged(address indexed previousPolicy, address indexed newPolicy);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        address operator,
        address upgrader,
        address adapterRegistry_,
        address feePolicy_,
        address usdt_
    ) external initializer {
        if (
            admin == address(0) || operator == address(0) || upgrader == address(0) || adapterRegistry_ == address(0)
                || feePolicy_ == address(0) || usdt_ == address(0)
        ) {
            revert ZeroAddress();
        }

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, operator);
        _grantRole(UPGRADER_ROLE, upgrader);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(CONFIG_ADMIN_ROLE, admin);

        WalletStorage.Layout storage $ = WalletStorage.layout();
        $.adapterRegistry = adapterRegistry_;
        $.feePolicy = feePolicy_;
        $.usdt = usdt_;
    }

    function execute(ExecutionRequest calldata request) external nonReentrant onlyRole(OPERATOR_ROLE) whenNotPaused {
        if (request.wallet != address(this)) revert WalletMismatch(address(this), request.wallet);
        if (request.quoteId == bytes32(0)) revert ZeroQuote();

        WalletStorage.Layout storage $ = WalletStorage.layout();
        if ($.executedQuotes[request.quoteId]) revert QuoteAlreadyExecuted(request.quoteId);
        if (request.nonce != $.executionNonce) revert InvalidNonce($.executionNonce, request.nonce);
        if (request.deadline < block.timestamp) revert QuoteExpired(request.deadline);

        IAdapterRegistry registry = IAdapterRegistry($.adapterRegistry);
        if (!registry.isAdapterEnabled(request.adapter)) revert AdapterDisabled(request.adapter);

        ServiceType registeredType = registry.serviceTypeOf(request.adapter);
        if (registeredType != request.serviceType) {
            revert ServiceTypeMismatch(registeredType, request.serviceType);
        }

        address feeCollector = IFeePolicy($.feePolicy)
            .validateFee(request.sellToken, request.buyToken, request.feeUSDT, request.maxFeeUSDT);

        IERC20 sellToken = IERC20(request.sellToken);
        IERC20 buyToken = IERC20(request.buyToken);
        IERC20 usdtToken = IERC20($.usdt);

        if (request.sellToken == request.buyToken) {
            revert InvalidTokenPair(request.sellToken, request.buyToken);
        }
        if (request.serviceType == ServiceType.SWAP && request.minBuyAmount == 0) {
            revert InvalidMinBuyAmount();
        }

        uint256 sellBalance = sellToken.balanceOf(address(this));
        uint256 requiredSellBalance = request.sellAmount;
        if (request.sellToken == $.usdt && sellBalance >= request.sellAmount) {
            requiredSellBalance += request.feeUSDT;
        }
        if (sellBalance < requiredSellBalance) {
            revert InsufficientSellBalance(requiredSellBalance, sellBalance);
        }

        $.executedQuotes[request.quoteId] = true;
        $.executionNonce += 1;

        uint256 buyBalanceBefore = buyToken.balanceOf(address(this));

        sellToken.forceApprove(request.adapter, request.sellAmount);
        bytes32 executionId = IServiceAdapter(request.adapter)
            .execute(
                AdapterExecution({
                    sellToken: request.sellToken,
                    buyToken: request.buyToken,
                    sellAmount: request.sellAmount,
                    minBuyAmount: request.minBuyAmount,
                    recipient: address(this),
                    data: request.adapterData
                })
            );
        sellToken.forceApprove(request.adapter, 0);

        uint256 buyBalanceAfter = buyToken.balanceOf(address(this));
        uint256 buyAmount = buyBalanceAfter - buyBalanceBefore;
        if (request.serviceType == ServiceType.SWAP && buyAmount < request.minBuyAmount) {
            revert InsufficientBuyAmount(buyAmount, request.minBuyAmount);
        }

        uint256 feeBalance = usdtToken.balanceOf(address(this));
        if (feeBalance < request.feeUSDT) revert InsufficientFeeBalance(request.feeUSDT, feeBalance);

        usdtToken.forceApprove(feeCollector, request.feeUSDT);
        IFeeCollector(feeCollector).collect(request.quoteId, request.feeUSDT);
        usdtToken.forceApprove(feeCollector, 0);

        emit ExecutionSettled(
            request.quoteId,
            address(this),
            request.adapter,
            request.serviceType,
            request.sellToken,
            request.buyToken,
            request.sellAmount,
            buyAmount,
            request.feeUSDT,
            executionId
        );
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function setAdapterRegistry(address newRegistry) external onlyRole(CONFIG_ADMIN_ROLE) {
        if (newRegistry == address(0)) revert ZeroAddress();

        WalletStorage.Layout storage $ = WalletStorage.layout();
        address previousRegistry = $.adapterRegistry;
        $.adapterRegistry = newRegistry;

        emit AdapterRegistryChanged(previousRegistry, newRegistry);
    }

    function setFeePolicy(address newPolicy) external onlyRole(CONFIG_ADMIN_ROLE) {
        if (newPolicy == address(0)) revert ZeroAddress();

        WalletStorage.Layout storage $ = WalletStorage.layout();
        address previousPolicy = $.feePolicy;
        $.feePolicy = newPolicy;

        emit FeePolicyChanged(previousPolicy, newPolicy);
    }

    function adapterRegistry() external view returns (address) {
        return WalletStorage.layout().adapterRegistry;
    }

    function feePolicy() external view returns (address) {
        return WalletStorage.layout().feePolicy;
    }

    function usdt() external view returns (address) {
        return WalletStorage.layout().usdt;
    }

    function executionNonce() external view returns (uint256) {
        return WalletStorage.layout().executionNonce;
    }

    function isQuoteExecuted(bytes32 quoteId) external view returns (bool) {
        return WalletStorage.layout().executedQuotes[quoteId];
    }

    function implementationVersion() public pure virtual returns (string memory) {
        return "1.0.0";
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) { }
}

library WalletStorage {
    /// @dev keccak256(abi.encode(uint256(keccak256("erc4337demo.wallet.main")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT = 0x446af2d8fd90a641508c5ffa658ffb213cd5097b688351bdcf53ffb375685600;

    struct Layout {
        address adapterRegistry;
        address feePolicy;
        address usdt;
        uint256 executionNonce;
        mapping(bytes32 quoteId => bool executed) executedQuotes;
    }

    function layout() internal pure returns (Layout storage $) {
        bytes32 slot = SLOT;
        assembly {
            $.slot := slot
        }
    }
}
