// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2} from "forge-std/console2.sol";
import {Script} from "forge-std/Script.sol";
import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {DeploymentBase} from "@bao-script/deployment/DeploymentBase.sol";
import {DeploymentDataMemory} from "@bao-script/deployment/DeploymentDataMemory.sol";
import {DeploymentJson} from "@bao-script/deployment/DeploymentJson.sol";

/**
 * @title DeploymentJsonScript
 * @notice Base contract for production deployment scripts
 * @dev Combines Deployment (BaoFactory policy), DeploymentJson (persistence), and Script (broadcast).
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
 *
 *      Inheritance:
 *      - Deployment: _ensureBaoFactory (production: require functional)
 *      - DeploymentJson: JSON persistence, _beforeStart, _lookupContractPath
 *      - Script: forge script utilities
 */
abstract contract DeploymentJsonScript is Deployment, DeploymentJson, Script {
    constructor() DeploymentJson(vm.unixTime() / 1000) {}

    /// @notice Start broadcasting transactions
    /// @dev Called by DeploymentBase before blockchain operations
    function _startBroadcast() internal override returns (address deployer) {
        vm.startBroadcast();
        deployer = msg.sender;
        console2.log("startBroadcast with %s ...", deployer);
    }

    /// @notice Stop broadcasting transactions
    /// @dev Called by DeploymentBase after blockchain operations
    function _stopBroadcast() internal override {
        console2.log("stopBroadcast.");
        vm.stopBroadcast();
    }

    /// @dev Resolve diamond: use Deployment's implementation (production: require functional)
    function _ensureBaoFactory() internal virtual override(DeploymentBase, Deployment) returns (address factory) {
        return Deployment._ensureBaoFactory();
    }

    /// @dev Resolve diamond: use DeploymentJson's implementation (auto-save on change)
    function _afterValueChanged(string memory key) internal virtual override(DeploymentDataMemory, DeploymentJson) {
        DeploymentJson._afterValueChanged(key);
    }
}
