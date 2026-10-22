// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IFeeCollector {
    function collect(bytes32 quoteId, uint256 amount) external;
}
