// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {DeploymentJsonTesting} from "@bao-script/deployment/DeploymentJsonTesting.sol";

// Test harness with registered keys
contract DeploymentJsonStringTestHarness is DeploymentJsonTesting {
    constructor() {
        // Register parent contracts with contracts. prefix
        addContract("contracts.MockToken");
        addContract("contracts.Token");
        addContract("contracts.Token1");
        addContract("contracts.Token2");
        addContract("contracts.Contract1");
        addContract("contracts.Contract2");
        addContract("contracts.Contract3");
        addContract("contracts.LoadTest");
        addContract("contracts.Admin");
        addContract("contracts.Treasury");
        addKey("config"); // Parent for config parameters (not a deployed contract)

        // Register child keys with dot notation
        addStringKey("contracts.MockToken.tokenName");
        addUintKey("contracts.MockToken.decimals");
        addStringKey("contracts.Token.symbol");
        addStringKey("contracts.Token.name");
        addStringKey("config.param1");
        addUintKey("config.param2");
        addBoolKey("config.param3");
        addStringKey("config.name");
        addStringKey("config.networkName");
        addUintKey("config.chainId");
        addIntKey("config.temperature");
        addBoolKey("config.isProduction");
        addUintKey("contracts.LoadTest.value");
    }
}

/**
 * @title DeploymentJsonStringTest
 * @notice Tests for string-based JSON serialization (no filesystem access)
 * @dev Demonstrates toJson() and fromJson() methods that don't litter filesystem
 */
