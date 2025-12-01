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

    function writeAddress(string memory key, address value) external {
        _writeAddress(key, value, DataType.ADDRESS);
    }

    function writeString(string memory key, string memory value) external {
        _writeString(key, value, DataType.STRING);
    }

    function writeUint(string memory key, uint256 value) external {
        _writeUint(key, value, DataType.UINT);
    }

    function writeInt(string memory key, int256 value) external {
        _writeInt(key, value, DataType.INT);
    }

    function writeBool(string memory key, bool value) external {
        _writeBool(key, value, DataType.BOOL);
    }

    function writeAddressArray(string memory key, address[] memory values) external {
        _writeAddressArray(key, values, DataType.ADDRESS_ARRAY);
    }

    function writeStringArray(string memory key, string[] memory values) external {
        _writeStringArray(key, values, DataType.STRING_ARRAY);
    }

    function writeUintArray(string memory key, uint256[] memory values) external {
        _writeUintArray(key, values, DataType.UINT_ARRAY);
    }

    function writeIntArray(string memory key, int256[] memory values) external {
        _writeIntArray(key, values, DataType.INT_ARRAY);
    }

    function readAddress(string memory key) external view returns (address) {
        return _readAddress(key);
    }

    function readString(string memory key) external view returns (string memory) {
        return _readString(key);
    }

    function readUint(string memory key) external view returns (uint256) {
        return _readUint(key);
    }

    function readInt(string memory key) external view returns (int256) {
        return _readInt(key);
    }

    function readBool(string memory key) external view returns (bool) {
        return _readBool(key);
    }

    function readAddressArray(string memory key) external view returns (address[] memory) {
        return _readAddressArray(key);
    }

    function readStringArray(string memory key) external view returns (string[] memory) {
        return _readStringArray(key);
    }

    function readUintArray(string memory key) external view returns (uint256[] memory) {
        return _readUintArray(key);
    }

    function readIntArray(string memory key) external view returns (int256[] memory) {
        return _readIntArray(key);
    }
}

contract DeploymentDataMemorySetup is BaoTest {
    DeploymentDataMemoryHarness internal data;

    function setUp() public virtual {
        data = new DeploymentDataMemoryHarness();
    }
}

contract DeploymentDataMemoryTest is DeploymentDataMemorySetup {
    function test_WriteAndReadAddress_() public {
        data.writeAddress("contracts.asset.address", address(0xBEEF));
        assertEq(data.readAddress("contracts.asset.address"), address(0xBEEF), "address read matches stored");
    }

    function test_ReadUnsetStringReverts_() public {
        string memory key = "config.name";
        vm.expectRevert(abi.encodeWithSelector(DeploymentDataMemory.ValueNotSet.selector, key));
        data.readString(key);
    }

    function test_ReadTypeMismatchReverts_() public {
        string memory key = "config.limit";
        data.writeUint(key, 99);
        vm.expectRevert(
            abi.encodeWithSelector(DeploymentDataMemory.ReadTypeMismatch.selector, key, DataType.INT, DataType.UINT)
        );
        data.readInt(key);
    }

    function test_HasRecognizesObjectChild_() public {
        assertEq(data.has("contracts.asset"), false, "object has should be false before child set");
        data.writeAddress("contracts.asset.address", address(this));
        assertEq(data.has("contracts.asset"), true, "object has should be true after child set");
    }

    function test_KeysDoNotDuplicateOnOverwrite_() public {
        data.writeString("config.name", "first");
        data.writeString("config.name", "second");

        string[] memory keysList = data.keys();
        assertEq(keysList.length, 1, "keys array should not duplicate entries");
        assertEq(keysList[0], "config.name", "keys array should track the expected key");
    }

    function test_AddressArrayOverwriteShrinksLength_() public {
        address[] memory first = new address[](2);
        first[0] = address(0xCAFE);
        first[1] = address(0xF00D);
        data.writeAddressArray("config.validators", first);

        address[] memory second = new address[](1);
        second[0] = address(0x1234);
        data.writeAddressArray("config.validators", second);

        address[] memory stored = data.readAddressArray("config.validators");
        assertEq(stored.length, 1, "address array overwrite should drop stale entries");
        assertEq(stored[0], address(0x1234), "address array overwrite should keep new entry");
    }

    function test_StringArrayOverwriteClearsStaleValues_() public {
        string[] memory first = new string[](2);
        first[0] = "alpha";
        first[1] = "beta";
        data.writeStringArray("config.tags", first);

        string[] memory second = new string[](1);
        second[0] = "latest";
        data.writeStringArray("config.tags", second);

        string[] memory stored = data.readStringArray("config.tags");
        assertEq(stored.length, 1, "string array overwrite should drop stale entries");
        assertEq(stored[0], "latest", "string array overwrite should keep new entry");
    }

    function test_UintArrayReadWrite_() public {
        uint256[] memory values = new uint256[](3);
        values[0] = 1;
        values[1] = 2;
        values[2] = 3;
        data.writeUintArray("config.limits", values);

        uint256[] memory stored = data.readUintArray("config.limits");
        assertEq(stored.length, 3, "uint array length should match writes");
        assertEq(stored[2], 3, "uint array value should persist");
    }

    function test_IntArrayReadWrite_() public {
        int256[] memory values = new int256[](2);
        values[0] = -5;
        values[1] = 42;
        data.writeIntArray("config.deltas", values);

        int256[] memory stored = data.readIntArray("config.deltas");
        assertEq(stored.length, 2, "int array length should match writes");
        assertEq(stored[0], -5, "int array value should persist");
    }

    function test_BoolReadWrite_() public {
        data.writeBool("config.enabled", true);
        assertEq(data.readBool("config.enabled"), true, "bool setter should persist value");
    }
}
