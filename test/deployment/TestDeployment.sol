// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Deployment} from "@bao-script/deployment/Deployment.sol";

/**
 * @title TestDeployment
 * @notice Test harness that exposes internal Deployment methods for testing
 * @dev This class provides public wrappers for internal string-based methods.
 *      Production code uses the type-safe enum API, but tests need string-based access.
 *      Can be used directly or extended for specialized test needs.
 *      Includes DeploymentJson mixin for Foundry-specific JSON operations.
 * @dev Defaults to address(this) as DEPLOYER_CONTEXT for test simplicity
 */
contract TestDeployment is Deployment {
    /// @notice Constructor for test environment
    /// @dev Passes address(0) to Deployment constructor, which defaults to address(this)
    constructor() Deployment(address(0)) {}

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

    // ============================================================================
    // Test-only Resume Methods (bypass auto-derived paths)
    // ============================================================================

    /// @notice Resume from custom filepath (test only)
    function resumeFrom(string memory filepath) public {
        _resumeFrom(filepath);
    }

    /// @notice Resume from JSON string (test only)
    function resumeFromJson(string memory json) public {
        _resumeFromJson(json);
    }

    // ============================================================================
    // Contract Access Wrappers
    // ============================================================================

    /**
     * @notice Public wrapper for internal _get() method
     * @param key String key to look up
     * @return Address of the deployed contract
     */
    function getByString(string memory key) public view returns (address) {
        return _get(key);
    }

    /**
     * @notice Public wrapper for internal _has() method
     * @param key String key to check
     * @return True if contract exists
     */
    function hasByString(string memory key) public view returns (bool) {
        return _has(key);
    }

    /**
     * @notice Public wrapper for internal useExisting() method
     * @param key String key to register
     * @param addr Address of existing contract
     */
    function useExistingByString(string memory key, address addr) public {
        useExisting(key, addr);
    }

    /**
     * @notice Public wrapper for internal _registerContractEntry helper
     */
    function registerContract(
        string memory key,
        address addr,
        string memory contractType,
        string memory contractPath,
        string memory category
    ) public {
        return _registerContract(key, addr, contractType, contractPath, category);
    }

    /**
     * @notice Public wrapper for internal _registerImplementationEntry helper
     */
    function registerImplementation(
        string memory key,
        address addr,
        string memory contractType,
        string memory contractPath
    ) public {
        _registerImplementationEntry(key, addr, contractType, contractPath);
    }

    /**
     * @notice Public wrapper for internal _registerLibraryEntry helper
     */
    function registerLibrary(
        string memory key,
        address addr,
        string memory contractType,
        string memory contractPath
    ) public {
        _registerLibraryEntry(key, addr, contractType, contractPath);
    }

    // ============================================================================
    // Parameter Access Wrappers
    // ============================================================================

    /**
     * @notice Public wrapper for internal _getString() method
     * @param key String key to look up
     * @return The string value
     */
    function getStringByKey(string memory key) public view returns (string memory) {
        return _getString(key);
    }

    /**
     * @notice Public wrapper for internal _getUint() method
     * @param key String key to look up
     * @return The uint256 value
     */
    function getUintByKey(string memory key) public view returns (uint256) {
        return _getUint(key);
    }

    /**
     * @notice Public wrapper for internal _getInt() method
     * @param key String key to look up
     * @return The int256 value
     */
    function getIntByKey(string memory key) public view returns (int256) {
        return _getInt(key);
    }

    /**
     * @notice Public wrapper for internal _getBool() method
     * @param key String key to look up
     * @return The bool value
     */
    function getBoolByKey(string memory key) public view returns (bool) {
        return _getBool(key);
    }

    /**
     * @notice Public wrapper for internal _setString() method
     * @param key String key to set
     * @param value The string value
     */
    function setStringByKey(string memory key, string memory value) public {
        _setString(key, value);
    }

    /**
     * @notice Public wrapper for internal _setUint() method
     * @param key String key to set
     * @param value The uint256 value
     */
    function setUintByKey(string memory key, uint256 value) public {
        _setUint(key, value);
    }

    /**
     * @notice Public wrapper for internal _setInt() method
     * @param key String key to set
     * @param value The int256 value
     */
    function setIntByKey(string memory key, int256 value) public {
        _setInt(key, value);
    }

    /**
     * @notice Public wrapper for internal _setBool() method
     * @param key String key to set
     * @param value The bool value
     */
    function setBoolByKey(string memory key, bool value) public {
        _setBool(key, value);
    }

    // ============================================================================
    // Library Deployment Wrappers
    // ============================================================================

    /**
     * @notice Public wrapper for deployLibrary with simplified parameters
     * @param key String key to register
     * @param bytecode Contract bytecode to deploy
     */
    function deployLibrary(string memory key, bytes memory bytecode) public {
        _deployLibrary(key, bytecode, "Library", "");
    }

    /**
     * @notice Public wrapper with salt parameter for backward compatibility
     * @dev The salt parameter is ignored - libraries always use CREATE
     * @param key String key to register
     * @param bytecode Contract bytecode to deploy
     */
    function deployLibrary(string memory key, bytes memory bytecode, string memory) public {
        _deployLibrary(key, bytecode, "Library", "");
    }

    /**
     * @notice Public wrapper exposing full metadata options for library deployment
     */
    function deployLibrary(
        string memory key,
        bytes memory bytecode,
        string memory contractType,
        string memory contractPath
    ) public {
        _deployLibrary(key, bytecode, contractType, contractPath);
    }

    // ============================================================================
    // Compatibility Helpers
    // ============================================================================

    /**
     * @notice Alias for getByString for backward compatibility
     * @param key String key to look up
     * @return Address of the deployed contract
     */
    function getContract(string memory key) public view returns (address) {
        return _get(key);
    }

    /**
     * @notice Alias for useExistingByString for backward compatibility
     * @param key String key to register
     * @param addr Address of existing contract
     */
    function registerExisting(string memory key, address addr) public {
        useExisting(key, addr);
    }

    /**
     * @notice Simple entry struct for test compatibility
     */
    struct DeploymentEntry {
        address addr;
        string category;
    }

    /**
     * @notice Get entry information for backward compatibility
     * @param key String key to look up
     * @return Entry with address and category
     */
    function getEntry(string memory key) public view returns (DeploymentEntry memory) {
        string memory entryType = getEntryType(key);
        address addr = _get(key);

        DeploymentEntry memory entry;
        entry.addr = addr;

        if (_strEqual(entryType, "library")) {
            entry.category = "library";
        } else if (_strEqual(entryType, "contract")) {
            entry.category = "existing";
        }

        return entry;
    }

    /**
     * @notice Helper for string comparison
     */
    function _strEqual(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
