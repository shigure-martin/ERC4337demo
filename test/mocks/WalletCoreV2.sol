// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { WalletCore } from "../../src/WalletCore.sol";

contract WalletCoreV2 is WalletCore {
    function implementationVersion() public pure override returns (string memory) {
        return "2.0.0";
    }

    function newFeature() external pure returns (string memory) {
        return "v2";
    }
}
