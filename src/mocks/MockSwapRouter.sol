// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockSwapRouter is Ownable {
    using SafeERC20 for IERC20;

    struct Rate {
        uint256 numerator;
        uint256 denominator;
    }

    mapping(address sellToken => mapping(address buyToken => Rate)) public rates;

    error InvalidPair();
    error InvalidRate();
    error InsufficientOutput(uint256 received, uint256 required);

    event RateSet(address indexed sellToken, address indexed buyToken, uint256 numerator, uint256 denominator);
    event Swap(
        address indexed sender, address indexed sellToken, address indexed buyToken, uint256 amountIn, uint256 amountOut
    );

    constructor() Ownable(msg.sender) { }

    function setRate(address sellToken, address buyToken, uint256 numerator, uint256 denominator) external onlyOwner {
        if (sellToken == address(0) || buyToken == address(0) || sellToken == buyToken) revert InvalidPair();
        if (numerator == 0 || denominator == 0) revert InvalidRate();

        rates[sellToken][buyToken] = Rate({ numerator: numerator, denominator: denominator });
        emit RateSet(sellToken, buyToken, numerator, denominator);
    }

    function swap(address sellToken, address buyToken, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256 amountOut)
    {
        Rate memory rate = rates[sellToken][buyToken];
        if (rate.numerator == 0 || rate.denominator == 0) revert InvalidPair();

        IERC20(sellToken).safeTransferFrom(msg.sender, address(this), amountIn);
        amountOut = amountIn * rate.numerator / rate.denominator;
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);

        IERC20(buyToken).safeTransfer(recipient, amountOut);
        emit Swap(msg.sender, sellToken, buyToken, amountIn, amountOut);
    }
}
