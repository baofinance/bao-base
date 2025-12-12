// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";
import {BaoFactory} from "@bao/factory/BaoFactory.sol";

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
            DeploymentInfrastructure._ensureBaoFactoryProduction();
            vm.stopBroadcast();
            console.log("BaoFactory deployed at:", baoFactoryAddr);
        } else {
            console.log("BaoFactory already exists at:", baoFactoryAddr);
        }

        // Log current operators
        BaoFactory baoFactory = BaoFactory(baoFactoryAddr);
        (address[] memory ops, uint256[] memory expiries) = baoFactory.operators();
        console.log("Operators count:", ops.length);
        for (uint256 i = 0; i < ops.length; i++) {
            console.log("  Operator:", ops[i], "expires:", expiries[i]);
        }
        console.log("Owner (multisig):", baoFactory.owner());
    }
}
