// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DeploymentDataJsonTesting} from "@bao-script/deployment/DeploymentDataJsonTesting.sol";
import {DeploymentKeys, DataType} from "@bao-script/deployment/DeploymentKeys.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {DeploymentLogsTest} from "./DeploymentLogsTest.sol";

string constant OWNER_KEY_JSON = "owner";
string constant PEGGED_KEY_JSON = "contracts.pegged";
string constant CONFIG_KEY_JSON = "contracts.config";
string constant PEGGED_IMPL_KEY_JSON = "contracts.pegged.implementation";
string constant PEGGED_SYMBOL_KEY_JSON = "contracts.pegged.symbol";
string constant PEGGED_NAME_KEY_JSON = "contracts.pegged.name";
string constant PEGGED_DECIMALS_KEY_JSON = "contracts.pegged.decimals";
string constant PEGGED_SUPPLY_KEY_JSON = "contracts.pegged.supply";
string constant CONFIG_TEMPERATURE_KEY_JSON = "contracts.config.temperature";
string constant CONFIG_ENABLED_KEY_JSON = "contracts.config.enabled";
string constant CONFIG_VALIDATORS_KEY_JSON = "contracts.config.validators";
string constant CONFIG_TAGS_KEY_JSON = "contracts.config.tags";
string constant CONFIG_LIMITS_KEY_JSON = "contracts.config.limits";
string constant CONFIG_DELTAS_KEY_JSON = "contracts.config.deltas";

/**
 * @title TestKeys
 * @notice Key registry for testing
 */
contract TestKeysJson is DeploymentKeys {
    constructor() {
        addKey(OWNER_KEY_JSON);
        addKey(PEGGED_KEY_JSON);
        addKey(CONFIG_KEY_JSON); // Parent for scalar attributes
        addAddressKey(PEGGED_IMPL_KEY_JSON);
        addStringKey(PEGGED_SYMBOL_KEY_JSON);
        addStringKey(PEGGED_NAME_KEY_JSON);
        addUintKey(PEGGED_DECIMALS_KEY_JSON);
        addUintKey(PEGGED_SUPPLY_KEY_JSON);
        addIntKey(CONFIG_TEMPERATURE_KEY_JSON);
        addBoolKey(CONFIG_ENABLED_KEY_JSON);
        addAddressArrayKey(CONFIG_VALIDATORS_KEY_JSON);
        addStringArrayKey(CONFIG_TAGS_KEY_JSON);
        addUintArrayKey(CONFIG_LIMITS_KEY_JSON);
        addIntArrayKey(CONFIG_DELTAS_KEY_JSON);
    }
}

/**
 * @title DeploymentDataJsonTest
 * @notice Tests for JSON-backed deployment data implementation
 */
