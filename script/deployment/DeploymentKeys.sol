// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LibString} from "@solady/utils/LibString.sol";

/**
 * @title DataType
 * @notice Enum for deployment data types
 * @dev Maps to JSON types with uint/int distinction for validation
 *      OBJECT: Parent node marker (no value, establishes hierarchy for child keys)
 *      ADDRESS: Nested addresses (keys contain dots, e.g., "pegged.implementation")
 *      STRING: String values (keys contain dots, e.g., "token.symbol")
 *      UINT: Unsigned integer values (keys contain dots, e.g., "token.decimals")
 *      INT: Signed integer values (keys contain dots, e.g., "config.temperature")
 *      BOOL: Boolean values (keys contain dots, e.g., "config.enabled")
 *      ADDRESS_ARRAY: Array of addresses (keys contain dots, e.g., "config.validators")
 *      STRING_ARRAY: Array of strings (keys contain dots, e.g., "config.tags")
 *      UINT_ARRAY: Array of unsigned integers (keys contain dots, e.g., "config.limits")
 *      INT_ARRAY: Array of signed integers (keys contain dots, e.g., "config.deltas")
 */
enum DataType {
    OBJECT,
    ADDRESS,
    STRING,
    UINT,
    INT,
    BOOL,
    ADDRESS_ARRAY,
    STRING_ARRAY,
    UINT_ARRAY,
    INT_ARRAY
}

/**
 * @title KeyPattern
 * @notice Represents a single-level wildcard pattern: prefix.*.suffix
 * @dev Used to match keys like "networks.mainnet.chainId" with pattern "networks.*.chainId"
 */
struct KeyPattern {
    string prefix; // e.g., "networks"
    string suffix; // e.g., "chainId"
    DataType dtype; // The data type for matched keys
    uint256 decimals; // Decimal places for numeric types (DECIMALS_AUTO for auto)
}

/**
 * @title DeploymentKeys
 * @notice Abstract contract for registering and validating deployment configuration keys
 * @dev Projects extend this to define their configuration keys with type safety.
 *      Supports single-level wildcard patterns (prefix.*.suffix) for dynamic keys.
 */
