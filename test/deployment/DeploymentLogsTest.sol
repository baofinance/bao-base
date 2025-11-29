// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {DeploymentTestingOutput} from "@bao-script/deployment/DeploymentJsonTesting.sol";

/// @title DeploymentLogsTest
/// @notice Provides deterministic filesystem scaffolding for deployment-oriented tests
/// @dev Ensures every test contract writes under a dedicated results/deployments/<suite> root
///      and exposes helpers for per-test filenames so suites remain reproducible.
abstract contract DeploymentLogsTest is BaoTest {
    string private deploymentLogsDir_;
    mapping(string => bool) private alreadyReset;

    /// @notice Prepare a clean deployments directory for the current test suite
    function _resetDeploymentLogs(string memory suiteLabel) internal {
        string memory baseDir = DeploymentTestingOutput._getPrefix();
        deploymentLogsDir_ = string.concat(baseDir, "/deployments/", suiteLabel);
        if (!alreadyReset[deploymentLogsDir_]) {
            alreadyReset[deploymentLogsDir_] = true;
            if (vm.exists(deploymentLogsDir_)) {
                vm.removeDir(deploymentLogsDir_, true);
            }
            vm.createDir(deploymentLogsDir_, true);
        }
    }
}
