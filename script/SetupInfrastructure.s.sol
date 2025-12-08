// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";
import {BaoFactory} from "@bao-script/deployment/BaoFactory.sol";

/**
 * @title SetupInfrastructure
 * @notice Deploys BaoFactory infrastructure
 * @dev Run with: forge script script/SetupInfrastructure.s.sol --broadcast --rpc-url $RPC
 *
 * This script deploys BaoFactory. The setOperator call must be done
 * separately by the multisig owner.
 */
contract SetupInfrastructure is Script {
    function run() public {
        // Deploy BaoFactory if missing
        address baoFactoryAddr = DeploymentInfrastructure.predictBaoFactoryAddress();
        console.log("Predicted BaoFactory address:", baoFactoryAddr);

        if (baoFactoryAddr.code.length == 0) {
            console.log("Deploying BaoFactory...");
            vm.startBroadcast();
            DeploymentInfrastructure._ensureBaoFactory();
            vm.stopBroadcast();
            console.log("BaoFactory deployed at:", baoFactoryAddr);
        } else {
            console.log("BaoFactory already exists at:", baoFactoryAddr);
        }

        // Log current operator
        BaoFactory baoFactory = BaoFactory(baoFactoryAddr);
        console.log("Current operator:", baoFactory.operator());
        console.log("Owner (multisig):", baoFactory.owner());
    }
}