abstract contract DeploymentKeys {
    using LibString for string;

    // ============ Storage ============

    // TODO: look at making all this data private and provide access functions if needed
    /// @dev Mapping from key name to expected type
    mapping(string => DataType) private _keyTypes;

    /// @dev Mapping to track if key is registered
    mapping(string => bool) private _keyRegistered;

    /// @dev Mapping from key name to decimals for numeric formatting
    /// type(uint256).max means "auto" (printf %g style), other values are fixed scale
    mapping(string => uint256) internal _keyDecimals;

    /// @dev Array of all registered keys
    string[] private _schemaKeys;

    /// @dev Array of registered patterns for single-level wildcards
    KeyPattern[] internal _patterns;

    /// @dev Sentinel value meaning "use auto-scaling" for numeric formatting
    uint256 internal constant DECIMALS_AUTO = type(uint256).max;

    // ============ Errors ============

    error InvalidKeyFormat(string key, string reason);
    error TypeMismatch(string key, DataType expectedType, DataType actualType);
    error KeyNotRegistered(string key);
    error KeyAlreadyRegistered(string key);
    error ParentContractNotRegistered(string key, string parentKey);
    error ContractKeyMustStartWithContracts(string key);

    // ============ Constructor ============

    // Global metadata
    string internal constant SCHEMA_VERSION = "schemaVersion";
    string public constant OWNER = "owner";
    string public constant SYSTEM_SALT_STRING = "systemSaltString";
    string public constant BAO_FACTORY = "BaoFactory";

    // Session metadata
    string public constant SESSION = "session";
    string public constant SESSION_VERSION = "session.version";
    string public constant SESSION_DEPLOYER = "session.deployer";
    string public constant SESSION_STUB = "session.stub";
    string public constant SESSION_STUB_ADDRESS = "session.stub.address";
    string public constant SESSION_STUB_CONTRACT_TYPE = "session.stub.contractType";
    string public constant SESSION_STUB_CONTRACT_PATH = "session.stub.contractPath";
    string public constant SESSION_STUB_BLOCK_NUMBER = "session.stub.blockNumber";
    string public constant SESSION_STARTED = "session.started";
    string public constant SESSION_FINISHED = "session.finished";
    string public constant SESSION_START_TIMESTAMP = "session.startTimestamp";
    string public constant SESSION_FINISH_TIMESTAMP = "session.finishTimestamp";
    string public constant SESSION_START_BLOCK = "session.startBlock";
    string public constant SESSION_FINISH_BLOCK = "session.finishBlock";
    string public constant SESSION_NETWORK = "session.network";
    string public constant SESSION_CHAIN_ID = "session.chainId";

    /**
     * @notice Initialize deployment keys with metadata keys
     * @dev Use high-level registration methods (addProxy, addContract) to register contract keys
     */
    constructor() {
        // Top-level metadata
        _registerKey(SCHEMA_VERSION, DataType.UINT);
        _registerKey(OWNER, DataType.ADDRESS);
        _registerKey(BAO_FACTORY, DataType.ADDRESS);
        _registerKey(SYSTEM_SALT_STRING, DataType.STRING);

        // Session metadata namespace
        _registerKey(SESSION, DataType.OBJECT);
        _registerKey(SESSION_VERSION, DataType.STRING);
        _registerKey(SESSION_DEPLOYER, DataType.ADDRESS);

        // stub info TODO: this should be a contract
        _registerKey(SESSION_STUB, DataType.OBJECT);
        _registerKey(SESSION_STUB_ADDRESS, DataType.ADDRESS);
        _registerKey(SESSION_STUB_CONTRACT_TYPE, DataType.STRING);
        _registerKey(SESSION_STUB_CONTRACT_PATH, DataType.STRING);
        _registerKey(SESSION_STUB_BLOCK_NUMBER, DataType.UINT);

        // stamps
        _registerKey(SESSION_STARTED, DataType.STRING);
        _registerKey(SESSION_FINISHED, DataType.STRING);
        _registerKey(SESSION_START_TIMESTAMP, DataType.UINT);
        _registerKey(SESSION_FINISH_TIMESTAMP, DataType.UINT);
        _registerKey(SESSION_START_BLOCK, DataType.UINT);
        _registerKey(SESSION_FINISH_BLOCK, DataType.UINT);
        _registerKey(SESSION_NETWORK, DataType.STRING);
        _registerKey(SESSION_CHAIN_ID, DataType.UINT);

        // Contracts namespace root
        _registerKey("contracts", DataType.OBJECT);
    }

    // ============ Key Registration ============

    /**
     * @notice Register a contract address key (top-level, no dots)
     * @dev Called in derived contract constructors to register OBJECT type keys
     *      This creates a top-level namespace that nested keys can attach to
     * @param key The key name (e.g., "owner", "pegged") - must NOT contain dots
     * @return key Returns the key for use in constant declarations
     */
    function addKey(string memory key) internal returns (string memory) {
        _validateKeyFormat(key);
        _registerKey(key, DataType.OBJECT);
        return key;
    }

    /**
     * @notice Register an address key
     * @dev For addresses in hierarchical configs like "pegged.implementation"
     *      If nested (contains dots), requires parent CONTRACT key to be registered first
     * @param key The key name (e.g., "treasury" or "pegged.implementation")
     * @return key Returns the key for use in constant declarations
     */
    function addAddressKey(string memory key) internal returns (string memory) {
        _validateDataKey(key, DataType.ADDRESS);
        return key;
    }

    /**
     * @notice Register a string key
     * @dev If nested (contains dots), requires parent CONTRACT key to be registered first
     * @param key The key name (e.g., "pegged.symbol")
     * @return key Returns the key for use in constant declarations
     */
    function addStringKey(string memory key) internal returns (string memory) {
        _validateDataKey(key, DataType.STRING);
        return key;
    }

    /**
     * @notice Register a uint key with auto-scaling
     * @dev If nested (contains dots), requires parent CONTRACT key to be registered first
     * @param key The key name (e.g., "pegged.decimals")
     * @return key Returns the key for use in constant declarations
     */
    function addUintKey(string memory key) internal returns (string memory) {
        return addUintKey(key, DECIMALS_AUTO);
    }

    /**
     * @notice Register a uint key with fixed decimal scaling
     * @dev If nested (contains dots), requires parent CONTRACT key to be registered first
     * @param key The key name (e.g., "pegged.totalSupply")
     * @param decimals The decimal places for formatting (e.g., 18 for token amounts)
     * @return key Returns the key for use in constant declarations
     */
    function addUintKey(string memory key, uint256 decimals) internal returns (string memory) {
        _validateDataKey(key, DataType.UINT);
        _keyDecimals[key] = decimals;
        return key;
    }

    /**
     * @notice Register an int key with auto-scaling
     * @dev If nested (contains dots), requires parent CONTRACT key to be registered first
     * @param key The key name (e.g., "pegged.offset")
     * @return key Returns the key for use in constant declarations
     */
    function addIntKey(string memory key) internal returns (string memory) {
        return addIntKey(key, DECIMALS_AUTO);
    }

    /**
     * @notice Register an int key with fixed decimal scaling
     * @dev If nested (contains dots), requires parent CONTRACT key to be registered first
     * @param key The key name (e.g., "config.delta")
     * @param decimals The decimal places for formatting (e.g., 18 for token amounts)
     * @return key Returns the key for use in constant declarations
     */
    function addIntKey(string memory key, uint256 decimals) internal returns (string memory) {
        _validateDataKey(key, DataType.INT);
        _keyDecimals[key] = decimals;
        return key;
    }

    /**
     * @notice Register a bool key
     * @dev If nested (contains dots), requires parent CONTRACT key to be registered first
     * @param key The key name (e.g., "pegged.enabled")
     * @return key Returns the key for use in constant declarations
     */
    function addBoolKey(string memory key) internal returns (string memory) {
        _validateDataKey(key, DataType.BOOL);
        return key;
    }

    /**
     * @notice Register an address array key
     * @dev If nested (contains dots), requires parent CONTRACT key to be registered first
     * @param key The key name (e.g., "token.validators")
     * @return key Returns the key for use in constant declarations
     */
    function addAddressArrayKey(string memory key) internal returns (string memory) {
        _validateDataKey(key, DataType.ADDRESS_ARRAY);
        return key;
    }

    /**
     * @notice Register a string array key
     * @dev If nested (contains dots), requires parent CONTRACT key to be registered first
     * @param key The key name (e.g., "token.tags")
     * @return key Returns the key for use in constant declarations
     */
    function addStringArrayKey(string memory key) internal returns (string memory) {
        _validateDataKey(key, DataType.STRING_ARRAY);
        return key;
    }

    /**
     * @notice Register a uint array key with auto-scaling
     * @dev If nested (contains dots), requires parent CONTRACT key to be registered first
     * @param key The key name (e.g., "token.limits")
     * @return key Returns the key for use in constant declarations
     */
    function addUintArrayKey(string memory key) internal returns (string memory) {
        return addUintArrayKey(key, DECIMALS_AUTO);
    }

    /**
     * @notice Register a uint array key with fixed decimal scaling
     * @dev If nested (contains dots), requires parent CONTRACT key to be registered first
     * @param key The key name (e.g., "token.amounts")
     * @param decimals The decimal places for formatting (e.g., 18 for token amounts)
     * @return key Returns the key for use in constant declarations
     */
    function addUintArrayKey(string memory key, uint256 decimals) internal returns (string memory) {
        _validateDataKey(key, DataType.UINT_ARRAY);
        _keyDecimals[key] = decimals;
        return key;
    }

    /**
     * @notice Register an int array key with auto-scaling
     * @dev If nested (contains dots), requires parent CONTRACT key to be registered first
     * @param key The key name (e.g., "token.deltas")
     * @return key Returns the key for use in constant declarations
     */
    function addIntArrayKey(string memory key) internal returns (string memory) {
        return addIntArrayKey(key, DECIMALS_AUTO);
    }

    /**
     * @notice Register an int array key with fixed decimal scaling
     * @dev If nested (contains dots), requires parent CONTRACT key to be registered first
     * @param key The key name (e.g., "config.offsets")
     * @param decimals The decimal places for formatting (e.g., 18 for token amounts)
     * @return key Returns the key for use in constant declarations
     */
    function addIntArrayKey(string memory key, uint256 decimals) internal returns (string memory) {
        _validateDataKey(key, DataType.INT_ARRAY);
        _keyDecimals[key] = decimals;
        return key;
    }

    // ============ Pattern Registration (Single-Level Wildcards) ============

    /**
     * @notice Register a pattern for object keys: prefix.*.suffix
     * @dev When JSON is loaded, all keys matching this pattern are auto-registered
     * @param prefix The prefix before the wildcard (e.g., "networks")
     * @param suffix The suffix after the wildcard (e.g., "config")
     */
    function addAnyKeySuffix(string memory prefix, string memory suffix) internal {
        _addPattern(prefix, suffix, DataType.OBJECT, DECIMALS_AUTO);
    }

    /**
     * @notice Register a pattern for uint keys: prefix.*.suffix
     * @param prefix The prefix before the wildcard
     * @param suffix The suffix after the wildcard
     */
    function addAnyUintKeySuffix(string memory prefix, string memory suffix) internal {
        addAnyUintKeySuffix(prefix, suffix, DECIMALS_AUTO);
    }

    /**
     * @notice Register a pattern for uint keys with decimals: prefix.*.suffix
     * @param prefix The prefix before the wildcard
     * @param suffix The suffix after the wildcard
     * @param decimals The decimal places for formatting
     */
    function addAnyUintKeySuffix(string memory prefix, string memory suffix, uint256 decimals) internal {
        _addPattern(prefix, suffix, DataType.UINT, decimals);
    }

    /**
     * @notice Register a pattern for int keys: prefix.*.suffix
     * @param prefix The prefix before the wildcard
     * @param suffix The suffix after the wildcard
     */
    function addAnyIntKeySuffix(string memory prefix, string memory suffix) internal {
        addAnyIntKeySuffix(prefix, suffix, DECIMALS_AUTO);
    }

    /**
     * @notice Register a pattern for int keys with decimals: prefix.*.suffix
     * @param prefix The prefix before the wildcard
     * @param suffix The suffix after the wildcard
     * @param decimals The decimal places for formatting
     */
    function addAnyIntKeySuffix(string memory prefix, string memory suffix, uint256 decimals) internal {
        _addPattern(prefix, suffix, DataType.INT, decimals);
    }

    /**
     * @notice Register a pattern for address keys: prefix.*.suffix
     * @param prefix The prefix before the wildcard
     * @param suffix The suffix after the wildcard
     */
    function addAnyAddressKeySuffix(string memory prefix, string memory suffix) internal {
        _addPattern(prefix, suffix, DataType.ADDRESS, DECIMALS_AUTO);
    }

    /**
     * @notice Register a pattern for string keys: prefix.*.suffix
     * @param prefix The prefix before the wildcard
     * @param suffix The suffix after the wildcard
     */
    function addAnyStringKeySuffix(string memory prefix, string memory suffix) internal {
        _addPattern(prefix, suffix, DataType.STRING, DECIMALS_AUTO);
    }

    /**
     * @notice Register a pattern for bool keys: prefix.*.suffix
     * @param prefix The prefix before the wildcard
     * @param suffix The suffix after the wildcard
     */
    function addAnyBoolKeySuffix(string memory prefix, string memory suffix) internal {
        _addPattern(prefix, suffix, DataType.BOOL, DECIMALS_AUTO);
    }

    /**
     * @notice Register a pattern for address array keys: prefix.*.suffix
     * @param prefix The prefix before the wildcard
     * @param suffix The suffix after the wildcard
     */
    function addAnyAddressArrayKeySuffix(string memory prefix, string memory suffix) internal {
        _addPattern(prefix, suffix, DataType.ADDRESS_ARRAY, DECIMALS_AUTO);
    }

    /**
     * @notice Register a pattern for string array keys: prefix.*.suffix
     * @param prefix The prefix before the wildcard
     * @param suffix The suffix after the wildcard
     */
    function addAnyStringArrayKeySuffix(string memory prefix, string memory suffix) internal {
        _addPattern(prefix, suffix, DataType.STRING_ARRAY, DECIMALS_AUTO);
    }

    /**
     * @notice Register a pattern for uint array keys: prefix.*.suffix
     * @param prefix The prefix before the wildcard
     * @param suffix The suffix after the wildcard
     */
    function addAnyUintArrayKeySuffix(string memory prefix, string memory suffix) internal {
        addAnyUintArrayKeySuffix(prefix, suffix, DECIMALS_AUTO);
    }

    /**
     * @notice Register a pattern for uint array keys with decimals: prefix.*.suffix
     * @param prefix The prefix before the wildcard
     * @param suffix The suffix after the wildcard
     * @param decimals The decimal places for formatting
     */
    function addAnyUintArrayKeySuffix(string memory prefix, string memory suffix, uint256 decimals) internal {
        _addPattern(prefix, suffix, DataType.UINT_ARRAY, decimals);
    }

    /**
     * @notice Register a pattern for int array keys: prefix.*.suffix
     * @param prefix The prefix before the wildcard
     * @param suffix The suffix after the wildcard
     */
    function addAnyIntArrayKeySuffix(string memory prefix, string memory suffix) internal {
        addAnyIntArrayKeySuffix(prefix, suffix, DECIMALS_AUTO);
    }

    /**
     * @notice Register a pattern for int array keys with decimals: prefix.*.suffix
     * @param prefix The prefix before the wildcard
     * @param suffix The suffix after the wildcard
     * @param decimals The decimal places for formatting
     */
    function addAnyIntArrayKeySuffix(string memory prefix, string memory suffix, uint256 decimals) internal {
        _addPattern(prefix, suffix, DataType.INT_ARRAY, decimals);
    }

    /**
     * @notice Check if a key is registered (either explicitly or would match a pattern)
     * @param key The key to check
     * @return True if the key is registered or matches a pattern
     */
    function isKeyRegisteredOrMatchesPattern(string memory key) public view returns (bool) {
        if (_keyRegistered[key]) return true;

        // Check if it matches any pattern
        for (uint256 i = 0; i < _patterns.length; i++) {
            if (_matchesPattern(key, _patterns[i])) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Register a concrete key that matches a pattern
     * @dev Called during JSON loading when a pattern match is found
     * @param key The concrete key to register (e.g., "networks.mainnet.chainId")
     * @param pattern The pattern it matches
     */
    function _registerKeyFromPattern(string memory key, KeyPattern memory pattern) internal {
        if (_keyRegistered[key]) return; // Already registered

        _keyTypes[key] = pattern.dtype;
        _keyRegistered[key] = true;
        _schemaKeys.push(key);
        if (pattern.decimals != DECIMALS_AUTO) {
            _keyDecimals[key] = pattern.decimals;
        }
    }

    /**
     * @notice Internal helper to add a pattern
     * @dev Validates prefix is registered as OBJECT
     */
    function _addPattern(string memory prefix, string memory suffix, DataType dtype, uint256 decimals) private {
        // Validate prefix is registered as OBJECT
        if (!_keyRegistered[prefix] || _keyTypes[prefix] != DataType.OBJECT) {
            revert ParentContractNotRegistered(string.concat(prefix, ".*.", suffix), prefix);
        }
        _patterns.push(KeyPattern({prefix: prefix, suffix: suffix, dtype: dtype, decimals: decimals}));
    }

    /**
     * @notice Check if a key matches a pattern
     * @param key The key to check (e.g., "networks.mainnet.chainId")
     * @param pattern The pattern to match against
     * @return True if the key matches the pattern
     */
    function _matchesPattern(string memory key, KeyPattern memory pattern) internal pure returns (bool) {
        // Key must start with prefix.
        string memory prefixWithDot = string.concat(pattern.prefix, ".");
        if (!LibString.startsWith(key, prefixWithDot)) {
            return false;
        }

        // Key must end with .suffix
        string memory dotSuffix = string.concat(".", pattern.suffix);
        if (!LibString.endsWith(key, dotSuffix)) {
            return false;
        }

        // The middle part (wildcard) must be a single segment (no dots)
        uint256 prefixLen = bytes(prefixWithDot).length;
        uint256 suffixLen = bytes(dotSuffix).length;
        uint256 keyLen = bytes(key).length;

        // Ensure there's something in the middle
        if (keyLen <= prefixLen + suffixLen) {
            return false;
        }

        // Extract middle part and check it has no dots
        bytes memory keyBytes = bytes(key);
        for (uint256 i = prefixLen; i < keyLen - suffixLen; i++) {
            if (keyBytes[i] == 0x2E) {
                // '.'
                return false; // Middle has a dot, not a single-level wildcard match
            }
        }

        return true;
    }

    /**
     * @notice Extract the wildcard segment from a key that matches a pattern
     * @param key The key (e.g., "networks.mainnet.chainId")
     * @param pattern The pattern it matches
     * @return The wildcard segment (e.g., "mainnet")
     */
    function _extractWildcard(string memory key, KeyPattern memory pattern) internal pure returns (string memory) {
        uint256 prefixLen = bytes(pattern.prefix).length + 1; // +1 for the dot after prefix
        uint256 suffixLen = bytes(pattern.suffix).length + 1; // +1 for the dot before suffix
        uint256 keyLen = bytes(key).length;

        // Extract: key[prefixLen : keyLen - suffixLen]
        return key.slice(prefixLen, keyLen - suffixLen);
    }

    /**
     * @notice Register all keys for a proxy contract
     * @dev Registers:
     *      - {key} (CONTRACT)
     *      - {key}.implementation (STRING)
     *      - {key}.address (ADDRESS)
     *      - {key}.category (STRING)
     * @param key The full contract key (e.g., "contracts.pegged")
     *
     * TODO: Future enhancement - make implementation an array to preserve upgrade history.
     * Each call to registerImplementation/upgradeProxy would append to the array instead of
     * overwriting. Current implementation = last element. This would provide full audit trail
     * of all implementation versions with their deployment metadata.
     */
    function addProxy(string memory key) public {
        _requireContractsPrefix(key);
        _addImplementation(key);
        _registerKey(string.concat(key, ".category"), DataType.STRING);
        _registerKey(string.concat(key, ".factory"), DataType.ADDRESS);
        _registerKey(string.concat(key, ".owner"), DataType.ADDRESS);
        _registerKey(string.concat(key, ".value"), DataType.UINT);
        _registerKey(string.concat(key, ".saltString"), DataType.STRING);
        _registerKey(string.concat(key, ".salt"), DataType.STRING); // Store as hex string

        string memory implementationKey = string.concat(key, ".implementation");
        _addImplementation(implementationKey);
        // ownershipModel is a property of the implementation, not the proxy
        _registerKey(string.concat(implementationKey, ".ownershipModel"), DataType.STRING);
    }

    /**
     * @notice Register explicit roles for a contract
     * @dev Registers specific role keys (no wildcards):
     *      - {key}.roles (OBJECT) - parent for all roles
     *      - {key}.roles.{roleName}.value (UINT) - for each role
     *      - {key}.roles.{roleName}.grantees (STRING_ARRAY) - for each role
     *
     *      Usage: addRoles("contracts.pegged", ["MINTER_ROLE", "BURNER_ROLE"])
     *
     * @param key The full contract key (e.g., "contracts.pegged")
     * @param roleNames Array of role names to register
     */
    function addRoles(string memory key, string[] memory roleNames) public {
        string memory rolesKey = string.concat(key, ".roles");
        _registerKey(rolesKey, DataType.OBJECT);
        for (uint256 i = 0; i < roleNames.length; i++) {
            string memory roleKey = string.concat(rolesKey, ".", roleNames[i]);
            _registerKey(roleKey, DataType.OBJECT);
            _registerKey(string.concat(roleKey, ".value"), DataType.UINT);
            _registerKey(string.concat(roleKey, ".grantees"), DataType.STRING_ARRAY);
        }
    }

    /**
     * @notice Register all keys for a standalone contract
     * @dev Registers:
     *      - {key} (CONTRACT)
     *      - {key}.address (ADDRESS)
     *      - {key}.type (STRING)
     *      - {key}.path (STRING)
     *      - {key}.category (STRING)
     * @param key The full contract key (e.g., "contracts.library")
     */
    function addContract(string memory key) public {
        _requireContractsPrefix(key);
        _addImplementation(key);
        _registerKey(string.concat(key, ".category"), DataType.STRING);
    }

    function addPredictableContract(string memory key) public {
        addContract(key); // addContract already validates prefix
        _registerKey(string.concat(key, ".value"), DataType.UINT);
    }

    /**
     * @notice Register all keys for an implementation contract
     * @dev Registers:
     *      - {proxyKey}__{contractType} (CONTRACT)
     *      - {proxyKey}__{contractType}.address (ADDRESS)
     *      - {proxyKey}__{contractType}.type (STRING)
     *      - {proxyKey}__{contractType}.path (STRING)
     * @param key The full proxy key (e.g., "contracts.pegged")
     */
    function _addImplementation(string memory key) private {
        _registerKey(key, DataType.OBJECT);
        _registerKey(string.concat(key, ".address"), DataType.ADDRESS);
        _registerKey(string.concat(key, ".contractType"), DataType.STRING);
        _registerKey(string.concat(key, ".contractPath"), DataType.STRING);
        _registerKey(string.concat(key, ".deployer"), DataType.ADDRESS);
        _registerKey(string.concat(key, ".blockNumber"), DataType.UINT);
    }

    /**
     * @notice Validate that a key has been registered (or matches a pattern) and matches expected type
     * @dev If the key matches a pattern, it is automatically registered.
     *      Reverts with helpful error message if validation fails.
     * @param key The key to validate
     * @param expectedType The expected type for this key
     */
    function validateKey(string memory key, DataType expectedType) public {
        // If already registered, just check type
        if (_keyRegistered[key]) {
            if (_keyTypes[key] != expectedType) {
                revert TypeMismatch(key, expectedType, _keyTypes[key]);
            }
            return;
        }

        // Check if it matches a pattern with the expected type
        for (uint256 i = 0; i < _patterns.length; i++) {
            KeyPattern memory pattern = _patterns[i];
            if (pattern.dtype == expectedType && _matchesPattern(key, pattern)) {
                // Auto-register the intermediate object and the concrete key
                uint256 prefixLen = bytes(pattern.prefix).length + 1; // +1 for the dot after prefix
                uint256 suffixLen = bytes(pattern.suffix).length + 1; // +1 for the dot before suffix
                uint256 keyLen = bytes(key).length;

                // Extract: key[prefixLen : keyLen - suffixLen]
                string memory wildcardValue = key.slice(prefixLen, keyLen - suffixLen);
                string memory intermediateKey = string.concat(pattern.prefix, ".", wildcardValue);

                // Register intermediate object if not already registered
                if (!_keyRegistered[intermediateKey]) {
                    _keyTypes[intermediateKey] = DataType.OBJECT;
                    _keyRegistered[intermediateKey] = true;
                    _schemaKeys.push(intermediateKey);
                }

                // Register the concrete key
                _registerKeyFromPattern(key, pattern);
                return;
            }
        }

        revert KeyNotRegistered(key);
    }

    /**
     * @notice Get all registered schema keys
     * @dev Returns the complete schema - all keys that CAN be used
     *      For keys that HAVE values, use keys() on the data layer
     * @return schemaKeys Array of all registered configuration keys
     */
    function schemaKeys() public view returns (string[] memory) {
        return _schemaKeys;
    }

    /**
     * @notice Get expected type for a key
     * @param key The key to look up
     * @return expectedType The registered type for this key
     */
    function keyType(string memory key) public view returns (DataType expectedType) {
        return _keyTypes[key];
    }

    // ============ Internal Validation ============

    /**
     * @notice Register a key with type
     * @dev Internal helper to deduplicate registration logic
     * @param key The key name
     * @param expectedType The expected type
     */
    function _registerKey(string memory key, DataType expectedType) private {
        if (_keyRegistered[key]) {
            revert KeyAlreadyRegistered(key);
        }
        _keyTypes[key] = expectedType;
        _keyRegistered[key] = true;
        _schemaKeys.push(key);
    }

    /**
     * @notice Validate and register a data key
     * @dev Common pattern for ADDRESS, STRING, UINT, INT, BOOL, and array types
     *      If the key contains dots (nested), validates parent CONTRACT exists
     * @param key The key name (e.g., "treasury" or "pegged.symbol")
     * @param expectedType The expected type for this key
     */
    function _validateDataKey(string memory key, DataType expectedType) private {
        _validateKeyFormat(key);
        if (_hasDots(key)) {
            _validateParentContract(key);
        }
        _registerKey(key, expectedType);
    }

    /**
     * @notice Validate key format
     * @dev Keys must contain only: a-z, A-Z, 0-9, '.', '_', '-'
     *      Dots represent JSON path separators for nested navigation
     *      Keys must NOT end in ".address" to avoid confusion
     * @param key The key to validate
     */
    function _validateKeyFormat(string memory key) private pure {
        bytes memory keyBytes = bytes(key);

        if (keyBytes.length == 0) {
            revert InvalidKeyFormat(key, "Key cannot be empty");
        }

        // Reject keys ending in ".address"
        if (keyBytes.length >= 8) {
            bool endsWithDotAddress = keyBytes[keyBytes.length - 8] == 0x2E && // .
                keyBytes[keyBytes.length - 7] == 0x61 && // a
                keyBytes[keyBytes.length - 6] == 0x64 && // d
                keyBytes[keyBytes.length - 5] == 0x64 && // d
                keyBytes[keyBytes.length - 4] == 0x72 && // r
                keyBytes[keyBytes.length - 3] == 0x65 && // e
                keyBytes[keyBytes.length - 2] == 0x73 && // s
                keyBytes[keyBytes.length - 1] == 0x73; // s

            if (endsWithDotAddress) {
                revert InvalidKeyFormat(key, "Key cannot end with '.address'");
            }
        }

        for (uint256 i = 0; i < keyBytes.length; i++) {
            bytes1 char = keyBytes[i];

            bool isValid = (char >= 0x30 && char <= 0x39) || // 0-9
                (char >= 0x41 && char <= 0x5A) || // A-Z
                (char >= 0x61 && char <= 0x7A) || // a-z
                char == 0x2E || // . (JSON path separator)
                char == 0x5F || // _
                char == 0x2D; // -

            if (!isValid) {
                revert InvalidKeyFormat(key, "Key contains invalid character");
            }
        }

        // Additional validation: no leading/trailing dots
        if (keyBytes[0] == 0x2E || keyBytes[keyBytes.length - 1] == 0x2E) {
            revert InvalidKeyFormat(key, "Key cannot start or end with '.'");
        }

        // No consecutive dots
        for (uint256 i = 0; i < keyBytes.length - 1; i++) {
            if (keyBytes[i] == 0x2E && keyBytes[i + 1] == 0x2E) {
                revert InvalidKeyFormat(key, "Key cannot contain consecutive dots");
            }
        }
    }

    /**
     * @notice Check if key contains dots
     * @param key The key to check
     * @return True if key contains at least one dot
     */
    function _hasDots(string memory key) private pure returns (bool) {
        bytes memory keyBytes = bytes(key);
        for (uint256 i = 0; i < keyBytes.length; i++) {
            if (keyBytes[i] == 0x2E) return true; // '.'
        }
        return false;
    }

    /**
     * @notice Require key starts with "contracts." prefix
     * @dev All contract/proxy keys must be under the contracts namespace
     * @param key The key to validate
     */
    function _requireContractsPrefix(string memory key) private pure {
        if (!LibString.startsWith(key, "contracts.")) {
            revert ContractKeyMustStartWithContracts(key);
        }
    }

    /**
     * @notice Validate that parent CONTRACT key exists for nested keys
     * @dev For key "pegged.symbol", validates that "pegged" is registered as CONTRACT
     * @param key The nested key to validate (must contain dots)
     */
    function _validateParentContract(string memory key) private view {
        bytes memory keyBytes = bytes(key);
        (bool hasDot, uint256 dotPos) = _findPreviousDot(keyBytes, keyBytes.length);
        if (!hasDot) {
            revert InvalidKeyFormat(key, "Nested key must contain '.'");
        }

        while (true) {
            string memory candidate = _substring(keyBytes, dotPos);

            // Check if this parent is registered as an OBJECT (parent node marker)
            if (_keyRegistered[candidate] && _keyTypes[candidate] == DataType.OBJECT) {
                return;
            }

            // Try the next level up
            (bool foundAnother, uint256 nextDot) = _findPreviousDot(keyBytes, dotPos);
            if (!foundAnother) {
                revert ParentContractNotRegistered(key, candidate);
            }
            dotPos = nextDot;
        }
    }

    function _substring(bytes memory data, uint256 endExclusive) private pure returns (string memory) {
        bytes memory out = new bytes(endExclusive);
        for (uint256 i = 0; i < endExclusive; i++) {
            out[i] = data[i];
        }
        return string(out);
    }

    function _findPreviousDot(bytes memory data, uint256 startIndex) private pure returns (bool, uint256) {
        if (startIndex == 0) {
            return (false, 0);
        }
        for (uint256 i = startIndex; i > 0; i--) {
            if (data[i - 1] == 0x2E) {
                return (true, i - 1);
            }
        }
        return (false, 0);
    }
}
