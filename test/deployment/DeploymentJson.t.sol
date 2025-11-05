// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {MockDeployment} from "./MockDeployment.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {DeploymentRegistry} from "@bao-script/deployment/DeploymentRegistry.sol";

// Mock contracts for JSON testing
contract SimpleContract {
    string public name;

    constructor(string memory _name) {
        name = _name;
    }
}

contract SimpleImplementation is Initializable, UUPSUpgradeable {
    uint256 public value;

    function initialize(uint256 _value) external initializer {
        value = _value;
    }

    function _authorizeUpgrade(address) internal override {}
}

// Library for testing
library TestLib {
    function test() internal pure returns (uint256) {
        return 42;
    }
}

// Test harness
contract JsonTestHarness is MockDeployment {
    function deploySimpleContract(string memory key, string memory name) public returns (address) {
        SimpleContract c = new SimpleContract(name);
        registerContract(key, address(c), "SimpleContract", "test/SimpleContract.sol", "contract");
        return _get(key);
    }

    function deploySimpleProxy(string memory key, uint256 value) public returns (address) {
        SimpleImplementation impl = new SimpleImplementation();
        string memory implKey = string.concat(key, "_impl");
        registerImplementation(implKey, address(impl), "SimpleImplementation", "test/SimpleImplementation.sol");
        bytes memory initData = abi.encodeCall(SimpleImplementation.initialize, (value));
        this.deployProxy(key, implKey, initData);
        return _get(key);
    }

    function deployTestLibrary(string memory key) public returns (address) {
        bytes memory bytecode = type(TestLib).creationCode;
        deployLibrary(key, bytecode, "TestLib", "test/TestLib.sol");
        return _get(key);
    }
}

/**
 * @title DeploymentJsonTest
 * @notice Tests JSON serialization and deserialization
 */
