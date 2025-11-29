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
    string private _dir; // Namespace for test suite outputs
    bool _dirIsSet;
    string private _filename;
    bool _filenameIsSet;

    function _getPrefix() internal view override returns (string memory) {
        return DeploymentTestingOutput._getPrefix();
    }

    function toJson() public returns (string memory) {
        return _dataJson.toJson();
    }

    function fromJson(string memory json) public {
        _dataJson.fromJson(json);
    }

    function _getDir() internal view override returns (string memory) {
        if (_dirIsSet) return _dir;
        return super._getDir();
    }

    function _getFilename() internal view override returns (string memory) {
        if (_filenameIsSet) return _filename;
        return super._getFilename();
    }

    function setDir(string memory dir) public {
        _dir = dir;
        _dirIsSet = true;
    }

    function setFilename(string memory fileName) public {
        _filename = fileName;
        _filenameIsSet = true;
    }

    //     /// @notice Set custom output filename for this test (prevents output collisions)
    //     /// @param filename Custom filename without path or extension (e.g., "test_DeployProxy")
    //     function setOutputFilename(string memory filename) public {
    //         string memory network = bytes(_networkLabel).length > 0 ? _networkLabel : _dataJson.getString(SESSION_NETWORK);
    //         string memory baseDir = _getPrefix();
    //         string memory outputPath = string.concat(baseDir, "/deployments/", network, "/", filename, ".json");
    //         _dataJson.setOutputPath(outputPath);
    //     }
}
