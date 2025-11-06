// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeploymentRegistry} from "@bao-script/deployment/DeploymentRegistry.sol";
import {DeploymentRegistryJson} from "@bao-script/deployment/DeploymentRegistryJson.sol";
import {DeploymentFoundry} from "@bao-script/deployment/DeploymentFoundry.sol";
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
contract MockDeployment is DeploymentFoundry {
    /// @notice Flag to control registry saves in tests
    bool private _registrySavesEnabled;

    /// @notice Constructor for test deployment harness
    /// @dev Registry saves disabled by default in tests to avoid polluting results directory
    /// @dev Does NOT deploy infrastructure - that's handled by BaoDeploymentTest.setUp()
    constructor() {
        _registrySavesEnabled = false;
    }

    function _ensureBaoDeployerOperator() internal override {
        address baoDeployer = DeploymentInfrastructure.predictBaoDeployerAddress();

        if (baoDeployer.code.length > 0 && BaoDeployer(baoDeployer).operator() != address(this)) {
            VM.startPrank(DeploymentInfrastructure.BAOMULTISIG);
            BaoDeployer(baoDeployer).setOperator(address(this));
            VM.stopPrank();
        }

        super._ensureBaoDeployerOperator();
    }

    /*//////////////////////////////////////////////////////////////////////////
                        INFRASTRUCTURE DEPLOYMENT HELPERS
                        (Test-only exposure of production logic)
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Assign BaoDeployer operator by impersonating the owner (test helper)
    /// @param owner Address with ownership privileges (e.g., Bao multisig)
    /// @param operator Contract that should act as operator
    function assignBaoDeployerOperator(address owner, address operator) public {
        address deployed = DeploymentInfrastructure.predictBaoDeployerAddress();
        if (deployed == address(0)) {
            revert FactoryDeploymentFailed("BaoDeployer owner not configured");
        }

        VM.startPrank(owner);
        BaoDeployer(deployed).setOperator(operator);
        VM.stopPrank();
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

    /// @notice Override to add results/ prefix for test outputs
    /// @return "results/" prefix for test deployment files
    function _getBaseDirPrefix() internal pure override returns (string memory) {
        return "results/";
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

    function fromJsonFile(string memory filepath) public {
        _fromJsonFile(filepath);
    }

    function toJsonFile(string memory filepath) public {
        _toJsonFile(filepath);
    }

    function fromJson(string memory json) public virtual {
        return _fromJson(json);
    }

    function toJson() public virtual returns (string memory) {
        return _toJson();
    }

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

    /// @notice Remove .json extension from filepath
    /// @dev Used by snapshot harnesses to insert operation/phase numbers before extension
    function _removeJsonExtension(string memory path) internal pure returns (string memory) {
        bytes memory pathBytes = bytes(path);
        require(pathBytes.length > 5, "Path too short");

        // Check if ends with .json
        if (
            pathBytes[pathBytes.length - 5] == "." &&
            pathBytes[pathBytes.length - 4] == "j" &&
            pathBytes[pathBytes.length - 3] == "s" &&
            pathBytes[pathBytes.length - 2] == "o" &&
            pathBytes[pathBytes.length - 1] == "n"
        ) {
            bytes memory result = new bytes(pathBytes.length - 5);
            for (uint256 i = 0; i < pathBytes.length - 5; i++) {
                result[i] = pathBytes[i];
            }
            return string(result);
        }
        return path;
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
    // Test-only Resume Methods (bypass auto-derived paths)
    // ============================================================================

    /// @notice Resume from custom filepath (test only)
    function resumeFrom(string memory filepath) public {
        _resumeFrom(filepath);
    }

    /// @notice Resume from JSON string (test only)
    function resumeFromJson(string memory json) public {
        _fromJson(json);
        _ensureBaoDeployerOperator();
        _stub = new UUPSProxyDeployStub();
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

    // /**
    //  * @notice Deploy a contract via CREATE3 with ETH value to payable constructor
    //  * @dev Uses BaoDeployer's value-enabled deployDeterministic
    //  * @param key String key to register the contract
    //  * @param value Amount of ETH (in wei) to send to constructor (requires payable constructor)
    //  * @param creationCode Contract creation bytecode
    //  * @param contractType Contract type for metadata (e.g., "FundedVault")
    //  * @param contractPath Source path for metadata
    //  * @return deployed Address of the deployed contract
    //  */
    // function deployContractWithValue(
    //     string memory key,
    //     uint256 value,
    //     bytes memory creationCode,
    //     string memory contractType,
    //     string memory contractPath
    // ) public payable returns (address deployed) {
    //     _requireActiveRun();
    //     if (bytes(key).length == 0) {
    //         revert KeyRequired();
    //     }
    //     if (_exists[key]) {
    //         revert ContractAlreadyExists(key);
    //     }

    //     // Compute salt
    //     bytes memory saltBytes = abi.encodePacked(_metadata.systemSaltString, "/", key, "/contract");
    //     bytes32 salt = keccak256(saltBytes);

    //     address baoDeployerAddr = _predictBaoDeployerAddress();
    //     BaoDeployer baoDeployer = BaoDeployer(baoDeployerAddr);
    //     bytes32 initCodeHash = keccak256(creationCode);
    //     bytes32 commitment = DeploymentInfrastructure.commitment(address(this), value, salt, initCodeHash);

    //     baoDeployer.commit(commitment);
    //     deployed = baoDeployer.reveal{value: value}(creationCode, salt, value);

    //     // Register the contract
    //     registerContract(key, deployed, contractType, contractPath, "contract");

    //     emit ContractDeployed(key, deployed, contractType);
    // }

    /**
     * @notice Helper for string comparison
     */
    function _strEqual(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