contract DeploymentJsonTest is BaoDeploymentTest {
    JsonTestHarness public deployment;
    string constant TEST_OUTPUT_DIR = "results/deployments";
    string constant TEST_NETWORK = "test-network";
    string constant TEST_SALT = "json-test-salt";
    string constant TEST_VERSION = "v1.0.0";

    function setUp() public {
        super.setUp();
        deployment = new JsonTestHarness();
        deployment.start(address(this), TEST_NETWORK, TEST_VERSION, TEST_SALT);
    }

    function test_SaveEmptyDeployment() public {
        // Use toJson() for verification without saving file
        string memory json = deployment.toJson();
        assertTrue(bytes(json).length > 0);

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        // Verify metadata
        address deployer = vm.parseJsonAddress(json, ".deployer");
        assertEq(deployer, address(deployment)); // deployer is the harness

        string memory network = vm.parseJsonString(json, ".network");
        assertEq(network, TEST_NETWORK);
    }

    function test_SaveContractToJson() public {
        deployment.deploySimpleContract("contract1", "Test Contract");
        deployment.finish();

        // Use toJson() for verification without saving file
        string memory json = deployment.toJson();

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        // Verify contract is in JSON
        address addr = vm.parseJsonAddress(json, ".deployment.contract1.address");
        assertEq(addr, deployment.getByString("contract1"));

        string memory category = vm.parseJsonString(json, ".deployment.contract1.category");
        assertEq(category, "contract");

        string memory contractType = vm.parseJsonString(json, ".deployment.contract1.contractType");
        assertEq(contractType, "SimpleContract");
    }

    function test_SaveProxyToJson() public {
        deployment.deploySimpleProxy("proxy1", 100);
        deployment.finish();

        // Use toJson() for verification without saving file
        string memory json = deployment.toJson();

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        // Verify proxy fields
        address addr = vm.parseJsonAddress(json, ".deployment.proxy1.address");
        assertEq(addr, deployment.getByString("proxy1"));

        string memory category = vm.parseJsonString(json, ".deployment.proxy1.category");
        assertEq(category, "UUPS proxy");

        string memory saltString = vm.parseJsonString(json, ".deployment.proxy1.saltString");
        assertEq(saltString, "proxy1");

        bytes32 salt = vm.parseJsonBytes32(json, ".deployment.proxy1.salt");
        assertTrue(salt != bytes32(0));
    }

    function test_SaveLibraryToJson() public {
        deployment.deployTestLibrary("lib1");
        deployment.finish();

        string memory json = deployment.toJson();

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        // Verify library fields
        address addr = vm.parseJsonAddress(json, ".deployment.lib1.address");
        assertEq(addr, deployment.getByString("lib1"));

        string memory category = vm.parseJsonString(json, ".deployment.lib1.category");
        assertEq(category, "library");

        string memory contractType = vm.parseJsonString(json, ".deployment.lib1.contractType");
        assertEq(contractType, "TestLib");
    }

    function test_SaveMultipleEntriesToJson() public {
        // Enable auto-save to generate json-test-salt.json for regression
        deployment.enableAutoSave();

        deployment.deploySimpleContract("contract1", "Contract 1");
        deployment.deploySimpleProxy("proxy1", 10);
        deployment.deployTestLibrary("lib1");
        deployment.useExistingByString("external1", address(0x1234567890123456789012345678901234567890));

        deployment.finish();

        string memory path = string.concat(TEST_OUTPUT_DIR, "/json-test-salt.json");
        string memory json = vm.readFile(path);

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        // Verify all entries are present
        assertTrue(vm.keyExistsJson(json, ".deployment.contract1"));
        assertTrue(vm.keyExistsJson(json, ".deployment.proxy1"));
        assertTrue(vm.keyExistsJson(json, ".deployment.lib1"));
        assertTrue(vm.keyExistsJson(json, ".deployment.external1"));

        // Verify metadata - finish timestamp is now in runs array
        uint256 finishTimestamp = vm.parseJsonUint(json, ".runs[0].finishTimestamp");
        assertTrue(finishTimestamp > 0);
    }

    function test_LoadFromJson() public {
        string memory path = string.concat(TEST_OUTPUT_DIR, "/test-load.json");
        // First, save a deployment
        address contract1Addr = deployment.deploySimpleContract("contract1", "Contract 1");
        address proxy1Addr = deployment.deploySimpleProxy("proxy1", 10);
        address lib1Addr = deployment.deployTestLibrary("lib1");

        deployment.finish();
        deployment.saveToJson(path);

        // Create new deployment and load
        JsonTestHarness newDeployment = new JsonTestHarness();
        newDeployment.loadFromJson(path);

        // Verify all contracts are loaded
        assertTrue(newDeployment.hasByString("contract1"));
        assertTrue(newDeployment.hasByString("proxy1"));
        assertTrue(newDeployment.hasByString("lib1"));

        assertEq(newDeployment.getByString("contract1"), contract1Addr);
        assertEq(newDeployment.getByString("proxy1"), proxy1Addr);
        assertEq(newDeployment.getByString("lib1"), lib1Addr);

        // Verify metadata
        Deployment.DeploymentMetadata memory metadata = newDeployment.getMetadata();
        assertEq(metadata.network, TEST_NETWORK);
        assertEq(metadata.version, TEST_VERSION);
    }

    function test_LoadAndContinueDeployment() public {
        string memory path = string.concat(TEST_OUTPUT_DIR, "/test-continue.json");
        // Save initial deployment
        deployment.deploySimpleContract("contract1", "Contract 1");
        deployment.finish();
        deployment.saveToJson(path);

        // Load and continue
        JsonTestHarness newDeployment = new JsonTestHarness();
        newDeployment.resumeFrom(path);

        // Verify loaded contract exists
        assertTrue(newDeployment.hasByString("contract1"));

        // Continue deploying
        newDeployment.deploySimpleContract("contract2", "Contract 2");

        assertTrue(newDeployment.hasByString("contract1"));
        assertTrue(newDeployment.hasByString("contract2"));

        string[] memory keys = newDeployment.keys();
        assertEq(keys.length, 2);
    }

    function test_JsonContainsBlockNumber() public {
        uint256 deployBlock = block.number;

        deployment.deploySimpleContract("contract1", "Contract 1");

        string memory json = deployment.toJson();
        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");
        uint256 blockNumber = vm.parseJsonUint(json, ".deployment.contract1.blockNumber");

        assertEq(blockNumber, deployBlock);
    }

    function test_JsonContainsTimestamps() public {
        uint256 startTime = block.timestamp;

        deployment.deploySimpleContract("contract1", "Contract 1");

        vm.warp(block.timestamp + 100);
        deployment.finish();

        string memory json = deployment.toJson();
        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        // Timestamps are now in runs array
        uint256 savedStartTime = vm.parseJsonUint(json, ".runs[0].startTimestamp");
        uint256 savedFinishTime = vm.parseJsonUint(json, ".runs[0].finishTimestamp");

        assertEq(savedStartTime, startTime);
        assertEq(savedFinishTime, startTime + 100);
    }

    function test_RevertWhen_ResumeNonexistentPath() public {
        JsonTestHarness fresh = new JsonTestHarness();
        vm.expectRevert();
        fresh.resume("test", "nonexistent-salt");
    }

    function test_DeployerPreservedAcrossResume() public {
        string memory path = string.concat(TEST_OUTPUT_DIR, "/test-deployers.json");

        // Deploy first contract with original deployer
        address deployer1 = address(deployment);
        deployment.deploySimpleContract("contract1", "Contract 1");
        deployment.finish();
        deployment.saveToJson(path);

        string memory json1 = vm.readFile(path);
        address savedDeployer1 = vm.parseJsonAddress(json1, ".deployer");
        assertEq(savedDeployer1, deployer1, "First deployer should be recorded");

        // Create new harness with different deployer address
        JsonTestHarness newDeployment = new JsonTestHarness();
        address deployer2 = address(newDeployment);
        assertTrue(deployer2 != deployer1, "Deployers should be different");

        // Resume from existing JSON
        newDeployment.resumeFrom(path);

        // Verify the deployer is preserved from the original deployment
        Deployment.DeploymentMetadata memory metadata = newDeployment.getMetadata();
        assertEq(metadata.deployer, deployer1, "Original deployer should be preserved after resume");

        // Deploy second contract with the new deployment context
        newDeployment.deploySimpleContract("contract2", "Contract 2");
        newDeployment.finish();
        newDeployment.saveToJson(path);

        // Verify JSON still shows the original deployer (preserved across resume)
        string memory json2 = vm.readFile(path);
        address savedDeployer2 = vm.parseJsonAddress(json2, ".deployer");
        assertEq(savedDeployer2, deployer1, "Original deployer should be preserved in JSON");

        // Verify both contracts exist
        assertTrue(vm.keyExistsJson(json2, ".deployment.contract1"), "contract1 should exist");
        assertTrue(vm.keyExistsJson(json2, ".deployment.contract2"), "contract2 should exist");
    }

    function test_RevertWhen_ResumeFromUnfinishedRun() public {
        string memory path = string.concat(TEST_OUTPUT_DIR, "/test-unfinished.json");

        // Deploy contract but DON'T call finish()
        deployment.deploySimpleContract("contract1", "Contract 1");

        // Verify the JSON has an unfinished run
        string memory json = deployment.toJson();
        bool finished = vm.parseJsonBool(json, ".runs[0].finished");
        assertFalse(finished, "Run should not be finished");

        // Save to file for resume test
        deployment.saveToJson(path);

        // Try to resume - should fail
        JsonTestHarness newDeployment = new JsonTestHarness();
        vm.expectRevert("Cannot resume: last run not finished");
        newDeployment.resumeFrom(path);
    }
}
