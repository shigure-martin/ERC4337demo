// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { WalletCore } from "./WalletCore.sol";

contract WalletFactory is AccessControl {
    bytes32 public constant WALLET_ADMIN_ROLE = keccak256("WALLET_ADMIN_ROLE");
    bytes32 public constant IMPLEMENTATION_ADMIN_ROLE = keccak256("IMPLEMENTATION_ADMIN_ROLE");

    struct WalletInitParams {
        address admin;
        address operator;
        address upgrader;
        address adapterRegistry;
        address feePolicy;
        address usdt;
    }

    address public implementation;
    mapping(bytes32 salt => address wallet) public walletBySalt;

    error ZeroAddress();
    error InvalidImplementation(address implementation);
    error WalletAlreadyDeployed(address wallet);

    event WalletDeployed(
        address indexed wallet, address indexed admin, address indexed upgrader, bytes32 salt, address implementation
    );
    event ImplementationChanged(address indexed previousImplementation, address indexed newImplementation);

    constructor(address admin, address implementation_) {
        if (admin == address(0) || implementation_ == address(0)) revert ZeroAddress();
        if (implementation_.code.length == 0) revert InvalidImplementation(implementation_);

        implementation = implementation_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(WALLET_ADMIN_ROLE, admin);
        _grantRole(IMPLEMENTATION_ADMIN_ROLE, admin);
    }

    function deployWallet(bytes32 salt, WalletInitParams calldata params)
        external
        onlyRole(WALLET_ADMIN_ROLE)
        returns (address wallet)
    {
        bytes memory initializer = _initializer(params);
        address predicted = _predictAddress(salt, initializer);
        if (predicted.code.length != 0) revert WalletAlreadyDeployed(predicted);

        wallet = address(new ERC1967Proxy{ salt: salt }(implementation, initializer));
        walletBySalt[salt] = wallet;

        emit WalletDeployed(wallet, params.admin, params.upgrader, salt, implementation);
    }

    function predictWalletAddress(bytes32 salt, WalletInitParams calldata params) external view returns (address) {
        return _predictAddress(salt, _initializer(params));
    }

    function setImplementation(address newImplementation) external onlyRole(IMPLEMENTATION_ADMIN_ROLE) {
        if (newImplementation == address(0)) revert ZeroAddress();
        if (newImplementation.code.length == 0) revert InvalidImplementation(newImplementation);

        address previousImplementation = implementation;
        implementation = newImplementation;

        emit ImplementationChanged(previousImplementation, newImplementation);
    }

    function _initializer(WalletInitParams calldata params) private pure returns (bytes memory) {
        return abi.encodeCall(
            WalletCore.initialize,
            (params.admin, params.operator, params.upgrader, params.adapterRegistry, params.feePolicy, params.usdt)
        );
    }

    function _predictAddress(bytes32 salt, bytes memory initializer) private view returns (address) {
        bytes memory bytecode = bytes.concat(type(ERC1967Proxy).creationCode, abi.encode(implementation, initializer));
        bytes32 bytecodeHash = keccak256(bytecode);
        return Create2.computeAddress(salt, bytecodeHash, address(this));
    }
}