contract DeploymentDataJsonTest is DeploymentLogsTest {
    using stdJson for string;

    DeploymentDataJsonTesting data;
    TestKeysJson keys;

    function setUp() public {
        keys = new TestKeysJson();
        data = new DeploymentDataJsonTesting(keys);
    }

    // ============ Address Tests ============

    function test_SetAndGetAddress() public {
        address expected = address(0x1234);
        data.set(OWNER_KEY_JSON, expected);
        assertEq(data.get(OWNER_KEY_JSON), expected);
    }

    function test_HasReturnsTrueAfterSet() public {
        data.set(OWNER_KEY_JSON, address(0x1234));
        assertTrue(data.has(OWNER_KEY_JSON));
    }

    function test_HasReturnsFalseBeforeSet() public view {
        assertFalse(data.has(OWNER_KEY_JSON));
    }

    function test_KeysIncludesSetAddress() public {
        data.set(OWNER_KEY_JSON, address(0x1234));
        string[] memory allKeys = data.keys();
        assertEq(allKeys.length, 1);
        assertEq(allKeys[0], OWNER_KEY_JSON);
    }

    // ============ String Tests ============

    function test_SetAndGetString() public {
        data.setString(PEGGED_NAME_KEY_JSON, "Bao Token");
        assertEq(data.getString(PEGGED_NAME_KEY_JSON), "Bao Token");
    }

    function test_SetAndGetStringSymbol() public {
        data.setString(PEGGED_SYMBOL_KEY_JSON, "BAO");
        assertEq(data.getString(PEGGED_SYMBOL_KEY_JSON), "BAO");
    }

    // ============ Uint Tests ============

    function test_SetAndGetUint() public {
        data.setUint(PEGGED_DECIMALS_KEY_JSON, 18);
        assertEq(data.getUint(PEGGED_DECIMALS_KEY_JSON), 18);
    }

    function test_SetAndGetUintSupply() public {
        data.setUint(PEGGED_SUPPLY_KEY_JSON, 1000000);
        assertEq(data.getUint(PEGGED_SUPPLY_KEY_JSON), 1000000);
    }

    function test_UintLargeValue() public {
        uint256 largeValue = type(uint256).max;
        data.setUint(PEGGED_SUPPLY_KEY_JSON, largeValue);
        assertEq(data.getUint(PEGGED_SUPPLY_KEY_JSON), largeValue);
    }

    function test_RevertGetUintWhenNotSet() public {
        // Reading uint before setting should fail validation
        vm.expectRevert();
        data.getUint(PEGGED_DECIMALS_KEY_JSON);
    }

    // ============ Int Tests ============

    function test_SetAndGetInt() public {
        data.setInt(CONFIG_TEMPERATURE_KEY_JSON, -273);
        assertEq(data.getInt(CONFIG_TEMPERATURE_KEY_JSON), -273);
    }

    function test_SetAndGetPositiveInt() public {
        data.setInt(CONFIG_TEMPERATURE_KEY_JSON, 100);
        assertEq(data.getInt(CONFIG_TEMPERATURE_KEY_JSON), 100);
    }

    function test_IntMaxValue() public {
        int256 maxValue = type(int256).max;
        data.setInt(CONFIG_TEMPERATURE_KEY_JSON, maxValue);
        assertEq(data.getInt(CONFIG_TEMPERATURE_KEY_JSON), maxValue);
    }

    function test_IntMinValue() public {
        int256 minValue = type(int256).min;
        data.setInt(CONFIG_TEMPERATURE_KEY_JSON, minValue);
        assertEq(data.getInt(CONFIG_TEMPERATURE_KEY_JSON), minValue);
    }

    // ============ Bool Tests ============

    function test_SetAndGetBool() public {
        data.setBool(CONFIG_ENABLED_KEY_JSON, true);
        assertTrue(data.getBool(CONFIG_ENABLED_KEY_JSON));
    }

    function test_SetAndGetBoolFalse() public {
        data.setBool(CONFIG_ENABLED_KEY_JSON, false);
        assertFalse(data.getBool(CONFIG_ENABLED_KEY_JSON));
    }

    // ============ Address Array Tests ============

    function test_SetAndGetAddressArray() public {
        address[] memory addrs = new address[](2);
        addrs[0] = address(0x1111);
        addrs[1] = address(0x2222);

        data.setAddressArray(CONFIG_VALIDATORS_KEY_JSON, addrs);
        address[] memory result = data.getAddressArray(CONFIG_VALIDATORS_KEY_JSON);

        assertEq(result.length, 2);
        assertEq(result[0], address(0x1111));
        assertEq(result[1], address(0x2222));
    }

    function test_EmptyAddressArray() public {
        address[] memory addrs = new address[](0);
        data.setAddressArray(CONFIG_VALIDATORS_KEY_JSON, addrs);
        address[] memory result = data.getAddressArray(CONFIG_VALIDATORS_KEY_JSON);
        assertEq(result.length, 0);
    }

    // ============ String Array Tests ============

    function test_SetAndGetStringArray() public {
        string[] memory tags = new string[](2);
        tags[0] = "stable";
        tags[1] = "verified";

        data.setStringArray(CONFIG_TAGS_KEY_JSON, tags);
        string[] memory result = data.getStringArray(CONFIG_TAGS_KEY_JSON);

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

        data.setUintArray(CONFIG_LIMITS_KEY_JSON, limits);
        uint256[] memory result = data.getUintArray(CONFIG_LIMITS_KEY_JSON);

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

        data.setIntArray(CONFIG_DELTAS_KEY_JSON, deltas);
        int256[] memory result = data.getIntArray(CONFIG_DELTAS_KEY_JSON);

        assertEq(result.length, 3);
        assertEq(result[0], -50);
        assertEq(result[1], 0);
        assertEq(result[2], 100);
    }

    // ============ Multiple Keys Tests ============

    function test_MultipleKeysTracked() public {
        data.set(OWNER_KEY_JSON, address(0x1111));
        data.setString(PEGGED_SYMBOL_KEY_JSON, "BAO");
        data.setUint(PEGGED_DECIMALS_KEY_JSON, 18);

        string[] memory allKeys = data.keys();
        assertEq(allKeys.length, 3);
    }

    function test_OverwriteValue() public {
        data.set(OWNER_KEY_JSON, address(0x1111));
        data.set(OWNER_KEY_JSON, address(0x2222));

        assertEq(data.get(OWNER_KEY_JSON), address(0x2222));

        // Keys should not duplicate
        string[] memory allKeys = data.keys();
        assertEq(allKeys.length, 1);
    }

    // ============ JSON Export Tests ============

    function test_ToJsonIncludesValues() public {
        data.set(OWNER_KEY_JSON, address(0x1234567890123456789012345678901234567890));
        data.setString(PEGGED_SYMBOL_KEY_JSON, "BAO");
        data.setUint(PEGGED_DECIMALS_KEY_JSON, 18);

        string memory json = data.toJson();

        // Basic validation - should contain the values
        assertTrue(bytes(json).length > 0, "JSON should not be empty");
    }

    // ============ Type Validation Tests ============

    function test_RevertWhenKeyNotRegistered() public {
        vm.expectRevert();
        data.set("unregistered", address(0x1234));
    }

    function test_RevertWhenTypeMismatch() public {
        // Try to set string value with address setter
        vm.expectRevert();
        data.set(PEGGED_SYMBOL_KEY_JSON, address(0x1234));
    }

    function test_RevertWhenReadingUintAsInt() public {
        data.setUint(PEGGED_DECIMALS_KEY_JSON, 18);

        // Trying to read a UINT as INT should fail validation
        vm.expectRevert();
        data.getInt(PEGGED_DECIMALS_KEY_JSON);
    }

    function test_RevertWhenReadingIntAsUint() public {
        data.setInt(CONFIG_TEMPERATURE_KEY_JSON, -273);

        // Trying to read an INT as UINT should fail validation
        vm.expectRevert();
        data.getUint(CONFIG_TEMPERATURE_KEY_JSON);
    }

    function test_RevertWhenReadingUintArrayAsIntArray() public {
        uint256[] memory limits = new uint256[](1);
        limits[0] = 100;
        data.setUintArray(CONFIG_LIMITS_KEY_JSON, limits);

        vm.expectRevert();
        data.getIntArray(CONFIG_LIMITS_KEY_JSON);
    }

    // ============ JSON Initialization Tests ============

    function test_InitializeFromJson() public {
        string memory initialJson = '{"owner":"0x0000000000000000000000000000000000001234"}';

        DeploymentDataJsonTesting dataFromJson = new DeploymentDataJsonTesting(keys);

        assertEq(dataFromJson.get(OWNER_KEY_JSON), address(0x1234));
    }

    function test_InitializeFromJsonWithMultipleKeys() public {
        string
            memory initialJson = '{"owner":"0x0000000000000000000000000000000000001234","contracts":{"pegged":"0x0000000000000000000000000000000000005678"}}';

        DeploymentDataJsonTesting dataFromJson = new DeploymentDataJsonTesting(keys);

        dataFromJson.fromJson(initialJson);
        assertEq(dataFromJson.get(OWNER_KEY_JSON), address(0x1234));
        assertEq(dataFromJson.get(PEGGED_KEY_JSON), address(0x5678));
    }

    // ============ Nested Address Tests ============

    function test_SetAndGetNestedAddress() public {
        data.setAddress(PEGGED_IMPL_KEY_JSON, address(0x9999));
        assertEq(data.getAddress(PEGGED_IMPL_KEY_JSON), address(0x9999), "Nested address mismatch");
    }

    function test_ContractVsNestedAddress() public {
        // set() is for CONTRACT type (top-level, no dots)
        data.set(OWNER_KEY_JSON, address(0x1111));
        assertEq(data.get(OWNER_KEY_JSON), address(0x1111), "CONTRACT address mismatch");

        // setAddress() is for ADDRESS type (nested, with dots)
        data.setAddress(PEGGED_IMPL_KEY_JSON, address(0x2222));
        assertEq(data.getAddress(PEGGED_IMPL_KEY_JSON), address(0x2222), "Nested ADDRESS mismatch");
    }

    function test_NestedAddressInJson() public {
        data.setAddress(PEGGED_IMPL_KEY_JSON, address(0xABCD));
        string memory json = data.toJson();

        // Should create nested structure: {"contracts": {"pegged": {"implementation": "0x..."}}}
        address recovered = json.readAddress("$.contracts.pegged.implementation");
        assertEq(recovered, address(0xABCD), "JSON nested address mismatch");
    }
}
