// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {TestDeployment} from "./TestDeployment.sol";
import {MockUpgradeableContract} from "../mocks/upgradeable/MockGeneric.sol";

// Simple library for testing
library TestMathLib {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        return a + b;
    }
}

// Test harness for round-trip testing
contract RoundTripTestHarness is TestDeployment {
    function deployMockProxy(string memory key, uint256 initialValue, string memory mockName) public returns (address) {
        MockUpgradeableContract impl = new MockUpgradeableContract();
        string memory implKey = string.concat(key, "_impl");
        registerImplementation(implKey, address(impl), "MockUpgradeableContract", "test/MockUpgradeableContract.sol");
        bytes memory initData = abi.encodeCall(
            MockUpgradeableContract.initialize,
            (initialValue, mockName, getMetadata().owner)
        );
        return this.deployProxy(key, implKey, initData);
    }

    function deployMockLibrary(string memory key) public returns (address) {
        bytes memory bytecode = type(TestMathLib).creationCode;
        deployLibrary(key, bytecode, "TestMathLib", "test/TestMathLib.sol");
        return _get(key);
    }
}

/**
 * @title DeploymentJsonRoundTripTest
 * @notice Tests JSON serialization fidelity across complex deployment scenarios
 * @dev Ensures all deployment data survives JSON round-trip conversion
 */
contract DeploymentJsonRoundTripTest is Test {
    RoundTripTestHarness public deployment;

    function setUp() public {
        deployment = new RoundTripTestHarness();
        deployment.start(address(this), "test-network", "v2.1.0", "roundtrip-test-salt");
    }

    function test_ComplexDeploymentRoundTrip() public {
        // Create a complex deployment scenario
        address existingAddr = address(0x1234567890123456789012345678901234567890);
        deployment.useExistingByString("ExistingToken", existingAddr);

        address proxyAddr = deployment.deployMockProxy("TestProxy", 42, "Test Proxy");
        address libAddr = deployment.deployMockLibrary("TestLib");

        // Add parameters
        deployment.setStringByKey("networkName", "Ethereum");
        deployment.setUintByKey("chainId", 1);
        deployment.setIntByKey("offset", -100);
        deployment.setBoolByKey("enabled", true);

        deployment.finish();

        // Serialize to JSON
        string memory json = deployment.toJson();

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        // Create new deployment and deserialize
        RoundTripTestHarness restored = new RoundTripTestHarness();
        restored.fromJson(json);

        // Verify all contracts are preserved
        assertEq(restored.getByString("ExistingToken"), existingAddr, "Existing contract address mismatch");
        assertEq(restored.getByString("TestProxy"), proxyAddr, "Proxy address mismatch");
        assertEq(restored.getByString("TestLib"), libAddr, "Library address mismatch");

        // Verify entry types are preserved
        assertEq(restored.getEntryType("ExistingToken"), "contract", "Existing contract type mismatch");
        assertEq(restored.getEntryType("TestProxy"), "proxy", "Proxy type mismatch");
        assertEq(restored.getEntryType("TestLib"), "library", "Library type mismatch");

        // Verify parameters are preserved
        assertEq(restored.getStringByKey("networkName"), "Ethereum", "String parameter mismatch");
        assertEq(restored.getUintByKey("chainId"), 1, "Uint parameter mismatch");
        assertEq(restored.getIntByKey("offset"), -100, "Int parameter mismatch");
        assertTrue(restored.getBoolByKey("enabled"), "Bool parameter mismatch");

        // Verify metadata is preserved
        assertEq(restored.getMetadata().network, "test-network", "Network metadata mismatch");
        assertEq(restored.getMetadata().version, "v2.1.0", "Version metadata mismatch");
    }

    function test_EmptyDeploymentRoundTrip() public {
        deployment.finish();

        string memory json = deployment.toJson();

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        RoundTripTestHarness restored = new RoundTripTestHarness();
        restored.fromJson(json);

        // Should have metadata but no contracts
        string[] memory keys = restored.keys();
        assertEq(keys.length, 0, "Should have no deployment keys");

        assertEq(restored.getMetadata().network, "test-network", "Network should be preserved");
        assertEq(restored.getMetadata().version, "v2.1.0", "Version should be preserved");
    }

    function test_LargeDeploymentRoundTrip() public {
        // Create a large deployment with many entries
        for (uint256 i = 0; i < 10; i++) {
            string memory key = string(abi.encodePacked("contract", vm.toString(i)));
            address addr = address(uint160(0x1000 + i));
            deployment.useExistingByString(key, addr);
        }

        for (uint256 i = 0; i < 5; i++) {
            string memory key = string(abi.encodePacked("param", vm.toString(i)));
            deployment.setUintByKey(key, i * 100);
        }

        deployment.finish();

        string memory json = deployment.toJson();

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        RoundTripTestHarness restored = new RoundTripTestHarness();
        restored.fromJson(json);

        // Verify all contracts
        for (uint256 i = 0; i < 10; i++) {
            string memory key = string(abi.encodePacked("contract", vm.toString(i)));
            address expected = address(uint160(0x1000 + i));
            assertEq(
                restored.getByString(key),
                expected,
                string(abi.encodePacked("Contract ", vm.toString(i), " mismatch"))
            );
        }

        // Verify all parameters
        for (uint256 i = 0; i < 5; i++) {
            string memory key = string(abi.encodePacked("param", vm.toString(i)));
            assertEq(
                restored.getUintByKey(key),
                i * 100,
                string(abi.encodePacked("Parameter ", vm.toString(i), " mismatch"))
            );
        }

        string[] memory keys = restored.keys();
        assertEq(keys.length, 15, "Should have 15 total entries");
    }

    function test_SpecialCharactersInKeysRoundTrip() public {
        // Test keys with special characters that might break JSON
        deployment.useExistingByString("token-with-dashes", address(0x1111));
        deployment.useExistingByString("token_with_underscores", address(0x2222));
        deployment.useExistingByString("tokenWithCamelCase", address(0x3333));
        deployment.setStringByKey("string-param", "value with spaces");
        deployment.setStringByKey('json"escape', 'value with "quotes"');

        deployment.finish();

        string memory json = deployment.toJson();

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        RoundTripTestHarness restored = new RoundTripTestHarness();
        restored.fromJson(json);

        assertEq(restored.getByString("token-with-dashes"), address(0x1111), "Dashes in key failed");
        assertEq(restored.getByString("token_with_underscores"), address(0x2222), "Underscores in key failed");
        assertEq(restored.getByString("tokenWithCamelCase"), address(0x3333), "CamelCase in key failed");
        assertEq(restored.getStringByKey("string-param"), "value with spaces", "Spaces in value failed");
        assertEq(restored.getStringByKey('json"escape'), 'value with "quotes"', "Quotes in value failed");
    }
}
