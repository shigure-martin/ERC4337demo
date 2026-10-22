// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IAdapterRegistry } from "./interfaces/IAdapterRegistry.sol";
import { ServiceType } from "./types/WalletTypes.sol";

contract AdapterRegistry is AccessControl, IAdapterRegistry {
    bytes32 public constant ADAPTER_ADMIN_ROLE = keccak256("ADAPTER_ADMIN_ROLE");

    struct AdapterInfo {
        ServiceType serviceType;
        bool configured;
        bool enabled;
    }

    mapping(address adapter => AdapterInfo) private _adapters;

    error ZeroAddress();
    error AdapterNotConfigured(address adapter);
    error AdapterAlreadyEnabled(address adapter);

    event AdapterRegistered(address indexed adapter, ServiceType indexed serviceType);
    event AdapterStatusChanged(address indexed adapter, bool enabled);

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADAPTER_ADMIN_ROLE, admin);
    }

    function registerAdapter(address adapter, ServiceType serviceType) external onlyRole(ADAPTER_ADMIN_ROLE) {
        if (adapter == address(0)) revert ZeroAddress();
        if (adapter.code.length == 0) revert AdapterNotConfigured(adapter);

        AdapterInfo storage info = _adapters[adapter];
        if (info.configured && info.enabled) revert AdapterAlreadyEnabled(adapter);

        info.serviceType = serviceType;
        info.configured = true;
        info.enabled = true;

        emit AdapterRegistered(adapter, serviceType);
    }

    function setAdapterEnabled(address adapter, bool enabled) external onlyRole(ADAPTER_ADMIN_ROLE) {
        AdapterInfo storage info = _adapters[adapter];
        if (adapter == address(0) || adapter.code.length == 0) revert AdapterNotConfigured(adapter);
        if (!info.configured) revert AdapterNotConfigured(adapter);

        info.enabled = enabled;
        emit AdapterStatusChanged(adapter, enabled);
    }

    function isAdapterEnabled(address adapter) external view returns (bool) {
        return _adapters[adapter].enabled;
    }

    function serviceTypeOf(address adapter) external view returns (ServiceType) {
        return _adapters[adapter].serviceType;
    }
}
