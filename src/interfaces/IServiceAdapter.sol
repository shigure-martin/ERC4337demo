// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { AdapterExecution } from "../types/WalletTypes.sol";

interface IServiceAdapter {
    function execute(AdapterExecution calldata execution) external returns (bytes32 executionId);
}