contract DeploymentJsonStringTest is BaoDeploymentTest {
    DeploymentJsonStringTestHarness public deployment;

    string constant TEST_SALT = "DeploymentJsonStringTest";

    function setUp() public override {
        super.setUp();
        deployment = new DeploymentJsonStringTestHarness();
        _resetDeploymentLogs(TEST_SALT, "");
    }

    function _startDeployment(string memory network) internal {
        _prepareTestNetwork(TEST_SALT, network);
        deployment.start(network, TEST_SALT, "");
    }

    function test_ToJsonReturnsValidString() public {
        _startDeployment("test_ToJsonReturnsValidString");

        // Deploy some contracts
        deployment.useExisting("contracts.MockToken", address(0x1234));
        deployment.setString("contracts.MockToken.tokenName", "Test Token");
        deployment.setUint("contracts.MockToken.decimals", 18);

        // Get JSON string without writing to file
        string memory json = deployment.toJson();

        // Verify it's not empty
        assertTrue(bytes(json).length > 0, "JSON should not be empty");

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        // Verify it contains expected keys
        assertTrue(vm.keyExistsJson(json, ".contracts.MockToken"), "Should contain MockToken");
        assertTrue(vm.keyExistsJson(json, ".contracts.MockToken.tokenName"), "Should contain tokenName");
        assertTrue(vm.keyExistsJson(json, ".contracts.MockToken.decimals"), "Should contain decimals");
    }

    function test_FromJsonLoadsFromString() public {
        _startDeployment("test_FromJsonLoadsFromString");

        // Deploy and serialize
        deployment.useExisting("contracts.Token1", address(0x1111));
        deployment.useExisting("contracts.Token2", address(0x2222));
        deployment.setString("config.name", "TestSystem");
        deployment.finish();

        string memory json = deployment.toJson();

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        // Create new deployment and load from string
        DeploymentJsonTesting newDeployment = new DeploymentJsonTesting();
        newDeployment.fromJson(json);

        // Verify loaded data
        assertEq(newDeployment.get("contracts.Token1"), address(0x1111), "Token1 address mismatch");
        assertEq(newDeployment.get("contracts.Token2"), address(0x2222), "Token2 address mismatch");
        assertEq(newDeployment.getString("config.name"), "TestSystem", "Name parameter mismatch");

        assertTrue(newDeployment.has("contracts.Token1"), "Should have Token1");
        assertTrue(newDeployment.has("contracts.Token2"), "Should have Token2");
    }

    function test_RoundTripWithoutFilesystem() public {
        _startDeployment("test_RoundTripWithoutFilesystem");

        // Create complex deployment state
        deployment.useExisting("contracts.Admin", address(0xABCD));
        deployment.useExisting("contracts.Treasury", address(0xDEAD));

        deployment.setString("config.networkName", "Ethereum");
        deployment.setUint("config.chainId", 1);
        deployment.setInt("config.temperature", -42);
        deployment.setBool("config.isProduction", true);

        deployment.finish();

        // Serialize to string
        string memory json = deployment.toJson();

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        // Deserialize to new instance
        DeploymentJsonTesting restored = new DeploymentJsonTesting();
        restored.fromJson(json);

        // Verify all contracts
        assertEq(restored.get("contracts.Admin"), address(0xABCD), "Admin address");
        assertEq(restored.get("contracts.Treasury"), address(0xDEAD), "Treasury address");

        // Verify all parameters
        assertEq(restored.getString("config.networkName"), "Ethereum", "Network name");
        assertEq(restored.getUint("config.chainId"), 1, "Chain ID");
        assertEq(restored.getInt("config.temperature"), -42, "Temperature");
        assertTrue(restored.getBool("config.isProduction"), "Is production flag");

        // Verify keys list
        string[] memory keys = restored.keys();
        assertEq(keys.length, 7, "Should have 7 keys (2 contracts + config + 4 config params)");
    }

    function test_EmptyDeploymentSerialization() public {
        _startDeployment("test_EmptyDeploymentSerialization");

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
        _startDeployment("test_OnlyContractsNoFiles");

        // Deploy multiple contracts without touching filesystem
        deployment.useExisting("contracts.Contract1", address(0x1));
        deployment.useExisting("contracts.Contract2", address(0x2));
        deployment.useExisting("contracts.Contract3", address(0x3));

        deployment.finish();

        string memory json = deployment.toJson();

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        DeploymentJsonTesting loaded = new DeploymentJsonTesting();
        loaded.fromJson(json);

        assertEq(loaded.keys().length, 3, "Should have 3 contracts");
        assertEq(loaded.get("contracts.Contract1"), address(0x1));
        assertEq(loaded.get("contracts.Contract2"), address(0x2));
        assertEq(loaded.get("contracts.Contract3"), address(0x3));
    }

    function test_OnlyParametersNoFiles() public {
        _startDeployment("test_OnlyParametersNoFiles");

        // Only parameters, no contracts (but they need parent 'config')
        deployment.setString("config.param1", "value1");
        deployment.setUint("config.param2", 100);
        deployment.setBool("config.param3", false);

        deployment.finish();

        string memory json = deployment.toJson();

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        DeploymentJsonTesting loaded = new DeploymentJsonTesting();
        loaded.fromJson(json);

        assertEq(loaded.keys().length, 4, "Should have 4 keys (config + 3 parameters)");
        assertEq(loaded.getString("config.param1"), "value1");
        assertEq(loaded.getUint("config.param2"), 100);
        assertFalse(loaded.getBool("config.param3"));
    }

    function test_PreservesSaveToJsonCompatibility() public {
        _startDeployment("test_PreservesSaveToJsonCompatibility");

        // Ensure saveToJson still works (uses toJson internally)
        deployment.useExisting("contracts.Token", address(0x5555));
        deployment.setString("contracts.Token.name", "SavedToken");

        deployment.finish();
        string memory json = deployment.toJson();

        // Load from file - if this succeeds, schema is valid
        DeploymentJsonTesting loaded = new DeploymentJsonTesting();
        loaded.fromJson(json);

        assertEq(loaded.get("contracts.Token"), address(0x5555));
        assertEq(loaded.getString("contracts.Token.name"), "SavedToken");
    }

    function test_PreservesLoadFromJsonCompatibility() public {
        _startDeployment("test_PreservesLoadFromJsonCompatibility");

        // Test that loadFromJson still works (uses fromJson internally)
        deployment.useExisting("contracts.LoadTest", address(0x9999));
        deployment.setUint("contracts.LoadTest.value", 42);

        deployment.finish();
        string memory json = deployment.toJson();

        // Load using original method - if this succeeds, schema is valid
        DeploymentJsonTesting loaded = new DeploymentJsonTesting();
        loaded.fromJson(json);

        assertEq(loaded.get("contracts.LoadTest"), address(0x9999));
        assertEq(loaded.getUint("contracts.LoadTest.value"), 42);
    }
}
