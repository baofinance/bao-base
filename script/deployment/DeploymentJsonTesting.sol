// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeploymentJson} from "@bao-script/deployment/DeploymentJson.sol";
import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {DeploymentDataMemory} from "@bao-script/deployment/DeploymentDataMemory.sol";
import {DeploymentTestingEnablers} from "@bao-script/deployment/DeploymentTestingEnablers.sol";
import {BaoDeployer} from "@bao-script/deployment/BaoDeployer.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";
import {BaoDeployerSetOperator} from "@bao-script/deployment/BaoDeployerSetOperator.sol";

import {Vm} from "forge-std/Vm.sol";

/**
 * @title DeploymentJsonTesting
 * @notice JSON deployment layer extended for test environments
 * @dev Adds test output directory, filename overrides, sequencing, and vm.prank support
 *
 * Inherits:
 * - DeploymentJson: Full JSON persistence with setter hooks
 * - BaoDeployerSetOperator: vm.prank operator setup for testing
 *
 * Provides:
 * - Test output directory (BAO_DEPLOYMENT_LOGS_ROOT or "results")
 * - Filename override for custom output paths
 * - Automatic/manual sequencing for capturing deployment phases
 * - setContractAddress() for test injection via vm.prank
 */
contract DeploymentJsonTesting is DeploymentJson, DeploymentTestingEnablers, BaoDeployerSetOperator {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // string private _filename;
    // bool _filenameIsSet;
    // uint256 private _sequenceNumber; // Incremented on each save
    // string private _baseFilename;
    // bool private _manualSequencing; // If true, only increment on explicit nextSequence() calls

    /// @notice Start deployment session with deployer defaulting to address(this)
    /// @dev Convenience overload for tests where the harness is the deployer
    function start(string memory network_, string memory systemSaltString_, string memory startPoint) public {
        start(network_, systemSaltString_, address(this), startPoint);
    }

    /// @notice Start deployment session with explicit deployer
    function start(
        string memory network_,
        string memory systemSaltString_,
        address deployer,
        string memory startPoint
    ) public override(DeploymentJson, Deployment) {
        DeploymentJson.start(network_, systemSaltString_, deployer, startPoint);
    }

    // ============================================================================
    // Test Output Configuration
    // ============================================================================

    function _getPrefix() internal view override returns (string memory) {
        return DeploymentTestingOutput._getPrefix();
    }

    /// @notice Simulate predictable deploys with insufficient value to validate ValueMismatch paths
    function simulatePredictableDeployWithoutFunding(
        uint256 value,
        string memory key,
        bytes memory initCode,
        string memory /* contractType */,
        string memory /* contractPath */
    ) external returns (address addr) {
        return _simulatePredictableDeployWithoutFundingInternal(value, key, initCode);
    }

    // ============================================================================
    // Test Contract Address Injection
    // ============================================================================

    /// @notice Set a contract address in the deployment data via vm.prank
    /// @dev Uses vm.prank to make the call appear to come from the BaoDeployer operator
    /// @param key The contract key
    /// @param addr The contract address to set
    function setContractAddress(string memory key, address addr) public {
        address operator = BaoDeployer(DeploymentInfrastructure.predictBaoDeployerAddress()).operator();
        VM.prank(operator);
        _set(key, addr);
    }
}

library DeploymentTestingOutput {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function _getPrefix() internal view returns (string memory) {
        try VM.envString("BAO_DEPLOYMENT_LOGS_ROOT") returns (string memory customRoot) {
            if (bytes(customRoot).length > 0) {
                return customRoot;
            }
        } catch {
            // Environment variable not set, use default
        }
        return "results";
    }
}
