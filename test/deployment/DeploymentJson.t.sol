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
contract MockDeploymentJson is MockDeployment {
    function deploySimpleContract(string memory key, string memory name) public returns (address) {
        SimpleContract c = new SimpleContract(name);
        registerContract(key, address(c), "SimpleContract", "test/SimpleContract.sol", "contract");
        return get(key);
    }

    function deploySimpleProxy(string memory key, uint256 value) public returns (address) {
        SimpleImplementation impl = new SimpleImplementation();
        string memory implKey = registerImplementation(
            key,
            address(impl),
            "SimpleImplementation",
            "test/SimpleImplementation.sol"
        );
        bytes memory initData = abi.encodeCall(SimpleImplementation.initialize, (value));
        this.deployProxy(key, implKey, initData);
        return get(key);
    }

    function deployTestLibrary(string memory key) public returns (address) {
        bytes memory bytecode = type(TestLib).creationCode;
        deployLibrary(key, bytecode, "TestLib", "test/TestLib.sol");
        return get(key);
    }
}

/**
 * @title DeploymentJsonTest
 * @notice Tests JSON serialization and deserialization
 */
contract DeploymentJsonTest is BaoDeploymentTest {
    MockDeploymentJson public deployment;

    string constant TEST_NETWORK = "test-network";
    string constant TEST_SALT = "json-test-salt";
    string constant TEST_VERSION = "v1.0.0";

    function setUp() public override {
        super.setUp();
        deployment = new MockDeploymentJson();
        startDeploymentSession(deployment, address(this), TEST_NETWORK, TEST_VERSION, TEST_SALT, false);
    }

    function test_SaveEmptyDeployment() public {
        // Use toJsonString() for verification without saving file
        string memory json = deployment.toJsonString();
        assertTrue(bytes(json).length > 0);

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        // Verify metadata
        address deployer = vm.parseJsonAddress(json, ".deployer");
        assertEq(deployer, address(deployment)); // deployer is the harness

        string memory network = vm.parseJsonString(json, ".network");
        assertEq(network, TEST_NETWORK);
    }

    function test_RunSerializationIncludesFinishFieldsWhenActive() public {
        string memory json = deployment.toJsonString();

        assertTrue(vm.keyExistsJson(json, ".runs[0].finishTimestamp"));
        uint256 finishTimestamp = vm.parseJsonUint(json, ".runs[0].finishTimestamp");
        assertEq(finishTimestamp, 0, "Should serialize zero finish timestamp");

        string memory finishIso = vm.parseJsonString(json, ".runs[0].finishTimestampISO");
        assertEq(bytes(finishIso).length, 0, "Should serialize empty ISO string");

        assertTrue(vm.keyExistsJson(json, ".runs[0].finishBlock"));
        uint256 finishBlock = vm.parseJsonUint(json, ".runs[0].finishBlock");
        assertEq(finishBlock, 0, "Should serialize zero finish block");
    }

    function test_SaveContractToJson() public {
        deployment.deploySimpleContract("contract1", "Test Contract");
        deployment.finish();

        // Use toJsonString() for verification without saving file
        string memory json = deployment.toJsonString();

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        // Verify contract is in JSON
        address addr = vm.parseJsonAddress(json, ".deployment.contract1.address");
        assertEq(addr, deployment.get("contract1"));

        string memory category = vm.parseJsonString(json, ".deployment.contract1.category");
        assertEq(category, "contract");

        string memory contractType = vm.parseJsonString(json, ".deployment.contract1.contractType");
        assertEq(contractType, "SimpleContract");
    }

    function test_SaveProxyToJson() public {
        deployment.deploySimpleProxy("proxy1", 100);
        deployment.finish();

        // Use toJsonString() for verification without saving file
        string memory json = deployment.toJsonString();

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        // Verify proxy fields
        address addr = vm.parseJsonAddress(json, ".deployment.proxy1.address");
        assertEq(addr, deployment.get("proxy1"));

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

        string memory json = deployment.toJsonString();

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        // Verify library fields
        address addr = vm.parseJsonAddress(json, ".deployment.lib1.address");
        assertEq(addr, deployment.get("lib1"));

        string memory category = vm.parseJsonString(json, ".deployment.lib1.category");
        assertEq(category, "library");

        string memory contractType = vm.parseJsonString(json, ".deployment.lib1.contractType");
        assertEq(contractType, "TestLib");
    }

    function test_SaveMultipleEntriesToJson() public {
        deployment.deploySimpleContract("contract1", "Contract 1");
        deployment.deploySimpleProxy("proxy1", 10);
        deployment.deployTestLibrary("lib1");
        deployment.useExisting("external1", address(0x1234567890123456789012345678901234567890));

        deployment.finish();

        string memory json = deployment.toJsonString();

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
        // First, save a deployment
        address contract1Addr = deployment.deploySimpleContract("contract1", "Contract 1");
        address proxy1Addr = deployment.deploySimpleProxy("proxy1", 10);
        address lib1Addr = deployment.deployTestLibrary("lib1");
        deployment.useExisting("external1", address(0x1234567890123456789012345678901234567890));

        deployment.finish();
        deployment.forceSaveRegistry();

        // Create new deployment and load
        MockDeploymentJson newDeployment = new MockDeploymentJson();
        newDeployment.forceLoadRegistry(deployment.getSystemSaltString());

        // Verify all contracts are loaded
        assertTrue(newDeployment.has("contract1"));
        assertTrue(newDeployment.has("proxy1"));
        assertTrue(newDeployment.has("lib1"));
        assertTrue(newDeployment.has("external1"));

        assertEq(newDeployment.get("contract1"), contract1Addr, "contract1");
        assertEq(newDeployment.get("proxy1"), proxy1Addr, "proxy1");
        assertEq(newDeployment.get("lib1"), lib1Addr, "lib1");
        assertEq(newDeployment.get("external1"), address(0x1234567890123456789012345678901234567890), "external1");

        // Verify metadata
        Deployment.DeploymentMetadata memory metadata = newDeployment.getMetadata();
        assertEq(metadata.network, TEST_NETWORK);
        assertEq(metadata.version, TEST_VERSION);
    }

    function test_LoadAndContinueDeployment() public {
        // Save initial deployment
        deployment.deploySimpleContract("contract1", "Contract 1");
        deployment.finish();
        string memory json = deployment.toJsonString();

        // Load and continue
        MockDeploymentJson newDeployment = new MockDeploymentJson();
        newDeployment.fromJsonString(json);

        // Verify loaded contract exists
        assertTrue(newDeployment.has("contract1"));

        // Continue deploying
        newDeployment.deploySimpleContract("contract2", "Contract 2");

        assertTrue(newDeployment.has("contract1"));
        assertTrue(newDeployment.has("contract2"));

        string[] memory keys = newDeployment.keys();
        assertEq(keys.length, 2);
    }

    function test_JsonContainsBlockNumber() public {
        uint256 deployBlock = block.number;

        deployment.deploySimpleContract("contract1", "Contract 1");

        string memory json = deployment.toJsonString();
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

        string memory json = deployment.toJsonString();
        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        // Timestamps are now in runs array
        uint256 savedStartTime = vm.parseJsonUint(json, ".runs[0].startTimestamp");
        uint256 savedFinishTime = vm.parseJsonUint(json, ".runs[0].finishTimestamp");

        assertEq(savedStartTime, startTime);
        assertEq(savedFinishTime, startTime + 100);
    }

    function test_RevertWhen_ResumeNonexistentPath() public {
        MockDeploymentJson fresh = new MockDeploymentJson();
    string memory config = buildDeploymentConfig(address(this), TEST_VERSION, "nonexistent-salt");
        vm.expectRevert();
    fresh.resume(config, TEST_NETWORK, false);
    }

    function test_RevertWhen_ResumeFromUnfinishedRun() public {
        // Deploy contract but DON'T call finish()
        deployment.deploySimpleContract("contract1", "Contract 1");

        // Verify the JSON has an unfinished run
        string memory json = deployment.toJsonString();
        bool finished = vm.parseJsonBool(json, ".runs[0].finished");
        assertFalse(finished, "Run should not be finished");

        // Try to resume - should fail
        MockDeploymentJson newDeployment = new MockDeploymentJson();
        newDeployment.fromJsonString(json);

        vm.expectRevert("Cannot resume: last run not finished");
        newDeployment.resumeAfterLoad();
    }
}
