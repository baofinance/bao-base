// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
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
    uint256 private _deployerPk;

    /// @notice Set the deployer private key for broadcast operations
    /// @param pk Private key to use for vm.startBroadcast()
    function setDeployerPk(uint256 pk) internal {
        _deployerPk = pk;
    }

    /// @notice Start broadcasting transactions
    /// @dev Called by Deployment before blockchain operations
    function _startBroadcast() internal override {
        vm.startBroadcast(_deployerPk);
    }

    /// @notice Stop broadcasting transactions
    /// @dev Called by Deployment after blockchain operations
    function _stopBroadcast() internal override {
        vm.stopBroadcast();
    }
}
