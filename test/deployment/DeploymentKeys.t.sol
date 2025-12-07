// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {DeploymentKeys, DataType} from "@bao-script/deployment/DeploymentKeys.sol";

/**
 * @title TestKeysForValidation
 * @notice Test implementation for key validation
 */
contract TestKeysForValidation is DeploymentKeys {
    function addTestKey(string memory key) external returns (string memory) {
        return addKey(key);
    }

    function addTestAddressKey(string memory key) external returns (string memory) {
        return addAddressKey(key);
    }

    function addTestStringKey(string memory key) external returns (string memory) {
        return addStringKey(key);
    }

    function addTestUintKey(string memory key) external returns (string memory) {
        return addUintKey(key);
    }
}

/**
 * @title DeploymentKeysTest
 * @notice Tests for key registration and validation
 */
contract DeploymentKeysTest is BaoTest {
    TestKeysForValidation keys;
    uint256 baseKeyCount;

    function _ck(string memory key) internal pure returns (string memory) {
        return string.concat("contracts", key);
    }

    function _assertKeyDelta(uint256 expectedDelta) internal view {
        string[] memory allKeys = keys.schemaKeys();
        assertEq(allKeys.length, baseKeyCount + expectedDelta);
    }

    function setUp() public {
        keys = new TestKeysForValidation();
        baseKeyCount = keys.schemaKeys().length;
    }

    // ============ Key Registration Tests ============

    function test_AddAddressKey() public {
        string memory key = keys.addTestKey(_ck("owner"));
        assertEq(key, _ck("owner"));
    }

    function test_AddStringKey() public {
        keys.addTestKey(_ck("token"));
        string memory key = keys.addTestStringKey(_ck("token.symbol"));
        assertEq(key, _ck("token.symbol"));
    }

    function test_AddUintKey() public {
        keys.addTestKey(_ck("token"));
        string memory key = keys.addTestUintKey(_ck("token.decimals"));
        assertEq(key, _ck("token.decimals"));
    }

    function test_GetAllKeys() public {
        keys.addTestKey(_ck("owner"));
        keys.addTestKey(_ck("token"));
        keys.addTestStringKey(_ck("token.symbol"));
        keys.addTestUintKey(_ck("token.decimals"));

        string[] memory allKeys = keys.schemaKeys();
        assertEq(allKeys.length, baseKeyCount + 4);
        assertEq(allKeys[baseKeyCount + 0], _ck("owner"));
        assertEq(allKeys[baseKeyCount + 1], _ck("token"));
        assertEq(allKeys[baseKeyCount + 2], _ck("token.symbol"));
        assertEq(allKeys[baseKeyCount + 3], _ck("token.decimals"));
    }

    function test_GetKeyType() public {
        keys.addTestKey(_ck("owner"));
        keys.addTestKey(_ck("token"));
        keys.addTestStringKey(_ck("token.symbol"));
        keys.addTestUintKey(_ck("token.decimals"));

        assertEq(uint256(keys.keyType(_ck("owner"))), uint256(DataType.OBJECT));
        assertEq(uint256(keys.keyType(_ck("token"))), uint256(DataType.OBJECT));
        assertEq(uint256(keys.keyType(_ck("token.symbol"))), uint256(DataType.STRING));
        assertEq(uint256(keys.keyType(_ck("token.decimals"))), uint256(DataType.UINT));
    }

    // ============ Key Validation Tests ============

    function test_ValidateRegisteredKey() public {
        keys.addTestKey(_ck("owner"));
        keys.validateKey(_ck("owner"), DataType.OBJECT);
        // Should not revert
    }

    function test_RevertValidateUnregisteredKey() public {
        vm.expectRevert();
        keys.validateKey(_ck("unregistered"), DataType.OBJECT);
    }

    function test_RevertValidateTypeMismatch() public {
        keys.addTestKey(_ck("owner"));

        vm.expectRevert();
        keys.validateKey(_ck("owner"), DataType.STRING);
    }

    // ============ Key Format Validation Tests ============

    function test_AcceptValidKeyFormats() public {
        // Simple keys
        keys.addTestKey(_ck("owner"));
        keys.addTestKey(_ck("deployer"));

        // Hierarchical keys with dots - need parent first
        keys.addTestKey(_ck("pegged"));
        keys.addTestStringKey(_ck("pegged.symbol"));
        keys.addTestStringKey(_ck("pegged.name"));

        // Keys with underscores
        keys.addTestKey(_ck("token_owner"));

        // Keys with hyphens
        keys.addTestKey(_ck("multi-sig"));

        // Keys with numbers
        keys.addTestKey(_ck("validator1"));
        keys.addTestKey(_ck("proxy2"));
    }

    function test_RevertEmptyKey() public {
        vm.expectRevert();
        keys.addTestKey("");
    }

    function test_RevertKeyStartingWithDot() public {
        vm.expectRevert();
        keys.addTestKey(".invalid");
    }

    function test_RevertKeyEndingWithDot() public {
        vm.expectRevert();
        keys.addTestKey(_ck("invalid."));
    }

    function test_RevertKeyWithConsecutiveDots() public {
        vm.expectRevert();
        keys.addTestKey(_ck("invalid..key"));
    }

    function test_RevertKeyEndingWithDotAddress() public {
        vm.expectRevert();
        keys.addTestKey(_ck("pegged.address"));
    }

    function test_RevertKeyWithInvalidCharacters() public {
        // Space
        vm.expectRevert();
        keys.addTestKey(_ck("invalid key"));

        // Special characters
        vm.expectRevert();
        keys.addTestKey(_ck("invalid@key"));

        vm.expectRevert();
        keys.addTestKey(_ck("invalid#key"));

        vm.expectRevert();
        keys.addTestKey(_ck("invalid$key"));
    }

    // ============ Hierarchical Key Tests ============

    function test_DotSeparatedHierarchy() public {
        keys.addTestKey(_ck("pegged"));
        keys.addTestStringKey(_ck("pegged.symbol"));
        keys.addTestStringKey(_ck("pegged.name"));
        keys.addTestUintKey(_ck("pegged.decimals"));

        _assertKeyDelta(4);
    }

    function test_MultiLevelHierarchy() public {
        // Add parent CONTRACT first
        keys.addTestKey(_ck("token"));
        keys.addTestStringKey(_ck("token.metadata.symbol"));
        keys.addTestStringKey(_ck("token.metadata.name"));

        _assertKeyDelta(3);
    }

    // ============ Case Sensitivity Tests ============

    function test_KeysAreCaseSensitive() public {
        keys.addTestKey(_ck("Owner"));
        keys.addTestKey(_ck("owner"));

        _assertKeyDelta(2);
    }

    // ============ Parent Contract Validation Tests ============

    function test_NestedKeyRequiresParentContract() public {
        // First add parent CONTRACT
        keys.addTestKey(_ck("token"));

        // Then nested attributes should work
        keys.addTestAddressKey(_ck("token.implementation"));
        keys.addTestStringKey(_ck("token.symbol"));
        keys.addTestUintKey(_ck("token.decimals"));

        _assertKeyDelta(4);
    }

    function test_RevertNestedKeyWithoutParent() public {
        // Try to add nested key without parent CONTRACT
        vm.expectRevert();
        keys.addTestStringKey(_ck("token.symbol"));
    }

    function test_ContractKeyAllowsDots() public {
        // CONTRACT keys can include dots to support namespaces like "contracts.*"
        string memory key = keys.addTestKey("contracts.token");
        assertEq(key, "contracts.token");
    }

    // ============ Top-Level Data Keys (Without Dots) Tests ============

    function test_StringKeyWithoutDots() public {
        // STRING keys can be top-level (no dots)
        string memory key = keys.addTestStringKey("symbol");
        assertEq(key, "symbol");
    }

    function test_UintKeyWithoutDots() public {
        // UINT keys can be top-level (no dots)
        string memory key = keys.addTestUintKey("decimals");
        assertEq(key, "decimals");
    }

    function test_AddressKeyWithoutDots() public {
        // ADDRESS keys can be top-level (no dots)
        string memory key = keys.addTestAddressKey("treasury");
        assertEq(key, "treasury");
    }

    // ============ Parent Type Validation Tests ============

    function test_RevertWhenParentIsNotContract() public {
        // Try to add nested key where parent doesn't exist
        vm.expectRevert();
        keys.addTestStringKey(_ck("nonexistent.symbol"));
    }

    function test_AllowDeepNesting() public {
        // Deep nesting is allowed as long as root is CONTRACT
        keys.addTestKey(_ck("config"));
        keys.addTestStringKey(_ck("config.setting"));
        keys.addTestStringKey(_ck("config.setting.nested"));
        keys.addTestStringKey(_ck("config.setting.nested.deep"));

        _assertKeyDelta(4);
    }
}
