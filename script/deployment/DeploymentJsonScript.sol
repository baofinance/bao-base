// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2} from "forge-std/console2.sol";
import {Script} from "forge-std/Script.sol";
import {BaoFactoryDeployment} from "@bao-factory/BaoFactoryDeployment.sol";
import {DeploymentJson} from "@bao-script/deployment/DeploymentJson.sol";

/**
 * @title DeploymentJsonScript
 * @notice Base contract for production deployment scripts
 * @dev Extends DeploymentJson with broadcast hooks for forge scripts.
 *
 *      Usage:
 *      1. Extend this contract for your deployment script
 *      2. Call start(network, salt, "", deployer) with the deployer address
 *      3. Call setDeployerPk(pk) to set the private key for broadcasting
 *      4. All blockchain operations in deployProxy, finish, etc. will be broadcast
 *
 *      Example:
 *      ```
 *      contract MyDeploy is DeploymentJsonScript {
 *          function run() public {
 *              address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
 *              setDeployerPk(vm.envUint("PRIVATE_KEY"));
 *              start("mainnet", "MySalt", "", deployer);
 *              deployMyToken();
 *              finish();
 *          }
 *      }
 *      ```
 */
abstract contract DeploymentJsonScript is DeploymentJson, Script {
    /// @notice Private key used for broadcasting transactions

    constructor() DeploymentJson(vm.unixTime() / 1000) {}

    /// @notice Start broadcasting transactions
    /// @dev Called by Deployment before blockchain operations
    function _startBroadcast() internal override returns (address deployer) {
        vm.startBroadcast();
        deployer = msg.sender;
        console2.log("startBroadcast with %s ...", deployer);
    }

    /// @notice Stop broadcasting transactions
    /// @dev Called by Deployment after blockchain operations
    function _stopBroadcast() internal override {
        console2.log("stopBroadcast.");
        vm.stopBroadcast();
    }

    /// @notice Deploy BaoFactory using the production bytecode captured in bao-factory
    /// @dev DeploymentJson does not implement _ensureBaoFactory(), so production scripts
    ///      get the canonical behavior directly from this base.
    function _ensureBaoFactory() internal virtual override returns (address factory) {
        factory = BaoFactoryDeployment.ensureBaoFactoryProduction();
    }
}
