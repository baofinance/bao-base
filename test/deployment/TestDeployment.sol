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
 */
contract TestDeployment is Deployment {
    constructor() Deployment("test-salt") {}

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
     * @return The address that was registered
     */
    function useExistingByString(string memory key, address addr) public returns (address) {
        return useExisting(key, addr);
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
    ) public returns (address) {
        return _registerContractEntry(key, addr, contractType, contractPath, category);
    }

    /**
     * @notice Public wrapper for internal _registerImplementationEntry helper
     */
    function registerImplementation(
        string memory key,
        address addr,
        string memory contractType,
        string memory contractPath
    ) public returns (address) {
        return _registerImplementationEntry(key, addr, contractType, contractPath);
    }

    /**
     * @notice Public wrapper for internal _registerLibraryEntry helper
     */
    function registerLibrary(
        string memory key,
        address addr,
        string memory contractType,
        string memory contractPath
    ) public returns (address) {
        return _registerLibraryEntry(key, addr, contractType, contractPath);
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
     * @return Address of deployed library
     */
    function deployLibrary(string memory key, bytes memory bytecode) public returns (address) {
        return _deployLibrary(key, bytecode, "Library", "");
    }

    /**
     * @notice Public wrapper with salt parameter for backward compatibility
     * @dev The salt parameter is ignored - libraries always use CREATE
     * @param key String key to register
     * @param bytecode Contract bytecode to deploy
     * @return Address of deployed library
     */
    function deployLibrary(string memory key, bytes memory bytecode, string memory) public returns (address) {
        return _deployLibrary(key, bytecode, "Library", "");
    }

    /**
     * @notice Public wrapper exposing full metadata options for library deployment
     */
    function deployLibrary(
        string memory key,
        bytes memory bytecode,
        string memory contractType,
        string memory contractPath
    ) public returns (address) {
        return _deployLibrary(key, bytecode, contractType, contractPath);
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
     * @return The address that was registered
     */
    function registerExisting(string memory key, address addr) public returns (address) {
        return useExisting(key, addr);
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

    // ============================================================================
    // Ownership Management Wrappers
    // ============================================================================

    /**
     * @notice Public wrapper for finalizeOwnership() method
     * @param newOwner Address that should receive ownership of all proxies
     * @return transferred Number of proxies that had ownership transferred
     */
    function finalizeAllOwnership(address newOwner) public returns (uint256 transferred) {
        return finalizeOwnership(newOwner);
    }
}
