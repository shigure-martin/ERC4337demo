// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

enum ServiceType {
    SWAP,
    BRIDGE
}

struct ExecutionRequest {
    bytes32 quoteId;
    address wallet;
    ServiceType serviceType;
    address adapter;
    address sellToken;
    address buyToken;
    uint256 sellAmount;
    uint256 minBuyAmount;
    uint256 feeUSDT;
    uint256 maxFeeUSDT;
    uint64 deadline;
    uint256 nonce;
    bytes adapterData;
}

struct AdapterExecution {
    address sellToken;
    address buyToken;
    uint256 sellAmount;
    uint256 minBuyAmount;
    address recipient;
    bytes data;
}
