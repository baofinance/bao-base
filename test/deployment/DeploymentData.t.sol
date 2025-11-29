// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import {BaoTest} from "@bao-test/BaoTest.sol";
import {DeploymentDataMemory} from "@bao-script/deployment/DeploymentDataMemory.sol";
import {DeploymentDataJson} from "@bao-script/deployment/DeploymentDataJson.sol";
import {DeploymentKeys, DataType} from "@bao-script/deployment/DeploymentKeys.sol";

string constant OWNER_KEY = "owner";
string constant PEGGED_KEY = "contracts.pegged";
string constant CONFIG_KEY = "contracts.config";
string constant PEGGED_IMPL_KEY = "contracts.pegged.implementation";
string constant PEGGED_SYMBOL_KEY = "contracts.pegged.symbol";
string constant PEGGED_NAME_KEY = "contracts.pegged.name";
string constant PEGGED_DECIMALS_KEY = "contracts.pegged.decimals";
string constant PEGGED_SUPPLY_KEY = "contracts.pegged.supply";
string constant CONFIG_TEMPERATURE_KEY = "contracts.config.temperature";
string constant CONFIG_ENABLED_KEY = "contracts.config.enabled";
string constant CONFIG_VALIDATORS_KEY = "contracts.config.validators";
string constant CONFIG_TAGS_KEY = "contracts.config.tags";
string constant CONFIG_LIMITS_KEY = "contracts.config.limits";
string constant CONFIG_DELTAS_KEY = "contracts.config.deltas";

/**
 * @title TestKeys
 * @notice Key registry for testing
 */
contract TestKeys is DeploymentKeys {
    constructor() {
        addKey(OWNER_KEY);
        addKey(PEGGED_KEY);
        addKey(CONFIG_KEY); // Parent for scalar attributes
        addAddressKey(PEGGED_IMPL_KEY);
        addStringKey(PEGGED_SYMBOL_KEY);
        addStringKey(PEGGED_NAME_KEY);
        addUintKey(PEGGED_DECIMALS_KEY);
        addUintKey(PEGGED_SUPPLY_KEY);
        addIntKey(CONFIG_TEMPERATURE_KEY);
        addBoolKey(CONFIG_ENABLED_KEY);
        addAddressArrayKey(CONFIG_VALIDATORS_KEY);
        addStringArrayKey(CONFIG_TAGS_KEY);
        addUintArrayKey(CONFIG_LIMITS_KEY);
        addIntArrayKey(CONFIG_DELTAS_KEY);
    }
}

/**
 * @title DeploymentDataMemoryTest
 * @notice Tests for in-memory deployment data implementation
 */
