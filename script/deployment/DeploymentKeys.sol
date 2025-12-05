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
 * @title DeploymentKeys
 * @notice Abstract contract for registering and validating deployment configuration keys
 * @dev Projects extend this to define their configuration keys with type safety
 */
abstract contract DeploymentKeys {
    // ============ Storage ============

    /// @dev Mapping from key name to expected type
    mapping(string => DataType) private _keyTypes;

    /// @dev Mapping to track if key is registered
    mapping(string => bool) private _keyRegistered;

    /// @dev Mapping from key name to decimals for numeric formatting
    /// type(uint256).max means "auto" (printf %g style), other values are fixed scale
    mapping(string => uint256) internal _keyDecimals;

    /// @dev Array of all registered keys
    string[] private _schemaKeys;

    /// @dev Sentinel value meaning "use auto-scaling" for numeric formatting
    uint256 internal constant DECIMALS_AUTO = type(uint256).max;

    // ============ Errors ============

    error InvalidKeyFormat(string key, string reason);
    error TypeMismatch(string key, DataType expectedType, DataType actualType);
    error KeyNotRegistered(string key);
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
     * @notice Register a nested address key (contains dots)
     * @dev For addresses in hierarchical configs like "pegged.implementation"
     *      Requires parent CONTRACT key to be registered first
     *      ADDRESS type keys MUST contain dots to distinguish from CONTRACT type
     * @param key The key name (e.g., "pegged.implementation") - must contain dots
     * @return key Returns the key for use in constant declarations
     */
    function addAddressKey(string memory key) internal returns (string memory) {
        _validateKeyFormat(key);
        require(_hasDots(key), "ADDRESS keys must contain dots");
        _validateParentContract(key);
        _registerKey(key, DataType.ADDRESS);
        return key;
    }

    /**
     * @notice Register a string key
     * @dev String keys MUST have dots and belong to a parent CONTRACT
     * @param key The key name (e.g., "pegged.symbol") - must contain dots
     * @return key Returns the key for use in constant declarations
     */
    function addStringKey(string memory key) internal returns (string memory) {
        _validateKeyFormat(key);
        require(_hasDots(key), "STRING keys must contain dots");
        _validateParentContract(key);
        _registerKey(key, DataType.STRING);
        return key;
    }

    /**
     * @notice Register a uint key with auto-scaling
     * @dev UINT keys MUST have dots and belong to a parent CONTRACT
     * @param key The key name (e.g., "pegged.decimals") - must contain dots
     * @return key Returns the key for use in constant declarations
     */
    function addUintKey(string memory key) internal returns (string memory) {
        return addUintKey(key, DECIMALS_AUTO);
    }

    /**
     * @notice Register a uint key with fixed decimal scaling
     * @dev UINT keys MUST have dots and belong to a parent CONTRACT
     * @param key The key name (e.g., "pegged.totalSupply") - must contain dots
     * @param decimals The decimal places for formatting (e.g., 18 for token amounts)
     * @return key Returns the key for use in constant declarations
     */
    function addUintKey(string memory key, uint256 decimals) internal returns (string memory) {
        _validateKeyFormat(key);
        require(_hasDots(key), "UINT keys must contain dots");
        _validateParentContract(key);
        _registerKey(key, DataType.UINT);
        _keyDecimals[key] = decimals;
        return key;
    }

    /**
     * @notice Register an int key with auto-scaling
     * @dev INT keys MUST have dots and belong to a parent CONTRACT
     * @param key The key name (e.g., "pegged.offset") - must contain dots
     * @return key Returns the key for use in constant declarations
     */
    function addIntKey(string memory key) internal returns (string memory) {
        return addIntKey(key, DECIMALS_AUTO);
    }

    /**
     * @notice Register an int key with fixed decimal scaling
     * @dev INT keys MUST have dots and belong to a parent CONTRACT
     * @param key The key name (e.g., "config.delta") - must contain dots
     * @param decimals The decimal places for formatting (e.g., 18 for token amounts)
     * @return key Returns the key for use in constant declarations
     */
    function addIntKey(string memory key, uint256 decimals) internal returns (string memory) {
        _validateKeyFormat(key);
        require(_hasDots(key), "INT keys must contain dots");
        _validateParentContract(key);
        _registerKey(key, DataType.INT);
        _keyDecimals[key] = decimals;
        return key;
    }

    /**
     * @notice Register a bool key
     * @dev BOOL keys MUST have dots and belong to a parent CONTRACT
     * @param key The key name (e.g., "pegged.enabled") - must contain dots
     * @return key Returns the key for use in constant declarations
     */
    function addBoolKey(string memory key) internal returns (string memory) {
        _validateKeyFormat(key);
        require(_hasDots(key), "BOOL keys must contain dots");
        _validateParentContract(key);
        _registerKey(key, DataType.BOOL);
        return key;
    }

    /**
     * @notice Register an address array key
     * @dev ADDRESS_ARRAY keys MUST have dots and belong to a parent CONTRACT
     * @param key The key name (e.g., "token.validators") - must contain dots
     * @return key Returns the key for use in constant declarations
     */
    function addAddressArrayKey(string memory key) internal returns (string memory) {
        _validateKeyFormat(key);
        require(_hasDots(key), "ADDRESS_ARRAY keys must contain dots");
        _validateParentContract(key);
        _registerKey(key, DataType.ADDRESS_ARRAY);
        return key;
    }

    /**
     * @notice Register a string array key
     * @dev STRING_ARRAY keys MUST have dots and belong to a parent CONTRACT
     * @param key The key name (e.g., "token.tags") - must contain dots
     * @return key Returns the key for use in constant declarations
     */
    function addStringArrayKey(string memory key) internal returns (string memory) {
        _validateKeyFormat(key);
        require(_hasDots(key), "STRING_ARRAY keys must contain dots");
        _validateParentContract(key);
        _registerKey(key, DataType.STRING_ARRAY);
        return key;
    }

    /**
     * @notice Register a uint array key with auto-scaling
     * @dev UINT_ARRAY keys MUST have dots and belong to a parent CONTRACT
     * @param key The key name (e.g., "token.limits") - must contain dots
     * @return key Returns the key for use in constant declarations
     */
    function addUintArrayKey(string memory key) internal returns (string memory) {
        return addUintArrayKey(key, DECIMALS_AUTO);
    }

    /**
     * @notice Register a uint array key with fixed decimal scaling
     * @dev UINT_ARRAY keys MUST have dots and belong to a parent CONTRACT
     * @param key The key name (e.g., "token.amounts") - must contain dots
     * @param decimals The decimal places for formatting (e.g., 18 for token amounts)
     * @return key Returns the key for use in constant declarations
     */
    function addUintArrayKey(string memory key, uint256 decimals) internal returns (string memory) {
        _validateKeyFormat(key);
        require(_hasDots(key), "UINT_ARRAY keys must contain dots");
        _validateParentContract(key);
        _registerKey(key, DataType.UINT_ARRAY);
        _keyDecimals[key] = decimals;
        return key;
    }

    /**
     * @notice Register an int array key with auto-scaling
     * @dev INT_ARRAY keys MUST have dots and belong to a parent CONTRACT
     * @param key The key name (e.g., "token.deltas") - must contain dots
     * @return key Returns the key for use in constant declarations
     */
    function addIntArrayKey(string memory key) internal returns (string memory) {
        return addIntArrayKey(key, DECIMALS_AUTO);
    }

    /**
     * @notice Register an int array key with fixed decimal scaling
     * @dev INT_ARRAY keys MUST have dots and belong to a parent CONTRACT
     * @param key The key name (e.g., "config.offsets") - must contain dots
     * @param decimals The decimal places for formatting (e.g., 18 for token amounts)
     * @return key Returns the key for use in constant declarations
     */
    function addIntArrayKey(string memory key, uint256 decimals) internal returns (string memory) {
        _validateKeyFormat(key);
        require(_hasDots(key), "INT_ARRAY keys must contain dots");
        _validateParentContract(key);
        _registerKey(key, DataType.INT_ARRAY);
        _keyDecimals[key] = decimals;
        return key;
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
        _registerKey(string.concat(key, ".value"), DataType.UINT);
        _registerKey(string.concat(key, ".saltString"), DataType.STRING);
        _registerKey(string.concat(key, ".salt"), DataType.STRING); // Store as hex string

        string memory implementationKey = string.concat(key, ".implementation");
        _addImplementation(implementationKey);
        // ownershipModel is a property of the implementation, not the proxy
        _registerKey(string.concat(implementationKey, ".ownershipModel"), DataType.STRING);
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
     * @notice Validate that a key has been registered and matches expected type
     * @dev Reverts with helpful error message if validation fails
     * @param key The key to validate
     * @param expectedType The expected type for this key
     */
    function validateKey(string memory key, DataType expectedType) public view {
        if (!_keyRegistered[key]) {
            revert KeyNotRegistered(key);
        }
        if (_keyTypes[key] != expectedType) {
            revert TypeMismatch(key, expectedType, _keyTypes[key]);
        }
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
        _keyTypes[key] = expectedType;
        _keyRegistered[key] = true;
        _schemaKeys.push(key);
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
