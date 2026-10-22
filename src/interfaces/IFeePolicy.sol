// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IFeePolicy {
    function usdt() external view returns (address);

    function feeCollector() external view returns (address);

    function validateFee(address sellToken, address buyToken, uint256 feeUSDT, uint256 maxFeeUSDT)
        external
        view
        returns (address collector);
}
