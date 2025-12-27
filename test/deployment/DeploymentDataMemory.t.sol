// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {DeploymentDataMemory} from "@bao-script/deployment/DeploymentDataMemory.sol";
import {DataType} from "@bao-script/deployment/DeploymentKeys.sol";

contract DeploymentDataMemoryHarness is DeploymentDataMemory {
    constructor() {
        addContract("contracts.asset");
        addKey("config");
        addStringKey("config.name");
        addUintKey("config.limit");
        addIntKey("config.delta");
        addBoolKey("config.enabled");
        addAddressArrayKey("config.validators");
        addStringArrayKey("config.tags");
        addUintArrayKey("config.limits");
        addIntArrayKey("config.deltas");
    }

    function setAddress(string memory key, address value) external {
        _setAddress(key, value);
    }

    function setString(string memory key, string memory value) external {
        _setString(key, value);
    }

    function setUint(string memory key, uint256 value) external {
        _setUint(key, value);
    }

    function setInt(string memory key, int256 value) external {
        _setInt(key, value);
    }

    function setBool(string memory key, bool value) external {
        _setBool(key, value);
    }

    function setAddressArray(string memory key, address[] memory values) external {
        _setAddressArray(key, values);
    }

    function setStringArray(string memory key, string[] memory values) external {
        _setStringArray(key, values);
    }

    function setUintArray(string memory key, uint256[] memory values) external {
        _setUintArray(key, values);
    }

    function setIntArray(string memory key, int256[] memory values) external {
        _setIntArray(key, values);
    }

    function _afterValueChanged(string memory key) internal override {}

    function _save() internal override {}
}

contract DeploymentDataMemorySetup is BaoTest {
    DeploymentDataMemoryHarness internal data;

    function setUp() public virtual {
        data = new DeploymentDataMemoryHarness();
    }
}

contract DeploymentDataMemoryTest is DeploymentDataMemorySetup {
    function test_WriteAndReadAddress_() public {
        data.setAddress("contracts.asset.address", address(0xBEEF));
        assertEq(data.getAddress("contracts.asset.address"), address(0xBEEF), "address read matches stored");
    }

    function test_ReadUnsetStringReverts_() public {
        string memory key = "config.name";
        vm.expectRevert(abi.encodeWithSelector(DeploymentDataMemory.ValueNotSet.selector, key));
        data.getString(key);
    }

    function test_ReadTypeMismatchReverts_() public {
        string memory key = "config.limit";
        data.setUint(key, 99);
        vm.expectRevert(
            abi.encodeWithSelector(DeploymentDataMemory.ReadTypeMismatch.selector, key, DataType.INT, DataType.UINT)
        );
        data.getInt(key);
    }

    function test_HasRecognizesObjectChild_() public {
        assertEq(data.has("contracts.asset"), false, "object has should be false before child set");
        data.setAddress("contracts.asset.address", address(this));
        assertEq(data.has("contracts.asset"), true, "object has should be true after child set");
    }

    function test_KeysDoNotDuplicateOnOverwrite_() public {
        data.setString("config.name", "first");
        data.setString("config.name", "second");

        string[] memory keysList = data.keys();
        assertEq(keysList.length, 1, "keys array should not duplicate entries");
        assertEq(keysList[0], "config.name", "keys array should track the expected key");
    }

    function test_AddressArrayOverwriteShrinksLength_() public {
        address[] memory first = new address[](2);
        first[0] = address(0xCAFE);
        first[1] = address(0xF00D);
        data.setAddressArray("config.validators", first);

        address[] memory second = new address[](1);
        second[0] = address(0x1234);
        data.setAddressArray("config.validators", second);

        address[] memory stored = data.getAddressArray("config.validators");
        assertEq(stored.length, 1, "address array overwrite should drop stale entries");
        assertEq(stored[0], address(0x1234), "address array overwrite should keep new entry");
    }

    function test_StringArrayOverwriteClearsStaleValues_() public {
        string[] memory first = new string[](2);
        first[0] = "alpha";
        first[1] = "beta";
        data.setStringArray("config.tags", first);

        string[] memory second = new string[](1);
        second[0] = "latest";
        data.setStringArray("config.tags", second);

        string[] memory stored = data.getStringArray("config.tags");
        assertEq(stored.length, 1, "string array overwrite should drop stale entries");
        assertEq(stored[0], "latest", "string array overwrite should keep new entry");
    }

    function test_UintArrayReadWrite_() public {
        uint256[] memory values = new uint256[](3);
        values[0] = 1;
        values[1] = 2;
        values[2] = 3;
        data.setUintArray("config.limits", values);

        uint256[] memory stored = data.getUintArray("config.limits");
        assertEq(stored.length, 3, "uint array length should match writes");
        assertEq(stored[2], 3, "uint array value should persist");
    }

    function test_IntArrayReadWrite_() public {
        int256[] memory values = new int256[](2);
        values[0] = -5;
        values[1] = 42;
        data.setIntArray("config.deltas", values);

        int256[] memory stored = data.getIntArray("config.deltas");
        assertEq(stored.length, 2, "int array length should match writes");
        assertEq(stored[0], -5, "int array value should persist");
    }

    function test_BoolReadWrite_() public {
        data.setBool("config.enabled", true);
        assertEq(data.getBool("config.enabled"), true, "bool setter should persist value");
    }
}
