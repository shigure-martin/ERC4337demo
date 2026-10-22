// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IFeeCollector } from "./interfaces/IFeeCollector.sol";

contract FeeCollector is AccessControl, IFeeCollector {
    using SafeERC20 for IERC20;

    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");

    IERC20 public immutable token;
    address public treasury;
    uint256 public totalCollected;

    mapping(bytes32 quoteId => bool) public quoteCollected;

    error ZeroAddress();
    error ZeroAmount();
    error QuoteAlreadyCollected(bytes32 quoteId);
    error InsufficientFees(uint256 requested, uint256 available);

    event FeeCollected(bytes32 indexed quoteId, address indexed wallet, address indexed token, uint256 amount);
    event FeesWithdrawn(address indexed recipient, uint256 amount);
    event TreasuryChanged(address indexed previousTreasury, address indexed newTreasury);

    constructor(address admin, address token_, address treasury_) {
        if (admin == address(0) || token_ == address(0) || treasury_ == address(0)) {
            revert ZeroAddress();
        }

        token = IERC20(token_);
        treasury = treasury_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TREASURER_ROLE, admin);
    }

    function collect(bytes32 quoteId, uint256 amount) external override {
        if (amount == 0) revert ZeroAmount();
        if (quoteCollected[quoteId]) revert QuoteAlreadyCollected(quoteId);

        quoteCollected[quoteId] = true;
        totalCollected += amount;

        token.safeTransferFrom(msg.sender, address(this), amount);

        emit FeeCollected(quoteId, msg.sender, address(token), amount);
    }

    function withdraw(address recipient, uint256 amount) external onlyRole(TREASURER_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 available = token.balanceOf(address(this));
        if (amount > available) revert InsufficientFees(amount, available);

        token.safeTransfer(recipient, amount);
        emit FeesWithdrawn(recipient, amount);
    }

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();

        address previousTreasury = treasury;
        treasury = newTreasury;

        emit TreasuryChanged(previousTreasury, newTreasury);
    }
}
