// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ServiceType } from "../types/WalletTypes.sol";

interface IAdapterRegistry {
    function isAdapterEnabled(address adapter) external view returns (bool);

    function serviceTypeOf(address adapter) external view returns (ServiceType);
}
