// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import {BaoTest} from "@bao-test/BaoTest.sol";
import {DeploymentTesting} from "@bao-script/deployment/DeploymentTesting.sol";
import {DeploymentJsonTesting} from "@bao-script/deployment/DeploymentJsonTesting.sol";
import {DeploymentKeys, DataType} from "@bao-script/deployment/DeploymentKeys.sol";

string constant OWNER_KEY = "owner";
string constant PEGGED_KEY = "contracts.pegged";
string constant PEGGED_ADDRESS_KEY = "contracts.pegged.address";
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
 * @title TestDataHarness
 * @notice Concrete test harness for deployment data testing
 * @dev Extends DeploymentTesting with test-specific keys
 */
contract TestDataHarness is DeploymentTesting {
    constructor() {
        addContract(PEGGED_KEY); // Registers PEGGED_KEY as OBJECT + .address, .contractType, etc.
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
 * @title TestDataJsonHarness
 * @notice Concrete test harness for JSON deployment data testing
 * @dev Extends DeploymentJsonTesting with test-specific keys
 */
contract TestDataJsonHarness is DeploymentJsonTesting {
    constructor() {
        addContract(PEGGED_KEY);
        addKey(CONFIG_KEY);
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
 * @title DeploymentDataTest
 * @notice Tests for in-memory deployment data implementation
 */
contract DeploymentDataTest is BaoTest {
    TestDataHarness data;

    function _createDeploymentData() internal virtual returns (TestDataHarness data_) {
        data_ = new TestDataHarness();
    }

    function setUp() public {
        data = _createDeploymentData();
    }

    // ============ Address Tests ============

    function test_SetAndGetContractAddress() public {
        string[] memory allKeys = data.keys();
        assertEq(allKeys.length, 0);

        assertFalse(data.has(PEGGED_ADDRESS_KEY));
        vm.expectRevert();
        data.get(PEGGED_KEY);

        address expected = address(0x1234);
        data.setAddress(PEGGED_ADDRESS_KEY, expected);

        assertTrue(data.has(PEGGED_ADDRESS_KEY));
        assertEq(data.get(PEGGED_KEY), expected);

        allKeys = data.keys();
        assertEq(allKeys.length, 1);
        assertEq(allKeys[0], PEGGED_ADDRESS_KEY);
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

    function test_UintLargeValue() public {
        uint256 largeValue = type(uint256).max;
        data.setUint(PEGGED_SUPPLY_KEY, largeValue);
        assertEq(data.getUint(PEGGED_SUPPLY_KEY), largeValue);
    }

    function test_IntMaxValue() public {
        int256 maxValue = type(int256).max;
        data.setInt(CONFIG_TEMPERATURE_KEY, maxValue);
        assertEq(data.getInt(CONFIG_TEMPERATURE_KEY), maxValue);
    }

    function test_IntMinValue() public {
        int256 minValue = type(int256).min;
        data.setInt(CONFIG_TEMPERATURE_KEY, minValue);
        assertEq(data.getInt(CONFIG_TEMPERATURE_KEY), minValue);
    }

    function test_SetAndGetBoolFalse() public {
        data.setBool(CONFIG_ENABLED_KEY, false);
        assertFalse(data.getBool(CONFIG_ENABLED_KEY));
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

    function test_EmptyAddressArray() public {
        address[] memory expected = new address[](0);
        data.setAddressArray(CONFIG_VALIDATORS_KEY, expected);
        address[] memory result = data.getAddressArray(CONFIG_VALIDATORS_KEY);
        assertEq(result.length, 0);
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
        data.setAddress(PEGGED_ADDRESS_KEY, address(0x1111));
        data.setString(PEGGED_SYMBOL_KEY, "BAO");
        data.setUint(PEGGED_DECIMALS_KEY, 18);

        string[] memory allKeys = data.keys();
        assertEq(allKeys.length, 3);
    }

    function test_OverwriteValue() public {
        data.setAddress(PEGGED_ADDRESS_KEY, address(0x1111));
        data.setAddress(PEGGED_ADDRESS_KEY, address(0x2222));

        assertEq(data.get(PEGGED_KEY), address(0x2222));

        // Keys should not duplicate
        string[] memory allKeys = data.keys();
        assertEq(allKeys.length, 1);
    }

    // ============ Type Validation Tests ============

    function test_RevertWhenKeyNotRegistered() public {
        vm.expectRevert();
        data.setAddress("unregistered", address(0x1234));
    }

    function test_RevertWhenTypeMismatch() public {
        // Try to set address value on a string key
        vm.expectRevert();
        data.setAddress(PEGGED_SYMBOL_KEY, address(0x1234));
    }

    function test_RevertWhenReadingUintAsInt() public {
        data.setUint(PEGGED_DECIMALS_KEY, 18);

        // Trying to read a UINT as INT should fail validation
        vm.expectRevert();
        data.getInt(PEGGED_DECIMALS_KEY);
    }

    function test_RevertWhenReadingIntAsUint() public {
        data.setInt(CONFIG_TEMPERATURE_KEY, -273);

        // Trying to read an INT as UINT should fail validation
        vm.expectRevert();
        data.getUint(CONFIG_TEMPERATURE_KEY);
    }

    function test_RevertWhenReadingUintArrayAsIntArray() public {
        uint256[] memory limits = new uint256[](1);
        limits[0] = 100;
        data.setUintArray(CONFIG_LIMITS_KEY, limits);

        vm.expectRevert();
        data.getIntArray(CONFIG_LIMITS_KEY);
    }

    // ============ Nested Address Tests ============

    function test_SetAndGetNestedAddress() public {
        data.setAddress(PEGGED_IMPL_KEY, address(0x9999));
        assertEq(data.getAddress(PEGGED_IMPL_KEY), address(0x9999), "Nested address mismatch");
    }

    function test_ContractVsNestedAddress() public {
        // setAddress() on .address key, get() shorthand reads it
        data.setAddress(PEGGED_ADDRESS_KEY, address(0x1111));
        assertEq(data.get(PEGGED_KEY), address(0x1111), "Contract address mismatch");

        // setAddress() for nested ADDRESS type
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

    // ============ JSON Export Tests ============

    function test_ToJsonIncludesValues() public {
        dataJson.setAddress(PEGGED_ADDRESS_KEY, address(0x1234567890123456789012345678901234567890));
        dataJson.setString(PEGGED_SYMBOL_KEY, "BAO");
        dataJson.setUint(PEGGED_DECIMALS_KEY, 18);

        string memory json = dataJson.toJson();

        // Basic validation - should contain the values
        assertTrue(bytes(json).length > 0, "JSON should not be empty");
    }

    function test_ToJsonNestedStructure() public {
        dataJson.setAddress(PEGGED_IMPL_KEY, address(0xABCD));
        string memory json = dataJson.toJson();

        // Should create nested structure: {"contracts": {"pegged": {"implementation": "0x..."}}}
        address recovered = json.readAddress("$.contracts.pegged.implementation");
        assertEq(recovered, address(0xABCD), "JSON nested address mismatch");
    }

    // ============ JSON Import Tests ============

    function test_FromJsonSingleAddress() public {
        string memory initialJson = '{"owner":"0x0000000000000000000000000000000000001234"}';

        dataJson.fromJson(initialJson);
        assertEq(dataJson.getAddress(OWNER_KEY), address(0x1234));
    }

    function test_FromJsonMultipleKeys() public {
        string
            memory initialJson = '{"owner":"0x0000000000000000000000000000000000001234","contracts":{"pegged":{"address":"0x0000000000000000000000000000000000005678"}}}';

        dataJson.fromJson(initialJson);
        assertEq(dataJson.getAddress(OWNER_KEY), address(0x1234));
        assertEq(dataJson.get(PEGGED_KEY), address(0x5678));
    }

    function test_FromJsonNestedAddress() public {
        string
            memory initialJson = '{"contracts":{"pegged":{"implementation":"0x0000000000000000000000000000000000009999"}}}';

        dataJson.fromJson(initialJson);
        assertEq(dataJson.getAddress(PEGGED_IMPL_KEY), address(0x9999));
    }

    function test_FromJsonString() public {
        string memory initialJson = '{"contracts":{"pegged":{"symbol":"BAO"}}}';

        dataJson.fromJson(initialJson);
        assertEq(dataJson.getString(PEGGED_SYMBOL_KEY), "BAO");
    }

    function test_FromJsonUint() public {
        string memory initialJson = '{"contracts":{"pegged":{"decimals":18}}}';

        dataJson.fromJson(initialJson);
        assertEq(dataJson.getUint(PEGGED_DECIMALS_KEY), 18);
    }

    function test_FromJsonInt() public {
        string memory initialJson = '{"contracts":{"config":{"temperature":-273}}}';

        dataJson.fromJson(initialJson);
        assertEq(dataJson.getInt(CONFIG_TEMPERATURE_KEY), -273);
    }

    function test_FromJsonBool() public {
        string memory initialJson = '{"contracts":{"config":{"enabled":true}}}';

        dataJson.fromJson(initialJson);
        assertTrue(dataJson.getBool(CONFIG_ENABLED_KEY));
    }

    function test_FromJsonAddressArray() public {
        string
            memory initialJson = '{"contracts":{"config":{"validators":["0x0000000000000000000000000000000000001111","0x0000000000000000000000000000000000002222"]}}}';

        dataJson.fromJson(initialJson);
        address[] memory result = dataJson.getAddressArray(CONFIG_VALIDATORS_KEY);
        assertEq(result.length, 2);
        assertEq(result[0], address(0x1111));
        assertEq(result[1], address(0x2222));
    }

    function test_FromJsonStringArray() public {
        string memory initialJson = '{"contracts":{"config":{"tags":["stable","verified"]}}}';

        dataJson.fromJson(initialJson);
        string[] memory result = dataJson.getStringArray(CONFIG_TAGS_KEY);
        assertEq(result.length, 2);
        assertEq(result[0], "stable");
        assertEq(result[1], "verified");
    }

    function test_FromJsonUintArray() public {
        string memory initialJson = '{"contracts":{"config":{"limits":[100,200,300]}}}';

        dataJson.fromJson(initialJson);
        uint256[] memory result = dataJson.getUintArray(CONFIG_LIMITS_KEY);
        assertEq(result.length, 3);
        assertEq(result[0], 100);
        assertEq(result[1], 200);
        assertEq(result[2], 300);
    }

    function test_FromJsonIntArray() public {
        string memory initialJson = '{"contracts":{"config":{"deltas":[-50,0,100]}}}';

        dataJson.fromJson(initialJson);
        int256[] memory result = dataJson.getIntArray(CONFIG_DELTAS_KEY);
        assertEq(result.length, 3);
        assertEq(result[0], -50);
        assertEq(result[1], 0);
        assertEq(result[2], 100);
    }

    // ============ JSON Round-trip Tests ============

    function test_RoundTripAddress() public {
        dataJson.setAddress(PEGGED_ADDRESS_KEY, address(0x1234));
        string memory json = dataJson.toJson();

        DeploymentDataJson dataJson2 = new DeploymentDataJson(keys);
        dataJson2.fromJson(json);

        assertEq(dataJson2.get(PEGGED_KEY), address(0x1234));
    }

    function test_RoundTripNestedAddress() public {
        dataJson.setAddress(PEGGED_IMPL_KEY, address(0xABCD));
        string memory json = dataJson.toJson();

        DeploymentDataJson dataJson2 = new DeploymentDataJson(keys);
        dataJson2.fromJson(json);

        assertEq(dataJson2.getAddress(PEGGED_IMPL_KEY), address(0xABCD));
    }

    function test_RoundTripMultipleTypes() public {
        dataJson.setAddress(PEGGED_ADDRESS_KEY, address(0x1111));
        dataJson.setString(PEGGED_SYMBOL_KEY, "BAO");
        dataJson.setUint(PEGGED_DECIMALS_KEY, 18);
        dataJson.setInt(CONFIG_TEMPERATURE_KEY, -273);
        dataJson.setBool(CONFIG_ENABLED_KEY, true);

        string memory json = dataJson.toJson();

        DeploymentDataJson dataJson2 = new DeploymentDataJson(keys);
        dataJson2.fromJson(json);

        assertEq(dataJson2.get(PEGGED_KEY), address(0x1111));
        assertEq(dataJson2.getString(PEGGED_SYMBOL_KEY), "BAO");
        assertEq(dataJson2.getUint(PEGGED_DECIMALS_KEY), 18);
        assertEq(dataJson2.getInt(CONFIG_TEMPERATURE_KEY), -273);
        assertTrue(dataJson2.getBool(CONFIG_ENABLED_KEY));
    }

    function test_RoundTripArrays() public {
        address[] memory addrs = new address[](2);
        addrs[0] = address(0x1111);
        addrs[1] = address(0x2222);
        dataJson.setAddressArray(CONFIG_VALIDATORS_KEY, addrs);

        string[] memory tags = new string[](2);
        tags[0] = "stable";
        tags[1] = "verified";
        dataJson.setStringArray(CONFIG_TAGS_KEY, tags);

        uint256[] memory limits = new uint256[](3);
        limits[0] = 100;
        limits[1] = 200;
        limits[2] = 300;
        dataJson.setUintArray(CONFIG_LIMITS_KEY, limits);

        int256[] memory deltas = new int256[](3);
        deltas[0] = -50;
        deltas[1] = 0;
        deltas[2] = 100;
        dataJson.setIntArray(CONFIG_DELTAS_KEY, deltas);

        string memory json = dataJson.toJson();

        DeploymentDataJson dataJson2 = new DeploymentDataJson(keys);
        dataJson2.fromJson(json);

        address[] memory addrsResult = dataJson2.getAddressArray(CONFIG_VALIDATORS_KEY);
        assertEq(addrsResult.length, 2);
        assertEq(addrsResult[0], address(0x1111));
        assertEq(addrsResult[1], address(0x2222));

        string[] memory tagsResult = dataJson2.getStringArray(CONFIG_TAGS_KEY);
        assertEq(tagsResult.length, 2);
        assertEq(tagsResult[0], "stable");
        assertEq(tagsResult[1], "verified");

        uint256[] memory limitsResult = dataJson2.getUintArray(CONFIG_LIMITS_KEY);
        assertEq(limitsResult.length, 3);
        assertEq(limitsResult[0], 100);
        assertEq(limitsResult[1], 200);
        assertEq(limitsResult[2], 300);

        int256[] memory deltasResult = dataJson2.getIntArray(CONFIG_DELTAS_KEY);
        assertEq(deltasResult.length, 3);
        assertEq(deltasResult[0], -50);
        assertEq(deltasResult[1], 0);
        assertEq(deltasResult[2], 100);
    }
}
