// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeploymentJson} from "@bao-script/deployment/DeploymentJson.sol";
import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {DeploymentDataMemory} from "@bao-script/deployment/DeploymentDataMemory.sol";
import {DeploymentTestingEnablers} from "@bao-script/deployment/DeploymentTestingEnablers.sol";
import {BaoDeployer} from "@bao-script/deployment/BaoDeployer.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";
import {BaoDeployerSetOperator} from "@bao-script/deployment/BaoDeployerSetOperator.sol";
import {UUPSProxyDeployStub} from "@bao-script/deployment/UUPSProxyDeployStub.sol";

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

    /// @notice Deploy stub for testing
    /// @dev Override of Deployment._deployStub() - deploys fresh stub for each test
    function _deployStub() internal override {
        _stub = new UUPSProxyDeployStub();
        _stubContractType = "UUPSProxyDeployStub";
        _stubContractPath = "script/deployment/UUPSProxyDeployStub.sol";
        _stubBlockNumber = block.number;
    }

    // ============================================================================
    // Test Output Configuration
    // ============================================================================

    function _getPrefix() internal view override returns (string memory) {
        return DeploymentTestingOutput._getPrefix();
    }

    // function _getFilename() internal view virtual override returns (string memory) {
    //     if (_filenameIsSet) return _filename;
    //     return super._getFilename();
    // }

    // function setFilename(string memory fileName) public {
    //     _filename = fileName;
    //     _filenameIsSet = true;
    // }

    // ============================================================================
    // Sequencing for Capturing Deployment Phases
    // ============================================================================

    /// @notice Enable automatic sequence numbering for capturing update phases
    /// @dev Call this before writes to create .001, .002, .003 files instead of overwriting
    ///      Automatically increments sequence on every change
    // function enableSequencing() external {
    //     // _baseFilename = super._getFilename();
    //     _sequenceNumber = 1;
    // }

    // /// @notice Enable manual sequence numbering for before/after snapshots
    // /// @dev Call nextSequence() explicitly to advance sequence number
    // ///      Use this when you want to capture only specific states (e.g., before/after upgrade)
    // function enableManualSequencing() external {
    //     _baseFilename = super._getFilename();
    //     _sequenceNumber = 1;
    //     _manualSequencing = true;
    // }

    // /// @notice Advance to next sequence number and save current state (manual mode only)
    // /// @dev Only has effect if enableManualSequencing() was called
    // ///      Saves current state to current sequence file, then advances sequence number
    // ///      This captures the current state before moving to the next sequence
    // function saveSequence() external {
    //     if (_manualSequencing && _sequenceNumber > 0) {
    //         // Save current state to current sequence file
    //         setFilename(string.concat(_baseFilename, ".op", _padZero(_sequenceNumber, 2)));
    //         save();
    //         _sequenceNumber++;
    //     }
    // }

    // function _afterValueChanged(string memory key) internal override(DeploymentJson, DeploymentDataMemory) {
    //     // Only auto-increment if sequencing is enabled AND not in manual mode
    //     if (_sequenceNumber > 0 ) {
    //         setFilename(string.concat(_baseFilename, ".", _padZero(_sequenceNumber, 3), "-", key));
    //         _sequenceNumber++;
    //     }
    //     super._afterValueChanged(key);
    // }

    // ============================================================================
    // BaoDeployer Operator Setup (Testing)
    // ============================================================================

    /// @notice Set up BaoDeployer operator using vm.prank (testing only)
    /// @dev Overrides DeploymentJson production check with mixin-based setup
    function _ensureBaoDeployerOperator() internal override(DeploymentJson, Deployment) {
        _setUpBaoDeployerOperator();
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