contract DeploymentDataTest is BaoTest {
    DeploymentDataMemory data;
    TestKeys keys;

    function _createDeploymentData(TestKeys keys_) internal virtual returns (DeploymentDataMemory data_) {
        data_ = new DeploymentDataMemory(keys_);
    }

    function setUp() public {
        keys = new TestKeys();
        data = _createDeploymentData(keys);
    }

    // ============ Address Tests ============

    function test_SetAndGet() public {
        string[] memory allKeys = data.keys();
        assertEq(allKeys.length, 0);

        assertFalse(data.has(OWNER_KEY));
        vm.expectRevert();
        data.get(OWNER_KEY);

        address expected = address(0x1234);
        data.set(OWNER_KEY, expected);

        assertTrue(data.has(OWNER_KEY));
        assertEq(data.get(OWNER_KEY), expected);

        allKeys = data.keys();
        assertEq(allKeys.length, 1);
        assertEq(allKeys[0], OWNER_KEY);
    }

    function test_SetAndGetAddress() public {
        string[] memory allKeys = data.keys();
        assertEq(allKeys.length, 0);

        assertFalse(data.has(PEGGED_IMPL_KEY));
        vm.expectRevert();
        data.getAddress(PEGGED_IMPL_KEY);

        address expected = address(0x5678);
        data.setAddress(PEGGED_IMPL_KEY, expected);

        assertTrue(data.has(PEGGED_IMPL_KEY));
        assertEq(data.getAddress(PEGGED_IMPL_KEY), expected);

        allKeys = data.keys();
        assertEq(allKeys.length, 1);
        assertEq(allKeys[0], PEGGED_IMPL_KEY);
    }

    // ============ String Tests ============

    function test_SetAndGetString() public {
        string[] memory allKeys = data.keys();
        assertEq(allKeys.length, 0);

        assertFalse(data.has(PEGGED_SYMBOL_KEY));
        vm.expectRevert();
        data.getString(PEGGED_SYMBOL_KEY);

        string memory expected = "BAO";
        data.setString(PEGGED_SYMBOL_KEY, expected);

        assertTrue(data.has(PEGGED_SYMBOL_KEY));
        assertEq(data.getString(PEGGED_SYMBOL_KEY), expected);

        allKeys = data.keys();
        assertEq(allKeys.length, 1);
        assertEq(allKeys[0], PEGGED_SYMBOL_KEY);
    }

    // ============ Uint Tests ============

    function test_SetAndGetUint() public {
        string[] memory allKeys = data.keys();
        assertEq(allKeys.length, 0);

        assertFalse(data.has(PEGGED_DECIMALS_KEY));
        vm.expectRevert();
        data.getUint(PEGGED_DECIMALS_KEY);

        uint256 expected = 18;
        data.setUint(PEGGED_DECIMALS_KEY, expected);

        assertTrue(data.has(PEGGED_DECIMALS_KEY));
        assertEq(data.getUint(PEGGED_DECIMALS_KEY), expected);

        allKeys = data.keys();
        assertEq(allKeys.length, 1);
        assertEq(allKeys[0], PEGGED_DECIMALS_KEY);
    }

    // ============ Int Tests ============

    function test_SetAndGetInt() public {
        string[] memory allKeys = data.keys();
        assertEq(allKeys.length, 0);

        assertFalse(data.has(CONFIG_TEMPERATURE_KEY));
        vm.expectRevert();
        data.getInt(CONFIG_TEMPERATURE_KEY);

        int256 expected = -273;
        data.setInt(CONFIG_TEMPERATURE_KEY, expected);

        assertTrue(data.has(CONFIG_TEMPERATURE_KEY));
        assertEq(data.getInt(CONFIG_TEMPERATURE_KEY), expected);

        allKeys = data.keys();
        assertEq(allKeys.length, 1);
        assertEq(allKeys[0], CONFIG_TEMPERATURE_KEY);
    }

    function test_SetAndGetIntPositive() public {
        data.setInt(CONFIG_TEMPERATURE_KEY, 100);
        assertEq(data.getInt(CONFIG_TEMPERATURE_KEY), 100);
    }

    // ============ Bool Tests ============

    function test_SetAndGetBool() public {
        string[] memory allKeys = data.keys();
        assertEq(allKeys.length, 0);

        assertFalse(data.has(CONFIG_ENABLED_KEY));
        vm.expectRevert();
        data.getBool(CONFIG_ENABLED_KEY);

        bool expected = true;
        data.setBool(CONFIG_ENABLED_KEY, expected);

        assertTrue(data.has(CONFIG_ENABLED_KEY));
        assertTrue(data.getBool(CONFIG_ENABLED_KEY));

        allKeys = data.keys();
        assertEq(allKeys.length, 1);
        assertEq(allKeys[0], CONFIG_ENABLED_KEY);
    }

    // ============ Address Array Tests ============

    function test_SetAndGetAddressArray() public {
        string[] memory allKeys = data.keys();
        assertEq(allKeys.length, 0);

        assertFalse(data.has(CONFIG_VALIDATORS_KEY));
        vm.expectRevert();
        data.getAddressArray(CONFIG_VALIDATORS_KEY);

        address[] memory expected = new address[](2);
        expected[0] = address(0x1111);
        expected[1] = address(0x2222);
        data.setAddressArray(CONFIG_VALIDATORS_KEY, expected);

        assertTrue(data.has(CONFIG_VALIDATORS_KEY));
        address[] memory result = data.getAddressArray(CONFIG_VALIDATORS_KEY);
        assertEq(result.length, 2);
        assertEq(result[0], address(0x1111));
        assertEq(result[1], address(0x2222));

        allKeys = data.keys();
        assertEq(allKeys.length, 1);
        assertEq(allKeys[0], CONFIG_VALIDATORS_KEY);
    }

    // ============ String Array Tests ============

    function test_SetAndGetStringArray() public {
        string[] memory allKeys = data.keys();
        assertEq(allKeys.length, 0);

        assertFalse(data.has(CONFIG_TAGS_KEY));
        vm.expectRevert();
        data.getStringArray(CONFIG_TAGS_KEY);

        string[] memory expected = new string[](2);
        expected[0] = "stable";
        expected[1] = "verified";
        data.setStringArray(CONFIG_TAGS_KEY, expected);

        assertTrue(data.has(CONFIG_TAGS_KEY));
        string[] memory result = data.getStringArray(CONFIG_TAGS_KEY);
        assertEq(result.length, 2);
        assertEq(result[0], "stable");
        assertEq(result[1], "verified");

        allKeys = data.keys();
        assertEq(allKeys.length, 1);
        assertEq(allKeys[0], CONFIG_TAGS_KEY);
    }

    // ============ Uint Array Tests ============

    function test_SetAndGetUintArray() public {
        string[] memory allKeys = data.keys();
        assertEq(allKeys.length, 0);

        assertFalse(data.has(CONFIG_LIMITS_KEY));
        vm.expectRevert();
        data.getUintArray(CONFIG_LIMITS_KEY);

        uint256[] memory expected = new uint256[](3);
        expected[0] = 100;
        expected[1] = 200;
        expected[2] = 300;
        data.setUintArray(CONFIG_LIMITS_KEY, expected);

        assertTrue(data.has(CONFIG_LIMITS_KEY));
        uint256[] memory result = data.getUintArray(CONFIG_LIMITS_KEY);
        assertEq(result.length, 3);
        assertEq(result[0], 100);
        assertEq(result[1], 200);
        assertEq(result[2], 300);

        allKeys = data.keys();
        assertEq(allKeys.length, 1);
        assertEq(allKeys[0], CONFIG_LIMITS_KEY);
    }

    // ============ Int Array Tests ============

    function test_SetAndGetIntArray() public {
        string[] memory allKeys = data.keys();
        assertEq(allKeys.length, 0);

        assertFalse(data.has(CONFIG_DELTAS_KEY));
        vm.expectRevert();
        data.getIntArray(CONFIG_DELTAS_KEY);

        int256[] memory expected = new int256[](3);
        expected[0] = -50;
        expected[1] = 0;
        expected[2] = 100;
        data.setIntArray(CONFIG_DELTAS_KEY, expected);

        assertTrue(data.has(CONFIG_DELTAS_KEY));
        int256[] memory result = data.getIntArray(CONFIG_DELTAS_KEY);
        assertEq(result.length, 3);
        assertEq(result[0], -50);
        assertEq(result[1], 0);
        assertEq(result[2], 100);

        allKeys = data.keys();
        assertEq(allKeys.length, 1);
        assertEq(allKeys[0], CONFIG_DELTAS_KEY);
    }

    // ============ Multiple Keys Tests ============

    function test_MultipleKeysTracked() public {
        data.set(OWNER_KEY, address(0x1111));
        data.setString(PEGGED_SYMBOL_KEY, "BAO");
        data.setUint(PEGGED_DECIMALS_KEY, 18);

        string[] memory allKeys = data.keys();
        assertEq(allKeys.length, 3);
    }

    function test_OverwriteValue() public {
        data.set(OWNER_KEY, address(0x1111));
        data.set(OWNER_KEY, address(0x2222));

        assertEq(data.get(OWNER_KEY), address(0x2222));

        // Keys should not duplicate
        string[] memory allKeys = data.keys();
        assertEq(allKeys.length, 1);
    }

    // ============ Type Validation Tests ============

    function test_RevertWhenKeyNotRegistered() public {
        vm.expectRevert();
        data.set("unregistered", address(0x1234));
    }

    function test_RevertWhenTypeMismatch() public {
        // Try to set string value with address setter
        vm.expectRevert();
        data.set(PEGGED_SYMBOL_KEY, address(0x1234));
    }

    // ============ Nested Address Tests ============

    function test_SetAndGetNestedAddress() public {
        data.setAddress(PEGGED_IMPL_KEY, address(0x9999));
        assertEq(data.getAddress(PEGGED_IMPL_KEY), address(0x9999), "Nested address mismatch");
    }

    function test_ContractVsNestedAddress() public {
        // set() is for CONTRACT type (top-level, no dots)
        data.set(OWNER_KEY, address(0x1111));
        assertEq(data.get(OWNER_KEY), address(0x1111), "CONTRACT address mismatch");

        // setAddress() is for ADDRESS type (nested, with dots)
        data.setAddress(PEGGED_IMPL_KEY, address(0x2222));
        assertEq(data.getAddress(PEGGED_IMPL_KEY), address(0x2222), "Nested ADDRESS mismatch");
    }
}

contract DeploymentDataJsonTest is DeploymentDataTest {
    using stdJson for string;
    DeploymentDataJson dataJson;

    function _createDeploymentData(TestKeys keys_) internal override returns (DeploymentDataMemory) {
        dataJson = new DeploymentDataJson(keys_);
        return dataJson;
    }
}
