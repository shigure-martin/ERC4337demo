// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IServiceAdapter } from "../interfaces/IServiceAdapter.sol";
import { AdapterExecution } from "../types/WalletTypes.sol";

contract RouterSwapAdapter is AccessControl, ReentrancyGuard, IServiceAdapter {
    using SafeERC20 for IERC20;

    bytes32 public constant ROUTER_ADMIN_ROLE = keccak256("ROUTER_ADMIN_ROLE");

    mapping(address router => bool) public isRouterAllowed;

    error ZeroAddress();
    error ZeroAmount();
    error RouterNotAllowed(address router);
    error InvalidExecutionData();
    error RouterCallFailed(bytes reason);
    error InsufficientOutput(uint256 received, uint256 required);

    event RouterStatusChanged(address indexed router, bool allowed);
    event SwapExecuted(
        address indexed wallet,
        address indexed sellToken,
        address indexed buyToken,
        uint256 sellAmount,
        uint256 buyAmount
    );

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ROUTER_ADMIN_ROLE, admin);
    }

    function setRouterAllowed(address router, bool allowed) external onlyRole(ROUTER_ADMIN_ROLE) {
        if (router == address(0)) revert ZeroAddress();

        isRouterAllowed[router] = allowed;
        emit RouterStatusChanged(router, allowed);
    }

    function execute(AdapterExecution calldata execution) external nonReentrant returns (bytes32 executionId) {
        if (execution.recipient == address(0)) revert ZeroAddress();
        if (execution.sellAmount == 0) revert ZeroAmount();
        if (execution.sellToken == execution.buyToken) revert InvalidExecutionData();

        (address router, bytes memory routerCallData) = abi.decode(execution.data, (address, bytes));
        if (!isRouterAllowed[router]) revert RouterNotAllowed(router);
        if (routerCallData.length == 0) revert InvalidExecutionData();

        IERC20 sellToken = IERC20(execution.sellToken);
        IERC20 buyToken = IERC20(execution.buyToken);

        uint256 sellBalanceBefore = sellToken.balanceOf(address(this));
        sellToken.safeTransferFrom(msg.sender, address(this), execution.sellAmount);

        uint256 buyBalanceBefore = buyToken.balanceOf(address(this));
        sellToken.forceApprove(router, execution.sellAmount);

        (bool success, bytes memory reason) = router.call(routerCallData);
        sellToken.forceApprove(router, 0);

        if (!success) revert RouterCallFailed(reason);

        uint256 buyBalanceAfter = buyToken.balanceOf(address(this));
        uint256 buyAmount = buyBalanceAfter - buyBalanceBefore;
        if (buyAmount < execution.minBuyAmount) {
            revert InsufficientOutput(buyAmount, execution.minBuyAmount);
        }

        buyToken.safeTransfer(execution.recipient, buyAmount);

        uint256 sellBalanceAfter = sellToken.balanceOf(address(this));
        if (sellBalanceAfter > sellBalanceBefore) {
            sellToken.safeTransfer(execution.recipient, sellBalanceAfter - sellBalanceBefore);
        }

        executionId = keccak256(
            abi.encode(
                msg.sender,
                router,
                execution.sellToken,
                execution.buyToken,
                execution.sellAmount,
                buyAmount,
                execution.data
            )
        );

        emit SwapExecuted(msg.sender, execution.sellToken, execution.buyToken, execution.sellAmount, buyAmount);
    }
}
