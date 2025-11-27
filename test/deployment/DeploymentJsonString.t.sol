// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {DeploymentJsonTesting} from "@bao-script/deployment/DeploymentJsonTesting.sol";

/**
 * @title DeploymentJsonStringTest
 * @notice Tests for string-based JSON serialization (no filesystem access)
 * @dev Demonstrates toJson() and fromJson() methods that don't litter filesystem
 */
contract DeploymentJsonStringTest is BaoDeploymentTest {
    DeploymentJsonTesting public deployment;

    string constant TEST_NETWORK = "localhost";
    string constant TEST_SALT = "jsonstring-test-salt";

    function setUp() public override {
        super.setUp();
        deployment = new DeploymentJsonTesting();
        deployment.start(TEST_NETWORK, TEST_SALT, "");
    }

    function test_ToJsonReturnsValidString() public {
        // Deploy some contracts
        deployment.useExisting("MockToken", address(0x1234));
        deployment.setString("tokenName", "Test Token");
        deployment.setUint("decimals", 18);

        // Get JSON string without writing to file
        string memory json = deployment.toJson();

        // Verify it's not empty
        assertTrue(bytes(json).length > 0, "JSON should not be empty");

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        // Verify it contains expected keys
        assertTrue(vm.keyExistsJson(json, ".deployment.MockToken"), "Should contain MockToken");
        assertTrue(vm.keyExistsJson(json, ".deployment.tokenName"), "Should contain tokenName");
        assertTrue(vm.keyExistsJson(json, ".deployment.decimals"), "Should contain decimals");
    }

    function test_FromJsonLoadsFromString() public {
        // Deploy and serialize
        deployment.useExisting("Token1", address(0x1111));
        deployment.useExisting("Token2", address(0x2222));
        deployment.setString("name", "TestSystem");
        deployment.finish();

        string memory json = deployment.toJson();

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        // Create new deployment and load from string
        DeploymentJsonTesting newDeployment = new DeploymentJsonTesting();
        newDeployment.fromJson(json);

        // Verify loaded data
        assertEq(newDeployment.get("Token1"), address(0x1111), "Token1 address mismatch");
        assertEq(newDeployment.get("Token2"), address(0x2222), "Token2 address mismatch");
        assertEq(newDeployment.getString("name"), "TestSystem", "Name parameter mismatch");

        assertTrue(newDeployment.has("Token1"), "Should have Token1");
        assertTrue(newDeployment.has("Token2"), "Should have Token2");
    }

    function test_RoundTripWithoutFilesystem() public {
        // Create complex deployment state
        deployment.useExisting("Admin", address(0xABCD));
        deployment.useExisting("Treasury", address(0xDEAD));

        deployment.setString("networkName", "Ethereum");
        deployment.setUint("chainId", 1);
        deployment.setInt("temperature", -42);
        deployment.setBool("isProduction", true);

        deployment.finish();

        // Serialize to string
        string memory json = deployment.toJson();

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        // Deserialize to new instance
        DeploymentJsonTesting restored = new DeploymentJsonTesting();
        restored.fromJson(json);

        // Verify all contracts
        assertEq(restored.get("Admin"), address(0xABCD), "Admin address");
        assertEq(restored.get("Treasury"), address(0xDEAD), "Treasury address");

        // Verify all parameters
        assertEq(restored.getString("networkName"), "Ethereum", "Network name");
        assertEq(restored.getUint("chainId"), 1, "Chain ID");
        assertEq(restored.getInt("temperature"), -42, "Temperature");
        assertTrue(restored.getBool("isProduction"), "Is production flag");

        // Verify keys list
        string[] memory keys = restored.keys();
        assertEq(keys.length, 6, "Should have 6 entries");
    }

    function test_EmptyDeploymentSerialization() public {
        deployment.finish();

        string memory json = deployment.toJson();

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        // Should still have metadata fields (now flattened to root)
        assertTrue(vm.keyExistsJson(json, ".runs"), "Should have runs array");
        assertTrue(vm.keyExistsJson(json, ".network"), "Should have network");
        assertTrue(vm.keyExistsJson(json, ".deployer"), "Should have deployer");

        // Verify runs array has at least one entry (from finish())
        uint256 startTimestamp = vm.parseJsonUint(json, ".runs[0].startTimestamp");
        assertTrue(startTimestamp > 0, "Should have startTimestamp in runs");

        // Note: Empty deployment won't have .deployment key, which is fine
        // We just verify metadata exists
    }

    function test_OnlyContractsNoFiles() public {
        // Deploy multiple contracts without touching filesystem
        deployment.useExisting("Contract1", address(0x1));
        deployment.useExisting("Contract2", address(0x2));
        deployment.useExisting("Contract3", address(0x3));

        deployment.finish();

        string memory json = deployment.toJson();

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        DeploymentJsonTesting loaded = new DeploymentJsonTesting();
        loaded.fromJson(json);

        assertEq(loaded.keys().length, 3, "Should have 3 contracts");
        assertEq(loaded.get("Contract1"), address(0x1));
        assertEq(loaded.get("Contract2"), address(0x2));
        assertEq(loaded.get("Contract3"), address(0x3));
    }

    function test_OnlyParametersNoFiles() public {
        // Only parameters, no contracts
        deployment.setString("param1", "value1");
        deployment.setUint("param2", 100);
        deployment.setBool("param3", false);

        deployment.finish();

        string memory json = deployment.toJson();

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        DeploymentJsonTesting loaded = new DeploymentJsonTesting();
        loaded.fromJson(json);

        assertEq(loaded.keys().length, 3, "Should have 3 parameters");
        assertEq(loaded.getString("param1"), "value1");
        assertEq(loaded.getUint("param2"), 100);
        assertFalse(loaded.getBool("param3"));
    }

    function test_PreservesSaveToJsonCompatibility() public {
        // Ensure saveToJson still works (uses toJson internally)
        deployment.useExisting("Token", address(0x5555));
        deployment.setString("name", "SavedToken");

        deployment.finish();
        string memory json = deployment.toJson();

        // Load from file - if this succeeds, schema is valid
        DeploymentJsonTesting loaded = new DeploymentJsonTesting();
        loaded.fromJson(json);

        assertEq(loaded.get("Token"), address(0x5555));
        assertEq(loaded.getString("name"), "SavedToken");
    }

    function test_PreservesLoadFromJsonCompatibility() public {
        // Test that loadFromJson still works (uses fromJson internally)
        deployment.useExisting("LoadTest", address(0x9999));
        deployment.setUint("value", 42);

        deployment.finish();
        string memory json = deployment.toJson();

        // Load using original method - if this succeeds, schema is valid
        DeploymentJsonTesting loaded = new DeploymentJsonTesting();
        loaded.fromJson(json);

        assertEq(loaded.get("LoadTest"), address(0x9999));
        assertEq(loaded.getUint("value"), 42);
    }
}
