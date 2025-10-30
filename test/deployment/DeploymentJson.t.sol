// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {TestDeployment} from "./TestDeployment.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {Deployment} from "@bao-script/deployment/Deployment.sol";

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
contract JsonTestHarness is TestDeployment {
    function deploySimpleContract(string memory key, string memory name) public returns (address) {
        SimpleContract c = new SimpleContract(name);
        return registerContract(key, address(c), "SimpleContract", "test/SimpleContract.sol", "contract");
    }

    function deploySimpleProxy(string memory key, string memory saltString, uint256 value) public returns (address) {
        SimpleImplementation impl = new SimpleImplementation();
        bytes memory initData = abi.encodeCall(SimpleImplementation.initialize, (value));
        return deployProxy(key, address(impl), initData, saltString);
    }

    function deployTestLibrary(string memory key) public returns (address) {
        bytes memory bytecode = type(TestLib).creationCode;
        return deployLibrary(key, bytecode, "TestLib", "test/TestLib.sol");
    }
}

/**
 * @title DeploymentJsonTest
 * @notice Tests JSON serialization and deserialization
 */
contract DeploymentJsonTest is Test {
    JsonTestHarness public deployment;
    string constant TEST_OUTPUT_DIR = "results/deployment";

    function setUp() public {
        deployment = new JsonTestHarness();
        deployment.startDeployment(address(this), "test-network", "v1.0.0", "json-test-salt", address(0), "Stem_v1");
    }

    function test_SaveEmptyDeployment() public {
        string memory path = string.concat(TEST_OUTPUT_DIR, "/test-empty.json");
        deployment.saveToJson(path);

        // Verify file exists
        string memory json = vm.readFile(path);
        assertTrue(bytes(json).length > 0);

        // Verify metadata
        address deployer = vm.parseJsonAddress(json, ".deployer.address");
        assertEq(deployer, address(this));

        string memory network = vm.parseJsonString(json, ".metadata.network");
        assertEq(network, "test-network");
    }

    function test_SaveContractToJson() public {
        string memory path = string.concat(TEST_OUTPUT_DIR, "/test-contract.json");
        deployment.deploySimpleContract("contract1", "Test Contract");
        deployment.finishDeployment();
        deployment.saveToJson(path);

        string memory json = vm.readFile(path);

        // Verify contract is in JSON
        address addr = vm.parseJsonAddress(json, ".deployment.contract1.address");
        assertEq(addr, deployment.getByString("contract1"));

        string memory category = vm.parseJsonString(json, ".deployment.contract1.category");
        assertEq(category, "contract");

        string memory contractType = vm.parseJsonString(json, ".deployment.contract1.contractType");
        assertEq(contractType, "SimpleContract");
    }

    function test_SaveProxyToJson() public {
        string memory path = string.concat(TEST_OUTPUT_DIR, "/test-proxy.json");
        deployment.deploySimpleProxy("proxy1", "proxy-salt-1", 100);
        deployment.finishDeployment();
        deployment.saveToJson(path);

        string memory json = vm.readFile(path);

        // Verify proxy fields
        address addr = vm.parseJsonAddress(json, ".deployment.proxy1.address");
        assertEq(addr, deployment.getByString("proxy1"));

        string memory category = vm.parseJsonString(json, ".deployment.proxy1.category");
        assertEq(category, "UUPS proxy");

        string memory saltString = vm.parseJsonString(json, ".deployment.proxy1.saltString");
        assertEq(saltString, "proxy-salt-1");

        bytes32 salt = vm.parseJsonBytes32(json, ".deployment.proxy1.salt");
        assertTrue(salt != bytes32(0));
    }

    function test_SaveLibraryToJson() public {
        string memory path = string.concat(TEST_OUTPUT_DIR, "/test-library.json");
        deployment.deployTestLibrary("lib1");
        deployment.finishDeployment();
        deployment.saveToJson(path);

        string memory json = vm.readFile(path);

        // Verify library fields
        address addr = vm.parseJsonAddress(json, ".deployment.lib1.address");
        assertEq(addr, deployment.getByString("lib1"));

        string memory category = vm.parseJsonString(json, ".deployment.lib1.category");
        assertEq(category, "library");

        string memory contractType = vm.parseJsonString(json, ".deployment.lib1.contractType");
        assertEq(contractType, "TestLib");
    }

    function test_SaveMultipleEntriesToJson() public {
        string memory path = string.concat(TEST_OUTPUT_DIR, "/test-multiple.json");
        deployment.deploySimpleContract("contract1", "Contract 1");
        deployment.deploySimpleProxy("proxy1", "proxy-1", 10);
        deployment.deployTestLibrary("lib1");
        deployment.useExistingByString("external1", address(0x1234567890123456789012345678901234567890));

        deployment.finishDeployment();
        deployment.saveToJson(path);

        string memory json = vm.readFile(path);

        // Verify all entries are present
        assertTrue(vm.keyExistsJson(json, ".deployment.contract1"));
        assertTrue(vm.keyExistsJson(json, ".deployment.proxy1"));
        assertTrue(vm.keyExistsJson(json, ".deployment.lib1"));
        assertTrue(vm.keyExistsJson(json, ".deployment.external1"));

        // Verify metadata
        uint256 finishedAt = vm.parseJsonUint(json, ".metadata.finishedAt");
        assertTrue(finishedAt > 0);
    }

    function test_LoadFromJson() public {
        string memory path = string.concat(TEST_OUTPUT_DIR, "/test-load.json");
        // First, save a deployment
        address contract1Addr = deployment.deploySimpleContract("contract1", "Contract 1");
        address proxy1Addr = deployment.deploySimpleProxy("proxy1", "proxy-1", 10);
        address lib1Addr = deployment.deployTestLibrary("lib1");

        deployment.finishDeployment();
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
        assertEq(metadata.network, "test-network");
        assertEq(metadata.version, "v1.0.0");
    }

    function test_LoadAndContinueDeployment() public {
        string memory path = string.concat(TEST_OUTPUT_DIR, "/test-continue.json");
        // Save initial deployment
        deployment.deploySimpleContract("contract1", "Contract 1");
        deployment.saveToJson(path);

        // Load and continue
        JsonTestHarness newDeployment = new JsonTestHarness();
        newDeployment.loadFromJson(path);

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
        string memory path = string.concat(TEST_OUTPUT_DIR, "/test-blocknumber.json");
        uint256 deployBlock = block.number;

        deployment.deploySimpleContract("contract1", "Contract 1");
        deployment.saveToJson(path);

        string memory json = vm.readFile(path);
        uint256 blockNumber = vm.parseJsonUint(json, ".deployment.contract1.blockNumber");

        assertEq(blockNumber, deployBlock);
    }

    function test_JsonContainsTimestamps() public {
        string memory path = string.concat(TEST_OUTPUT_DIR, "/test-timestamps.json");
        uint256 startTime = block.timestamp;

        deployment.deploySimpleContract("contract1", "Contract 1");

        vm.warp(block.timestamp + 100);
        deployment.finishDeployment();

        deployment.saveToJson(path);

        string memory json = vm.readFile(path);

        uint256 savedStartTime = vm.parseJsonUint(json, ".metadata.startedAt");
        uint256 savedFinishTime = vm.parseJsonUint(json, ".metadata.finishedAt");

        assertEq(savedStartTime, startTime);
        assertEq(savedFinishTime, startTime + 100);
    }
}
