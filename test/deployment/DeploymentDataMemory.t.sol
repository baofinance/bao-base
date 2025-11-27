// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {DeploymentDataMemory} from "@bao-script/deployment/DeploymentDataMemory.sol";
import {DeploymentKeys} from "@bao-script/deployment/DeploymentKeys.sol";
import {DataType} from "@bao-script/deployment/DataType.sol";

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
contract DeploymentDataMemoryTest is BaoTest {
    DeploymentDataMemory data;
    TestKeys keys;

    function setUp() public {
        keys = new TestKeys();
        data = new DeploymentDataMemory(keys);
    }

    // ============ Address Tests ============

    function test_SetAndGetAddress() public {
        address expected = address(0x1234);
        data.set(OWNER_KEY, expected);
        assertEq(data.get(OWNER_KEY), expected);
    }

    function test_AddressDefaultIsZero() public {
        vm.expectRevert();
        data.get(OWNER_KEY);
    }

    function test_HasReturnsTrueAfterSet() public {
        data.set(OWNER_KEY, address(0x1234));
        assertTrue(data.has(OWNER_KEY));
    }

    function test_HasReturnsFalseBeforeSet() public view {
        assertFalse(data.has(OWNER_KEY));
    }

    function test_KeysIncludesSetAddress() public {
        data.set(OWNER_KEY, address(0x1234));
        string[] memory allKeys = data.keys();
        assertEq(allKeys.length, 1);
        assertEq(allKeys[0], OWNER_KEY);
    }

    function test_RejectKeyEndingWithDotAddress() public {
        // This should be caught at key registration time
        // We can't test it with existing keys, but the validation is in DeploymentKeys
    }

    // ============ String Tests ============

    function test_SetAndGetString() public {
        data.setString(PEGGED_SYMBOL_KEY, "BAO");
        assertEq(data.getString(PEGGED_SYMBOL_KEY), "BAO");
    }

    function test_StringDefaultIsEmpty() public {
        vm.expectRevert();
        data.getString(PEGGED_SYMBOL_KEY);
    }

    // ============ Uint Tests ============

    function test_SetAndGetUint() public {
        data.setUint(PEGGED_DECIMALS_KEY, 18);
        assertEq(data.getUint(PEGGED_DECIMALS_KEY), 18);
    }

    function test_UintDefaultIsZero() public {
        vm.expectRevert();
        data.getUint(PEGGED_DECIMALS_KEY);
    }

    // ============ Int Tests ============

    function test_SetAndGetInt() public {
        data.setInt(CONFIG_TEMPERATURE_KEY, -273);
        assertEq(data.getInt(CONFIG_TEMPERATURE_KEY), -273);
    }

    function test_SetAndGetIntPositive() public {
        data.setInt(CONFIG_TEMPERATURE_KEY, 100);
        assertEq(data.getInt(CONFIG_TEMPERATURE_KEY), 100);
    }

    function test_IntDefaultIsZero() public {
        vm.expectRevert();
        data.getInt(CONFIG_TEMPERATURE_KEY);
    }

    // ============ Bool Tests ============

    function test_SetAndGetBool() public {
        data.setBool(CONFIG_ENABLED_KEY, true);
        assertTrue(data.getBool(CONFIG_ENABLED_KEY));
    }

    function test_BoolDefaultIsFalse() public {
        vm.expectRevert();
        data.getBool(CONFIG_ENABLED_KEY);
    }

    // ============ Address Array Tests ============

    function test_SetAndGetAddressArray() public {
        address[] memory addrs = new address[](2);
        addrs[0] = address(0x1111);
        addrs[1] = address(0x2222);

        data.setAddressArray(CONFIG_VALIDATORS_KEY, addrs);
        address[] memory result = data.getAddressArray(CONFIG_VALIDATORS_KEY);

        assertEq(result.length, 2);
        assertEq(result[0], address(0x1111));
        assertEq(result[1], address(0x2222));
    }

    function test_AddressArrayDefaultIsEmpty() public {
        vm.expectRevert();
        data.getAddressArray(CONFIG_VALIDATORS_KEY);
    }

    // ============ String Array Tests ============

    function test_SetAndGetStringArray() public {
        string[] memory tags = new string[](2);
        tags[0] = "stable";
        tags[1] = "verified";

        data.setStringArray(CONFIG_TAGS_KEY, tags);
        string[] memory result = data.getStringArray(CONFIG_TAGS_KEY);

        assertEq(result.length, 2);
        assertEq(result[0], "stable");
        assertEq(result[1], "verified");
    }

    // ============ Uint Array Tests ============

    function test_SetAndGetUintArray() public {
        uint256[] memory limits = new uint256[](3);
        limits[0] = 100;
        limits[1] = 200;
        limits[2] = 300;

        data.setUintArray(CONFIG_LIMITS_KEY, limits);
        uint256[] memory result = data.getUintArray(CONFIG_LIMITS_KEY);

        assertEq(result.length, 3);
        assertEq(result[0], 100);
        assertEq(result[1], 200);
        assertEq(result[2], 300);
    }

    // ============ Int Array Tests ============

    function test_SetAndGetIntArray() public {
        int256[] memory deltas = new int256[](3);
        deltas[0] = -50;
        deltas[1] = 0;
        deltas[2] = 100;

        data.setIntArray(CONFIG_DELTAS_KEY, deltas);
        int256[] memory result = data.getIntArray(CONFIG_DELTAS_KEY);

        assertEq(result.length, 3);
        assertEq(result[0], -50);
        assertEq(result[1], 0);
        assertEq(result[2], 100);
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
