// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {DeploymentJson} from "@bao-script/deployment/DeploymentJson.sol";
import {DeploymentDataJsonTesting} from "@bao-script/deployment/DeploymentDataJsonTesting.sol";
import {DeploymentTesting} from "@bao-script/deployment/DeploymentTesting.sol";
import {IDeploymentDataWritable} from "@bao-script/deployment/interfaces/IDeploymentDataWritable.sol";

import {Vm} from "forge-std/Vm.sol";

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

/**
 * @title DeploymentJson
 * @notice JSON-specific deployment layer with file I/O
 * @dev Extends base Deployment with test accessor functions
 */
contract DeploymentJsonTesting is DeploymentJson, DeploymentTesting {
    string private _filename;
    bool _filenameIsSet;
    uint256 private _sequenceNumber; // Incremented on each save
    string private _baseFilename;
    bool private _manualSequencing; // If true, only increment on explicit nextSequence() calls

    /// @notice Enable automatic sequence numbering for capturing update phases
    /// @dev Call this before writes to create .001, .002, .003 files instead of overwriting
    ///      Automatically increments sequence on every change
    function enableSequencing() external {
        _baseFilename = super._getFilename();
        _sequenceNumber = 1;
        _manualSequencing = false;
    }

    /// @notice Enable manual sequence numbering for before/after snapshots
    /// @dev Call nextSequence() explicitly to advance sequence number
    ///      Use this when you want to capture only specific states (e.g., before/after upgrade)
    function enableManualSequencing() external {
        _baseFilename = super._getFilename();
        _sequenceNumber = 1;
        _manualSequencing = true;
    }

    /// @notice Advance to next sequence number and save current state (manual mode only)
    /// @dev Only has effect if enableManualSequencing() was called
    ///      Saves current state to current sequence file, then advances sequence number
    ///      This captures the current state before moving to the next sequence
    function nextSequence() external {
        if (_manualSequencing && _sequenceNumber > 0) {
            // Save current state to current sequence file
            setFilename(string.concat(_baseFilename, ".op", _padZero(_sequenceNumber, 2)));
            save();
            _sequenceNumber++;
        }
    }

    function _afterValueChanged(string memory key) internal override(DeploymentJson, Deployment) {
        // Only auto-increment if sequencing is enabled AND not in manual mode
        if (_sequenceNumber > 0 && !_manualSequencing) {
            setFilename(string.concat(_baseFilename, ".", _padZero(_sequenceNumber, 3), "-", key));
            _sequenceNumber++;
        }
        DeploymentJson._afterValueChanged(key);
    }

    function _getPrefix() internal view override returns (string memory) {
        return DeploymentTestingOutput._getPrefix();
    }

    function toJson() public returns (string memory) {
        return _dataJson.toJson();
    }

    function fromJson(string memory json) public {
        _dataJson.fromJson(json);
    }

    function _getFilename() internal view override returns (string memory) {
        if (_filenameIsSet) return _filename;
        return super._getFilename();
    }

    function setFilename(string memory fileName) public {
        _filename = fileName;
        _filenameIsSet = true;
    }
}
