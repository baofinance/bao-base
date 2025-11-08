// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {MockDeployment} from "./MockDeployment.sol";
import {MockUpgradeableContract} from "../mocks/upgradeable/MockGeneric.sol";

// Simple library for testing
library TestMathLib {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        return a + b;
    }
}

// Test harness for round-trip testing
contract MockDeploymentRoundTrip is MockDeployment {
    function deployMockProxy(string memory key, uint256 initialValue, string memory mockName) public returns (address) {
        MockUpgradeableContract impl = new MockUpgradeableContract();
        string memory implKey = string.concat(key, "_impl");
        registerImplementation(implKey, address(impl), "MockUpgradeableContract", "test/MockUpgradeableContract.sol");
        bytes memory initData = abi.encodeCall(
            MockUpgradeableContract.initialize,
            (initialValue, mockName, _metadata.owner)
        );
        return this.deployProxy(key, implKey, initData);
    }

    function deployMockLibrary(string memory key) public returns (address) {
        bytes memory bytecode = type(TestMathLib).creationCode;
        deployLibrary(key, bytecode, "TestMathLib", "test/TestMathLib.sol");
        return get(key);
    }
}

/**
 * @title DeploymentJsonRoundTripTest
 * @notice Tests JSON serialization fidelity across complex deployment scenarios
 * @dev Ensures all deployment data survives JSON round-trip conversion
 */
contract DeploymentJsonRoundTripTest is BaoDeploymentTest {
    MockDeploymentRoundTrip public deployment;
    string constant TEST_NETWORK = "test-network";
    string constant TEST_SALT = "roundtrip-test-salt";
    string constant TEST_VERSION = "v2.1.0";

    function setUp() public override {
        super.setUp();
        deployment = new MockDeploymentRoundTrip();
        deployment.start(address(this), TEST_NETWORK, TEST_VERSION, TEST_SALT);
    }

    function test_ComplexDeploymentRoundTrip() public {
        // Create a complex deployment scenario
        address existingAddr = address(0x1234567890123456789012345678901234567890);
        deployment.useExisting("ExistingToken", existingAddr);

        address proxyAddr = deployment.deployMockProxy("TestProxy", 42, "Test Proxy");
        address libAddr = deployment.deployMockLibrary("TestLib");

        // Add parameters
        deployment.setString("networkName", "Ethereum");
        deployment.setUint("chainId", 1);
        deployment.setInt("offset", -100);
        deployment.setBool("enabled", true);

        deployment.finish();

        // Serialize to JSON
        string memory json = deployment.toJsonString();

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        // Create new deployment and deserialize
        MockDeploymentRoundTrip restored = new MockDeploymentRoundTrip();
        restored.fromJsonString(json);

        // Verify all contracts are preserved
        assertEq(restored.get("ExistingToken"), existingAddr, "Existing contract address mismatch");
        assertEq(restored.get("TestProxy"), proxyAddr, "Proxy address mismatch");
        assertEq(restored.get("TestLib"), libAddr, "Library address mismatch");

        // Verify entry types are preserved
        assertEq(restored.getType("ExistingToken"), "contract", "Existing contract type mismatch");
        assertEq(restored.getType("TestProxy"), "proxy", "Proxy type mismatch");
        assertEq(restored.getType("TestLib"), "library", "Library type mismatch");

        // Verify parameters are preserved
        assertEq(restored.getString("networkName"), "Ethereum", "String parameter mismatch");
        assertEq(restored.getUint("chainId"), 1, "Uint parameter mismatch");
        assertEq(restored.getInt("offset"), -100, "Int parameter mismatch");
        assertTrue(restored.getBool("enabled"), "Bool parameter mismatch");

        // Verify metadata is preserved
        assertEq(restored.getMetadata().network, TEST_NETWORK, "Network metadata mismatch");
        assertEq(restored.getMetadata().version, TEST_VERSION, "Version metadata mismatch");
    }

    function test_EmptyDeploymentRoundTrip() public {
        deployment.finish();

        string memory json = deployment.toJsonString();

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        MockDeploymentRoundTrip restored = new MockDeploymentRoundTrip();
        restored.fromJsonString(json);

        // Should have metadata but no contracts
        string[] memory keys = restored.keys();
        assertEq(keys.length, 0, "Should have no deployment keys");

        assertEq(restored.getMetadata().network, TEST_NETWORK, "Network should be preserved");
        assertEq(restored.getMetadata().version, TEST_VERSION, "Version should be preserved");
    }

    function test_LargeDeploymentRoundTrip() public {
        // Create a large deployment with many entries
        for (uint256 i = 0; i < 10; i++) {
            string memory key = string(abi.encodePacked("contract", vm.toString(i)));
            address addr = address(uint160(0x1000 + i));
            deployment.useExisting(key, addr);
        }

        for (uint256 i = 0; i < 5; i++) {
            string memory key = string(abi.encodePacked("param", vm.toString(i)));
            deployment.setUint(key, i * 100);
        }

        deployment.finish();

        string memory json = deployment.toJsonString();

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        MockDeploymentRoundTrip restored = new MockDeploymentRoundTrip();
        restored.fromJsonString(json);

        // Verify all contracts
        for (uint256 i = 0; i < 10; i++) {
            string memory key = string(abi.encodePacked("contract", vm.toString(i)));
            address expected = address(uint160(0x1000 + i));
            assertEq(restored.get(key), expected, string(abi.encodePacked("Contract ", vm.toString(i), " mismatch")));
        }

        // Verify all parameters
        for (uint256 i = 0; i < 5; i++) {
            string memory key = string(abi.encodePacked("param", vm.toString(i)));
            assertEq(
                restored.getUint(key),
                i * 100,
                string(abi.encodePacked("Parameter ", vm.toString(i), " mismatch"))
            );
        }

        string[] memory keys = restored.keys();
        assertEq(keys.length, 15, "Should have 15 total entries");
    }

    function test_SpecialCharactersInKeysRoundTrip() public {
        // Test keys with special characters that might break JSON
        deployment.useExisting("token-with-dashes", address(0x1111));
        deployment.useExisting("token_with_underscores", address(0x2222));
        deployment.useExisting("tokenWithCamelCase", address(0x3333));
        deployment.setString("string-param", "value with spaces");
        deployment.setString('json"escape', 'value with "quotes"');

        deployment.finish();

        string memory json = deployment.toJsonString();

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        MockDeploymentRoundTrip restored = new MockDeploymentRoundTrip();
        restored.fromJsonString(json);

        assertEq(restored.get("token-with-dashes"), address(0x1111), "Dashes in key failed");
        assertEq(restored.get("token_with_underscores"), address(0x2222), "Underscores in key failed");
        assertEq(restored.get("tokenWithCamelCase"), address(0x3333), "CamelCase in key failed");
        assertEq(restored.getString("string-param"), "value with spaces", "Spaces in value failed");
        assertEq(restored.getString('json"escape'), 'value with "quotes"', "Quotes in value failed");
    }
}
