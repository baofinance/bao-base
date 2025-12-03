// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";
import {BaoDeployer} from "@bao-script/deployment/BaoDeployer.sol";

/**
 * @title SetupInfrastructure
 * @notice Deploys BaoDeployer infrastructure
 * @dev Run with: forge script script/SetupInfrastructure.s.sol --broadcast --rpc-url $RPC
 *
 * This script deploys BaoDeployer. The setOperator call must be done
 * separately by the multisig owner.
 */
contract SetupInfrastructure is Script {
    function run() public {
        // Deploy BaoDeployer if missing
        address baoDeployerAddr = DeploymentInfrastructure.predictBaoDeployerAddress();
        console.log("Predicted BaoDeployer address:", baoDeployerAddr);

        if (baoDeployerAddr.code.length == 0) {
            console.log("Deploying BaoDeployer...");
            vm.startBroadcast();
            DeploymentInfrastructure._ensureBaoDeployer();
            vm.stopBroadcast();
            console.log("BaoDeployer deployed at:", baoDeployerAddr);
        } else {
            console.log("BaoDeployer already exists at:", baoDeployerAddr);
        }

        // Log current operator
        BaoDeployer baoDeployer = BaoDeployer(baoDeployerAddr);
        console.log("Current operator:", baoDeployer.operator());
        console.log("Owner (multisig):", baoDeployer.owner());
    }
}
