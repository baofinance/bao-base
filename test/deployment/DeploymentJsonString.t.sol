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

    function fromJsonNoSave(string memory json) public {
        _fromJsonNoSave(json);
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
    }

    function _startDeployment(string memory network) internal {
        _initDeploymentTest(TEST_SALT, network);
        deployment.start(network, TEST_SALT, "");
    }

    function test_StringRoundTripPersistsState() public {
        _startDeployment("test_StringRoundTripPersistsState");

        deployment.useExisting("contracts.Admin", address(0xABCD));
        deployment.useExisting("contracts.Treasury", address(0xDEAD));
        deployment.setString("config.networkName", "Ethereum");
        deployment.setUint("config.chainId", 1);
        deployment.setInt("config.temperature", -42);
        deployment.setBool("config.isProduction", true);
        deployment.setUint("contracts.LoadTest.value", 99);
        deployment.finish();

        string memory json = deployment.toJson();
        assertTrue(bytes(json).length > 0, "JSON should not be empty");
        assertEq(vm.parseJsonUint(json, ".schemaVersion"), 1, "Schema version should be 1");

        DeploymentJsonStringTestHarness restored = new DeploymentJsonStringTestHarness();
        restored.fromJsonNoSave(json);

        assertEq(restored.get("contracts.Admin"), address(0xABCD), "Admin address persists");
        assertEq(restored.get("contracts.Treasury"), address(0xDEAD), "Treasury address persists");
        assertEq(restored.getUint("contracts.LoadTest.value"), 99, "LoadTest value persists");
        assertEq(restored.getString("config.networkName"), "Ethereum", "Network name persists");
        assertEq(restored.getUint("config.chainId"), 1, "Chain id persists");
        assertEq(restored.getInt("config.temperature"), -42, "Temperature persists");
        assertTrue(restored.getBool("config.isProduction"), "Production flag persists");
    }

    function test_EmptyDeploymentSerializationIncludesMetadata() public {
        _startDeployment("test_EmptyDeploymentSerializationIncludesMetadata");
        deployment.finish();

        string memory json = deployment.toJson();
        assertEq(vm.parseJsonUint(json, ".schemaVersion"), 1, "Schema version should be 1");

        assertTrue(vm.keyExistsJson(json, ".session"), "Session metadata exists");
        assertTrue(vm.keyExistsJson(json, ".session.network"), "Network saved");
        assertTrue(vm.keyExistsJson(json, ".session.deployer"), "Deployer saved");

        uint256 startTimestamp = vm.parseJsonUint(json, ".session.startTimestamp");
        uint256 finishTimestamp = vm.parseJsonUint(json, ".session.finishTimestamp");
        assertTrue(startTimestamp > 0, "Start timestamp recorded");
        assertTrue(finishTimestamp >= startTimestamp, "Finish timestamp recorded");
    }
}
