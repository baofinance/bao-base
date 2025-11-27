// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {DeploymentKeys} from "@bao-script/deployment/DeploymentKeys.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";
import {BaoDeployer} from "@bao-script/deployment/BaoDeployer.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * @title DeploymentTesting
 * @notice Base contract for deployment testing
 * @dev Provides:
 *      - results/ directory configuration
 *      - No system salt subdirectory
 *      - Automatic BaoDeployer operator setup
 *      - Directory cleaning before deployment
 *      - Public API for test configuration (setString, setAddress, etc.)
 */
abstract contract DeploymentTesting is Deployment {
    Vm constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // ============================================================================
    // Public Configuration API (for testing only)
    // ============================================================================

    function get(string memory key) public view returns (address) {
        return _get(key);
    }

    function has(string memory key) public view returns (bool) {
        return _has(key);
    }

    function setString(string memory key, string memory value) public {
        _setString(key, value);
    }

    function getString(string memory key) public view returns (string memory) {
        return _getString(key);
    }

    function setAddress(string memory key, address value) public {
        _setAddress(key, value);
    }

    function getAddress(string memory key) public view returns (address) {
        return _getAddress(key);
    }

    function setUint(string memory key, uint256 value) public {
        _setUint(key, value);
    }

    function getUint(string memory key) public view returns (uint256) {
        return _getUint(key);
    }

    function setBool(string memory key, bool value) public {
        _setBool(key, value);
    }

    function getBool(string memory key) public view returns (bool) {
        return _getBool(key);
    }

    function setInt(string memory key, int256 value) public {
        _setInt(key, value);
    }

    function getInt(string memory key) public view returns (int256) {
        return _getInt(key);
    }

    // Array methods
    function setAddressArray(string memory key, address[] memory value) public {
        _setAddressArray(key, value);
    }

    function getAddressArray(string memory key) public view returns (address[] memory) {
        return _getAddressArray(key);
    }

    function setStringArray(string memory key, string[] memory value) public {
        _setStringArray(key, value);
    }

    function getStringArray(string memory key) public view returns (string[] memory) {
        return _getStringArray(key);
    }

    function setUintArray(string memory key, uint256[] memory value) public {
        _setUintArray(key, value);
    }

    function getUintArray(string memory key) public view returns (uint256[] memory) {
        return _getUintArray(key);
    }

    function setIntArray(string memory key, int256[] memory value) public {
        _setIntArray(key, value);
    }

    function getIntArray(string memory key) public view returns (int256[] memory) {
        return _getIntArray(key);
    }

    // ============================================================================
    // Test Infrastructure Overrides
    // ============================================================================

    /// @notice Override for testing - use results/ directory (or BAO_DEPLOYMENT_LOGS_ROOT if set)
    /// @dev Checks BAO_DEPLOYMENT_LOGS_ROOT environment variable for custom test output location
    function _getDeploymentBaseDir() internal view virtual override returns (string memory) {
        try VM.envString("BAO_DEPLOYMENT_LOGS_ROOT") returns (string memory customRoot) {
            if (bytes(customRoot).length > 0) {
                return customRoot;
            }
        } catch {
            // Environment variable not set, use default
        }
        return "results";
    }

    /// @notice Override for testing - no system salt subdirectory
    function _useSystemSaltSubdir() internal view virtual override returns (bool) {
        return false;
    }

    /// @notice Override for testing - automatically set operator
    function _requireBaoDeployerOperator() internal virtual override {
        address baoDeployer = DeploymentInfrastructure.predictBaoDeployerAddress();
        require(baoDeployer.code.length > 0, "BaoDeployer not deployed");

        // In tests, automatically set this contract as operator
        address currentOperator = BaoDeployer(baoDeployer).operator();
        if (currentOperator != address(this)) {
            // Use vm.prank to set operator as the owner (BAOMULTISIG)
            VM.prank(DeploymentInfrastructure.BAOMULTISIG);
            BaoDeployer(baoDeployer).setOperator(address(this));
        }
    }
}
