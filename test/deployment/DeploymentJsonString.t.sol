// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {TestDeployment} from "./TestDeployment.sol";
import {UUPSProxyDeployStub} from "@bao-script/deployment/UUPSProxyDeployStub.sol";

/**
 * @title DeploymentJsonStringTest
 * @notice Tests for string-based JSON serialization (no filesystem access)
 * @dev Demonstrates toJson() and fromJson() methods that don't litter filesystem
 */
contract DeploymentJsonStringTest is Test {
    TestDeployment public deployment;
    UUPSProxyDeployStub internal stub;

    function setUp() public {
        deployment = new TestDeployment();
        stub = UUPSProxyDeployStub(deployment.getDeployStub());
        deployment.startDeployment(address(this), "localhost", "1.0.0", "jsonstring-test-salt");
    }

    function test_ToJsonReturnsValidString() public {
        // Deploy some contracts
        deployment.useExistingByString("MockToken", address(0x1234));
        deployment.setStringByKey("tokenName", "Test Token");
        deployment.setUintByKey("decimals", 18);

        // Get JSON string without writing to file
        string memory json = deployment.toJson();

        // Verify it's not empty
        assertTrue(bytes(json).length > 0, "JSON should not be empty");

        // Verify it contains expected keys
        assertTrue(vm.keyExistsJson(json, ".deployment.MockToken"), "Should contain MockToken");
        assertTrue(vm.keyExistsJson(json, ".deployment.tokenName"), "Should contain tokenName");
        assertTrue(vm.keyExistsJson(json, ".deployment.decimals"), "Should contain decimals");
    }

    function test_FromJsonLoadsFromString() public {
        // Deploy and serialize
        deployment.useExistingByString("Token1", address(0x1111));
        deployment.useExistingByString("Token2", address(0x2222));
        deployment.setStringByKey("name", "TestSystem");
        deployment.finishDeployment();

        string memory json = deployment.toJson();

        // Create new deployment and load from string
        TestDeployment newDeployment = new TestDeployment();
        stub.setDeployer(address(newDeployment));
        newDeployment.fromJson(json);

        // Verify loaded data
        assertEq(newDeployment.getByString("Token1"), address(0x1111), "Token1 address mismatch");
        assertEq(newDeployment.getByString("Token2"), address(0x2222), "Token2 address mismatch");
        assertEq(newDeployment.getStringByKey("name"), "TestSystem", "Name parameter mismatch");

        assertTrue(newDeployment.hasByString("Token1"), "Should have Token1");
        assertTrue(newDeployment.hasByString("Token2"), "Should have Token2");
    }

    function test_RoundTripWithoutFilesystem() public {
        // Create complex deployment state
        deployment.useExistingByString("Admin", address(0xABCD));
        deployment.useExistingByString("Treasury", address(0xDEAD));

        deployment.setStringByKey("networkName", "Ethereum");
        deployment.setUintByKey("chainId", 1);
        deployment.setIntByKey("temperature", -42);
        deployment.setBoolByKey("isProduction", true);

        deployment.finishDeployment();

        // Serialize to string
        string memory json = deployment.toJson();

        // Deserialize to new instance
        TestDeployment restored = new TestDeployment();
        stub.setDeployer(address(restored));
        restored.fromJson(json);

        // Verify all contracts
        assertEq(restored.getByString("Admin"), address(0xABCD), "Admin address");
        assertEq(restored.getByString("Treasury"), address(0xDEAD), "Treasury address");

        // Verify all parameters
        assertEq(restored.getStringByKey("networkName"), "Ethereum", "Network name");
        assertEq(restored.getUintByKey("chainId"), 1, "Chain ID");
        assertEq(restored.getIntByKey("temperature"), -42, "Temperature");
        assertTrue(restored.getBoolByKey("isProduction"), "Is production flag");

        // Verify keys list
        string[] memory keys = restored.keys();
        assertEq(keys.length, 6, "Should have 6 entries");
    }

    function test_EmptyDeploymentSerialization() public {
        deployment.finishDeployment();

        string memory json = deployment.toJson();

        // Should still have metadata
        assertTrue(vm.keyExistsJson(json, ".metadata"), "Should have metadata");
        assertTrue(vm.keyExistsJson(json, ".deployer"), "Should have deployer");

        // Note: Empty deployment won't have .deployment key, which is fine
        // We just verify metadata exists
    }

    function test_OnlyContractsNoFiles() public {
        // Deploy multiple contracts without touching filesystem
        deployment.useExistingByString("Contract1", address(0x1));
        deployment.useExistingByString("Contract2", address(0x2));
        deployment.useExistingByString("Contract3", address(0x3));

        deployment.finishDeployment();

        string memory json = deployment.toJson();

        TestDeployment loaded = new TestDeployment();
        stub.setDeployer(address(loaded));
        loaded.fromJson(json);

        assertEq(loaded.keys().length, 3, "Should have 3 contracts");
        assertEq(loaded.getByString("Contract1"), address(0x1));
        assertEq(loaded.getByString("Contract2"), address(0x2));
        assertEq(loaded.getByString("Contract3"), address(0x3));
    }

    function test_OnlyParametersNoFiles() public {
        // Only parameters, no contracts
        deployment.setStringByKey("param1", "value1");
        deployment.setUintByKey("param2", 100);
        deployment.setBoolByKey("param3", false);

        deployment.finishDeployment();

        string memory json = deployment.toJson();

        TestDeployment loaded = new TestDeployment();
        stub.setDeployer(address(loaded));
        loaded.fromJson(json);

        assertEq(loaded.keys().length, 3, "Should have 3 parameters");
        assertEq(loaded.getStringByKey("param1"), "value1");
        assertEq(loaded.getUintByKey("param2"), 100);
        assertFalse(loaded.getBoolByKey("param3"));
    }

    function test_PreservesSaveToJsonCompatibility() public {
        // Ensure saveToJson still works (uses toJson internally)
        deployment.useExistingByString("Token", address(0x5555));
        deployment.setStringByKey("name", "SavedToken");

        string memory path = "results/deployments/json-compat-test.json";
        vm.createDir("results/deployments", true);

        deployment.finishDeployment();
        deployment.saveToJson(path);

        // Load from file
        TestDeployment loaded = new TestDeployment();
        stub.setDeployer(address(loaded));
        loaded.loadFromJson(path);

        assertEq(loaded.getByString("Token"), address(0x5555));
        assertEq(loaded.getStringByKey("name"), "SavedToken");

        // Cleanup
        vm.removeFile(path);
    }

    function test_PreservesLoadFromJsonCompatibility() public {
        // Test that loadFromJson still works (uses fromJson internally)
        deployment.useExistingByString("LoadTest", address(0x9999));
        deployment.setUintByKey("value", 42);

        string memory path = "results/deployments/load-compat-test.json";
        vm.createDir("results/deployments", true);

        deployment.finishDeployment();
        deployment.saveToJson(path);

        // Load using original method
        TestDeployment loaded = new TestDeployment();
        stub.setDeployer(address(loaded));
        loaded.loadFromJson(path);

        assertEq(loaded.getByString("LoadTest"), address(0x9999));
        assertEq(loaded.getUintByKey("value"), 42);

        // Cleanup
        vm.removeFile(path);
    }
}
