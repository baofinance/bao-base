// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {DeploymentDataJsonTesting} from "@bao-script/deployment/DeploymentDataJsonTesting.sol";
import {IDeploymentDataJson} from "@bao-script/deployment/interfaces/IDeploymentDataJson.sol";

/// @title DeploymentLogsTest
/// @notice Provides deterministic filesystem scaffolding for deployment-oriented tests
/// @dev Ensures every test contract writes under a dedicated results/deployments/<suite> root
///      and exposes helpers for per-test filenames so suites remain reproducible.
abstract contract DeploymentLogsTest is BaoTest {
    string private deploymentLogsDir_;
    mapping(string => bool) private alreadyReset;

    /// @notice Get deployment base directory, respecting BAO_DEPLOYMENT_LOGS_ROOT
    /// @dev Matches the logic in DeploymentTesting._getDeploymentBaseDir()
    function _getDeploymentBaseDir() internal view returns (string memory) {
        try vm.envString("BAO_DEPLOYMENT_LOGS_ROOT") returns (string memory customRoot) {
            if (bytes(customRoot).length > 0) {
                return customRoot;
            }
        } catch {
            // Environment variable not set, use default
        }
        return "results";
    }

    /// @notice Prepare a clean deployments directory for the current test suite
    function _resetDeploymentLogs(string memory suiteLabel) internal {
        string memory baseDir = _getDeploymentBaseDir();
        deploymentLogsDir_ = string.concat(baseDir, "/deployments/", suiteLabel);
        if (!alreadyReset[deploymentLogsDir_]) {
            alreadyReset[deploymentLogsDir_] = true;
            if (vm.exists(deploymentLogsDir_)) {
                vm.removeDir(deploymentLogsDir_, true);
            }
            vm.createDir(deploymentLogsDir_, true);
        }
    }

    /// @notice Set output filename for a test using the data layer's setOutputPath
    function _setTestOutputPath(IDeploymentDataJson dataStore, string memory prefix, string memory testName) internal {
        string memory fileName = "";
        if (bytes(prefix).length == 0) {
            fileName = testName;
        } else if (bytes(testName).length == 0) {
            fileName = prefix;
        } else {
            fileName = string.concat(prefix, "-", testName);
        }
        string memory fullPath = string.concat(deploymentLogsDir_, "/", fileName, ".json");
        dataStore.setOutputPath(fullPath);
    }

    function _deploymentLogsDir() internal view returns (string memory) {
        require(bytes(deploymentLogsDir_).length > 0, "need to set deployment logs dir");
        return deploymentLogsDir_;
    }
}
