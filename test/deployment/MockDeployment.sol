// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeploymentRegistry} from "@bao-script/deployment/DeploymentRegistry.sol";
import {DeploymentRegistryJson} from "@bao-script/deployment/DeploymentRegistryJson.sol";
import {DeploymentFoundryTest} from "@bao-script/deployment/DeploymentFoundry.sol";
import {BaoDeployer} from "@bao-script/deployment/BaoDeployer.sol";
import {UUPSProxyDeployStub} from "@bao-script/deployment/UUPSProxyDeployStub.sol";
import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";

import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";

/**
 * @title MockDeployment
 * @notice Mock deployment harness for testing
 * @dev Exposes internal Deployment methods with public wrappers for test access
 * @dev Infrastructure (Nick's Factory, BaoDeployer) setup helpers exposed for tests
 * @dev Production code uses type-safe enum API; tests use these string-based wrappers
 * @dev Automatically configures the BaoDeployer operator when available
 * @dev Overrides to use results/deployments flat structure (no network subdirs)
 */
contract MockDeployment is DeploymentFoundryTest {
    /// @notice Flag to control registry saves in tests
    bool private _registrySavesEnabled;

    /// @notice Constructor for test deployment harness
    /// @dev Registry saves disabled by default in tests to avoid polluting results directory
    /// @dev Does NOT deploy infrastructure - that's handled by BaoDeploymentTest.setUp()
    constructor() {
        _registrySavesEnabled = false;
    }

    /*//////////////////////////////////////////////////////////////////////////
                            REGISTRY CONTROL
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Enable registry saves for tests that want to generate regression files
    function enableAutoSave() public {
        _registrySavesEnabled = true;
    }

    /// @notice Disable registry saves (default behavior)
    function disableAutoSave() public {
        _registrySavesEnabled = false;
    }

    /// @notice Override to use flat structure (no network subdirectories)
    /// @return false to disable network subdirectories in tests
    function _useNetworkSubdir() internal pure override returns (bool) {
        return false;
    }

    /// @notice Override to disable registry saves by default in tests
    /// @dev Tests that want regression files should call enableAutoSave() or use explicit toJsonFile()
    function _saveRegistry() internal virtual override(DeploymentRegistry, DeploymentRegistryJson) {
        if (_registrySavesEnabled) {
            super._saveRegistry();
        }
    }

    function filepath() public view returns (string memory) {
        return _filepath();
    }

    function forceLoadRegistry(string memory fileName) public {
        _loadRegistry("", fileName);
    }

    function forceSaveRegistry() public {
        super._saveRegistry();
    }

    function toJsonString() public virtual returns (string memory) {
        return _toJson();
    }

    function fromJsonString(string memory json) public {
        _fromJson(json);
    }

    function resumeAfterLoad() public {
        _resumeAfterLoad();
    }

    // ============================================================================
    // Test-only Resume Methods (bypass auto-derived paths)
    // ============================================================================

    // /// @notice Resume from custom filepath (test only)
    // function resumeFrom(string memory fileName) public {
    //     _fromJsonFile(fileName);
    // }

    // /// @notice Resume from JSON string (test only)
    // function resumeFromJson(string memory json) public {
    //     _fromJson(json);
    //     _ensureBaoDeployerOperator();
    //     _stub = new UUPSProxyDeployStub();
    // }

    /// @notice Count how many proxies are still owned by this harness (for testing)
    /// @dev Useful for verifying ownership transfer behavior in tests
    function countTransferrableProxies(address /* newOwner */) public view returns (uint256) {
        // This is for testing - just check if any proxies still owned by this harness
        uint256 stillOwned = 0;
        string[] memory allKeys = _keys;

        for (uint256 i; i < allKeys.length; i++) {
            string memory key = allKeys[i];

            if (_eq(_entryType[key], "proxy")) {
                address proxy = _proxies[key].info.addr;
                (bool success, bytes memory data) = proxy.staticcall(abi.encodeWithSignature("owner()"));
                if (success && data.length == 32) {
                    address currentOwner = abi.decode(data, (address));
                    if (currentOwner == address(this)) {
                        ++stillOwned;
                    }
                }
            }
        }

        return stillOwned;
    }

    /// @notice Convert uint to string
    /// @dev Used by snapshot harnesses to create numbered snapshot filenames
    function _uintToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";

        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }

        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }

        return string(buffer);
    }

    // ============================================================================
    // Contract Access Wrappers
    // ============================================================================

    /**
     * @notice Public wrapper for contract registration
     */
    function registerContract(
        string memory key,
        address addr,
        string memory contractType,
        string memory contractPath,
        string memory category
    ) public {
        return
            _registerStandardContract(
                key,
                addr,
                contractType,
                contractPath,
                category,
                address(0),
                _runs[_runs.length - 1].deployer
            );
    }

    function simulatePredictableDeployWithoutFunding(
        uint256 value,
        string memory key,
        bytes memory initCode,
        string memory /* contractType */,
        string memory /* contractPath */
    ) external virtual returns (address addr) {
        _requireActiveRun();
        if (bytes(key).length == 0) {
            revert KeyRequired();
        }
        if (_exists[key]) {
            revert ContractAlreadyExists(key);
        }

        bytes32 salt = EfficientHashLib.hash(abi.encodePacked(_metadata.systemSaltString, "/", key, "/contract"));
        address baoDeployerAddr = DeploymentInfrastructure.predictBaoDeployerAddress();
        BaoDeployer baoDeployer = BaoDeployer(baoDeployerAddr);
        bytes32 commitment = DeploymentInfrastructure.commitment(address(this), value, salt, keccak256(initCode));
        baoDeployer.commit(commitment);

        addr = baoDeployer.reveal{value: 0}(initCode, salt, value);
    }

    /**
     * @notice Helper for string comparison
     */
    function _strEqual(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @notice Compute the derived implementation key for assertions in tests
    function implementationKey(
        string memory proxyKey,
        string memory contractType
    ) public pure returns (string memory) {
        return _deriveImplementationKey(proxyKey, contractType);
    }
}
