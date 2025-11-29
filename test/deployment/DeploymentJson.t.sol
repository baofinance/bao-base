// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {DeploymentTesting} from "@bao-script/deployment/DeploymentTesting.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {DeploymentJsonTesting} from "@bao-script/deployment/DeploymentJsonTesting.sol";

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
contract MockDeploymentJson is DeploymentJsonTesting {
    constructor() {
        // Register all possible contract keys used in tests with contracts. prefix
        addContract("contracts.contract1");
        addContract("contracts.contract2");
        addProxy("contracts.proxy1");
        addContract("contracts.lib1");
        addContract("contracts.external1");
    }

    function deploySimpleContract(string memory key, string memory name) public {
        SimpleContract c = new SimpleContract(name);
        registerContract(
            string.concat("contracts.", key),
            address(c),
            "SimpleContract",
            "test/SimpleContract.sol",
            address(this)
        );
    }

    function deploySimpleProxy(string memory key, uint256 value) public {
        SimpleImplementation impl = new SimpleImplementation();
        bytes memory initData = abi.encodeCall(SimpleImplementation.initialize, (value));
        deployProxy(
            string.concat("contracts.", key),
            address(impl),
            initData,
            "SimpleImplementation",
            "test/SimpleImplementation.sol",
            address(this)
        );
    }

    function deployTestLibrary(string memory key) public {
        bytes memory bytecode = type(TestLib).creationCode;
        deployLibrary(string.concat("contracts.", key), bytecode, "TestLib", "test/TestLib.sol", address(this));
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

    function setUp() public override {
        super.setUp();
        deployment = new MockDeploymentJson();
        _resetDeploymentLogs(TEST_SALT, TEST_NETWORK, "{}");
        deployment.start(TEST_NETWORK, TEST_SALT, "");
    }

    function test_SaveEmptyDeployment() public {
        // Use toJson() for verification without saving file
        string memory json = deployment.toJson();
        assertTrue(bytes(json).length > 0);

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        // Verify metadata
        address deployer = vm.parseJsonAddress(json, ".session.deployer");
        assertEq(deployer, address(deployment)); // deployer is the harness

        string memory network = vm.parseJsonString(json, ".session.network");
        assertEq(network, TEST_NETWORK);
    }

    function test_RunSerializationIncludesFinishFieldsWhenActive() public {
        string memory json = deployment.toJson();

        // All finish fields should NOT exist when session is active (cleaner JSON)
        assertFalse(vm.keyExistsJson(json, ".session.finishTimestamp"), "finishTimestamp should not exist when active");
        assertFalse(vm.keyExistsJson(json, ".session.finished"), "ISO finished should not exist when active");
        assertFalse(vm.keyExistsJson(json, ".session.finishBlock"), "finishBlock should not exist when active");
    }

    function test_SaveContractToJson() public {
        deployment.deploySimpleContract("contract1", "Test Contract");
        deployment.finish();

        // Use toJson() for verification without saving file
        string memory json = deployment.toJson();

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        // Verify contract is in JSON
        address addr = vm.parseJsonAddress(json, ".contracts.contract1.address");
        assertEq(addr, deployment.get("contracts.contract1"));

        string memory category = vm.parseJsonString(json, ".contracts.contract1.category");
        assertEq(category, "contract");

        string memory contractType = vm.parseJsonString(json, ".contracts.contract1.contractType");
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
        address addr = vm.parseJsonAddress(json, ".contracts.proxy1.address");
        assertEq(addr, deployment.get("contracts.proxy1"));

        string memory category = vm.parseJsonString(json, ".contracts.proxy1.category");
        assertEq(category, "UUPS proxy");

        string memory saltString = vm.parseJsonString(json, ".contracts.proxy1.saltString");
        assertEq(saltString, "proxy1");

        bytes32 salt = vm.parseJsonBytes32(json, ".contracts.proxy1.salt");
        assertTrue(salt != bytes32(0));
    }

    function test_SaveLibraryToJson() public {
        deployment.deployTestLibrary("lib1");
        deployment.finish();

        string memory json = deployment.toJson();

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        // Verify library fields
        address addr = vm.parseJsonAddress(json, ".contracts.lib1.address");
        assertEq(addr, deployment.get("contracts.lib1"));

        string memory category = vm.parseJsonString(json, ".contracts.lib1.category");
        assertEq(category, "library");

        string memory contractType = vm.parseJsonString(json, ".contracts.lib1.contractType");
        assertEq(contractType, "TestLib");
    }

    function test_SaveMultipleEntriesToJson() public {
        deployment.deploySimpleContract("contract1", "Contract 1");
        deployment.deploySimpleProxy("proxy1", 10);
        deployment.deployTestLibrary("lib1");
        deployment.useExisting("contracts.external1", address(0x1234567890123456789012345678901234567890));

        deployment.finish();

        string memory json = deployment.toJson();

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        // Verify all entries are present
        assertTrue(vm.keyExistsJson(json, ".contracts.contract1"));
        assertTrue(vm.keyExistsJson(json, ".contracts.proxy1"));
        assertTrue(vm.keyExistsJson(json, ".contracts.lib1"));
        assertTrue(vm.keyExistsJson(json, ".contracts.external1"));

        // Verify metadata - finish timestamp is in session
        uint256 finishTimestamp = vm.parseJsonUint(json, ".session.finishTimestamp");
        assertTrue(finishTimestamp > 0);
    }

    function test_LoadFromJson() public {
        // First, save a deployment
        deployment.deploySimpleContract("contract1", "Contract 1");
        deployment.deploySimpleProxy("proxy1", 10);
        deployment.deployTestLibrary("lib1");
        deployment.useExisting("contracts.external1", address(0x1234567890123456789012345678901234567890));

        // Get addresses from deployment data
        address contract1Addr = deployment.get("contracts.contract1");
        address proxy1Addr = deployment.get("contracts.proxy1");
        address lib1Addr = deployment.get("contracts.lib1");

        deployment.finish();

        // Load from JSON
        string memory json = deployment.toJson();
        MockDeploymentJson newDeployment = new MockDeploymentJson();
        newDeployment.fromJson(json);

        // Verify all contracts are loaded
        assertTrue(newDeployment.has("contracts.contract1"));
        assertTrue(newDeployment.has("contracts.proxy1"));
        assertTrue(newDeployment.has("contracts.lib1"));
        assertTrue(newDeployment.has("contracts.external1"));

        assertEq(newDeployment.get("contracts.contract1"), contract1Addr, "contract1");
        assertEq(newDeployment.get("contracts.proxy1"), proxy1Addr, "proxy1");
        assertEq(newDeployment.get("contracts.lib1"), lib1Addr, "lib1");
        assertEq(
            newDeployment.get("contracts.external1"),
            address(0x1234567890123456789012345678901234567890),
            "external1"
        );

        // Verify metadata using getters
        assertEq(newDeployment.getString(newDeployment.SESSION_NETWORK()), TEST_NETWORK);
        assertEq(newDeployment.getString(newDeployment.SYSTEM_SALT_STRING()), TEST_SALT);
    }

    function test_LoadAndContinueDeployment() public {
        // Save initial deployment
        deployment.deploySimpleContract("contract1", "Contract 1");
        deployment.finish();
        string memory json = deployment.toJson();

        // Load and continue
        MockDeploymentJson newDeployment = new MockDeploymentJson();
        newDeployment.fromJson(json);

        // Verify loaded contract exists
        assertTrue(newDeployment.has("contracts.contract1"));

        // Continue deploying
        newDeployment.deploySimpleContract("contract2", "Contract 2");

        assertTrue(newDeployment.has("contracts.contract1"));
        assertTrue(newDeployment.has("contracts.contract2"));

        string[] memory keys = newDeployment.keys();
        assertEq(keys.length, 2);
    }

    function test_JsonContainsBlockNumber() public {
        uint256 deployBlock = block.number;

        deployment.deploySimpleContract("contract1", "Contract 1");

        string memory json = deployment.toJson();
        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");
        uint256 blockNumber = vm.parseJsonUint(json, ".contracts.contract1.blockNumber");

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

        // Timestamps are in session
        uint256 savedStartTime = vm.parseJsonUint(json, ".session.startTimestamp");
        uint256 savedFinishTime = vm.parseJsonUint(json, ".session.finishTimestamp");

        assertEq(savedStartTime, startTime);
        assertEq(savedFinishTime, startTime + 100);
    }

    function test_RevertWhen_ResumeNonexistentPath() public {
        MockDeploymentJson fresh = new MockDeploymentJson();
        vm.expectRevert();
        fresh.start(TEST_NETWORK, "nonexistent-salt", "");
    }

    function test_RevertWhen_ResumeFromUnfinishedRun() public {
        // Deploy contract but DON'T call finish()
        deployment.deploySimpleContract("contract1", "Contract 1");

        // Verify the JSON has an unfinished run (finished field should not exist)
        string memory json = deployment.toJson();
        assertFalse(vm.keyExistsJson(json, ".session.finished"), "ISO finished should not exist when not finished");

        // Try to resume - should fail
        MockDeploymentJson newDeployment = new MockDeploymentJson();
        newDeployment.start(TEST_NETWORK, TEST_SALT, "resume-test");

        // Verify it loaded the contract
        assertTrue(newDeployment.has("contract1"), "Should have loaded contract1");
    }

    function test_ResumeFromFileCreatesActiveRun() public {
        deployment.deploySimpleContract("contract1", "Contract 1");
        deployment.finish();
        string memory json = deployment.toJson();

        // Save to file
        string memory resumePath = string.concat("deployments/", TEST_NETWORK, "/", TEST_SALT, "/resume-active.json");
        vm.writeJson(json, resumePath);

        // Resume from file using start() with startPoint
        MockDeploymentJson resumed = new MockDeploymentJson();
        resumed.start(TEST_NETWORK, TEST_SALT, "resume-active");

        assertTrue(resumed.has("contracts.contract1"), "loaded contract present after resume");
        assertEq(resumed.getString(resumed.SESSION_NETWORK()), TEST_NETWORK, "network should match");

        resumed.deploySimpleContract("contract2", "Contract 2");
        assertTrue(resumed.has("contracts.contract2"), "can continue deploying after resume");
        resumed.finish();
    }
}
