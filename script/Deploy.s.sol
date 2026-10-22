// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { AdapterRegistry } from "../src/AdapterRegistry.sol";
import { FeeCollector } from "../src/FeeCollector.sol";
import { FeePolicy } from "../src/FeePolicy.sol";
import { RouterSwapAdapter } from "../src/adapters/RouterSwapAdapter.sol";
import { WalletCore } from "../src/WalletCore.sol";
import { WalletFactory } from "../src/WalletFactory.sol";
import { ServiceType } from "../src/types/WalletTypes.sol";

contract Deploy is Script {
    struct Deployment {
        address feeCollector;
        address feePolicy;
        address adapterRegistry;
        address swapAdapter;
        address walletImplementation;
        address walletFactory;
    }

    function run() external returns (Deployment memory deployment) {
        address treasury = vm.envAddress("TREASURY");
        address usdt = vm.envAddress("USDT");
        uint256 maxFeeUSDT = vm.envOr("MAX_FEE_USDT", uint256(10e6));
        address router = vm.envOr("ROUTER", address(0));

        vm.startBroadcast();

        address admin = msg.sender;
        deployment.feeCollector = address(new FeeCollector(admin, usdt, treasury));
        deployment.feePolicy = address(new FeePolicy(admin, usdt, deployment.feeCollector, maxFeeUSDT));
        deployment.adapterRegistry = address(new AdapterRegistry(admin));
        deployment.swapAdapter = address(new RouterSwapAdapter(admin));

        AdapterRegistry(deployment.adapterRegistry).registerAdapter(deployment.swapAdapter, ServiceType.SWAP);
        if (router != address(0)) {
            RouterSwapAdapter(deployment.swapAdapter).setRouterAllowed(router, true);
        }

        deployment.walletImplementation = address(new WalletCore());
        deployment.walletFactory = address(new WalletFactory(admin, deployment.walletImplementation));

        vm.stopBroadcast();

        console2.log("Admin", admin);
        console2.log("Treasury", treasury);
        console2.log("USDT", usdt);
        console2.log("Router", router);
        console2.log("FeeCollector", deployment.feeCollector);
        console2.log("FeePolicy", deployment.feePolicy);
        console2.log("AdapterRegistry", deployment.adapterRegistry);
        console2.log("SwapAdapter", deployment.swapAdapter);
        console2.log("WalletFactory", deployment.walletFactory);
    }
}
