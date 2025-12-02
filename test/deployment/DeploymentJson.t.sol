// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {DeploymentTesting} from "@bao-script/deployment/DeploymentTesting.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {DeploymentDataMemory} from "@bao-script/deployment/DeploymentDataMemory.sol";
import {DeploymentJsonTesting, DeploymentTestingOutput} from "@bao-script/deployment/DeploymentJsonTesting.sol";

string constant JSON_CONFIG_ROOT = "contracts.config";
string constant JSON_CONFIG_GUARDIAN_KEY = "contracts.config.guardian";
string constant JSON_CONFIG_SYMBOL_KEY = "contracts.config.symbol";
string constant JSON_CONFIG_SUPPLY_KEY = "contracts.config.supply";
string constant JSON_CONFIG_THRESHOLD_KEY = "contracts.config.threshold";
string constant JSON_CONFIG_ENABLED_KEY = "contracts.config.enabled";
string constant JSON_CONFIG_VALIDATORS_KEY = "contracts.config.validators";
string constant JSON_CONFIG_TAGS_KEY = "contracts.config.tags";
string constant JSON_CONFIG_LIMITS_KEY = "contracts.config.limits";
string constant JSON_CONFIG_DELTAS_KEY = "contracts.config.deltas";

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

        addKey(JSON_CONFIG_ROOT);
        addAddressKey(JSON_CONFIG_GUARDIAN_KEY);
        addStringKey(JSON_CONFIG_SYMBOL_KEY);
        addUintKey(JSON_CONFIG_SUPPLY_KEY);
        addIntKey(JSON_CONFIG_THRESHOLD_KEY);
        addBoolKey(JSON_CONFIG_ENABLED_KEY);
        addAddressArrayKey(JSON_CONFIG_VALIDATORS_KEY);
        addStringArrayKey(JSON_CONFIG_TAGS_KEY);
        addUintArrayKey(JSON_CONFIG_LIMITS_KEY);
        addIntArrayKey(JSON_CONFIG_DELTAS_KEY);
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

    function getOutputConfigPath() public returns (string memory) {
        return _getOutputConfigPath();
    }

    function getFilename() public view returns (string memory) {
        return _getFilename();
    }

    function fromJsonNoSave(string memory json) public {
        _fromJsonNoSave(json);
    }
}

/**
 * @title DeploymentJsonTest
 * @notice Tests JSON serialization and deserialization
 */
contract DeploymentJsonTest is BaoDeploymentTest {
    MockDeploymentJson public deployment;

    string constant TEST_SALT = "DeploymentJsonTest";
    string constant MISSING_OWNER_SALT = "DeploymentJsonMissingOwner";

    function setUp() public override {
        super.setUp();
        deployment = new MockDeploymentJson();
    }

    /// @notice Helper to start deployment with test-specific network name
    function _startDeployment(string memory network) internal {
        _initDeploymentTest(TEST_SALT, network);
        deployment.start(network, TEST_SALT, "");
    }

    function test_SaveEmptyDeployment() public {
        _startDeployment("test_SaveEmptyDeployment");

        // Use toJson() for verification without saving file
        string memory json = deployment.toJson();
        assertTrue(bytes(json).length > 0);

        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");

        // Verify metadata
        address deployer = vm.parseJsonAddress(json, ".session.deployer");
        assertEq(deployer, address(deployment)); // deployer is the harness

        string memory network = vm.parseJsonString(json, ".session.network");
        assertEq(network, "test_SaveEmptyDeployment");
    }

    function test_RunSerializationIncludesFinishFieldsWhenActive() public {
        _startDeployment("test_RunSerializationIncludesFinishFieldsWhenActive");

        string memory json = deployment.toJson();

        // All finish fields should NOT exist when session is active (cleaner JSON)
        assertFalse(vm.keyExistsJson(json, ".session.finishTimestamp"), "finishTimestamp should not exist when active");
        assertFalse(vm.keyExistsJson(json, ".session.finished"), "ISO finished should not exist when active");
        assertFalse(vm.keyExistsJson(json, ".session.finishBlock"), "finishBlock should not exist when active");
    }

    function test_SaveContractToJson() public {
        _startDeployment("test_SaveContractToJson");

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
        _startDeployment("test_SaveProxyToJson");

        deployment.deploySimpleProxy("proxy1", 0);
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
        _startDeployment("test_SaveLibraryToJson");
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
        _startDeployment("test_SaveMultipleEntriesToJson");
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

    function test_RegisterExistingPersistsInJson() public {
        _startDeployment("test_RegisterExistingPersistsInJson");

        address existingContract = address(0x1234567890123456789012345678901234567890);
        deployment.useExisting("contracts.external1", existingContract);
        deployment.finish();

        string memory json = deployment.toJson();
        assertEq(
            vm.parseJsonAddress(json, ".contracts.external1.address"),
            existingContract,
            "existing address persisted"
        );
        assertEq(vm.parseJsonString(json, ".contracts.external1.category"), "existing", "category persisted");
    }

    function test_LoadFromJson() public {
        _startDeployment("test_LoadFromJson");

        // First, save a deployment
        deployment.deploySimpleContract("contract1", "Test Contract");
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
        newDeployment.fromJsonNoSave(json);

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
        assertEq(newDeployment.getString(newDeployment.SESSION_NETWORK()), "test_LoadFromJson");
        assertEq(newDeployment.getString(newDeployment.SYSTEM_SALT_STRING()), TEST_SALT);
    }

    function test_LoadAndContinueDeployment() public {
        _startDeployment("test_LoadAndContinueDeployment");

        // Save initial deployment
        deployment.deploySimpleContract("contract1", "Test Contract");
        deployment.finish();

        // Load and continue from the saved snapshot
        MockDeploymentJson newDeployment = new MockDeploymentJson();
        // newDeployment.fromJson(vm.readFile(deployment.getOutputConfigPath()));
        newDeployment.start("test_LoadAndContinueDeployment", TEST_SALT, deployment.getFilename());

        // Verify loaded contract exists
        assertTrue(newDeployment.has("contracts.contract1"));

        // Continue deploying
        newDeployment.deploySimpleContract("contract2", "Contract 2");

        assertTrue(newDeployment.has("contracts.contract1"));
        assertTrue(newDeployment.has("contracts.contract2"));

        string[] memory keys = newDeployment.keys();
        assertTrue(keys.length >= 2, "Should include existing contracts plus metadata");
    }

    function test_JsonContainsBlockNumber() public {
        _startDeployment("test_JsonContainsBlockNumber");

        uint256 deployBlock = block.number;

        deployment.deploySimpleContract("contract1", "Contract 1");

        string memory json = deployment.toJson();
        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");
        uint256 blockNumber = vm.parseJsonUint(json, ".contracts.contract1.blockNumber");

        assertEq(blockNumber, deployBlock);
    }

    function test_JsonContainsTimestamps() public {
        _startDeployment("test_JsonContainsTimestamps");
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
        fresh.start("test_RevertWhen_ResumeNonexistentPath", "nonexistent-salt", "");
    }

    function test_RevertWhen_ResumeFromUnfinishedRun() public {
        _startDeployment("test_RevertWhen_ResumeFromUnfinishedRun");

        // Deploy contract but DON'T call finish()
        deployment.deploySimpleContract("contract1", "Contract 1");

        // Verify the JSON has an unfinished run (finished field should not exist)
        string memory json = deployment.toJson();
        assertFalse(vm.keyExistsJson(json, ".session.finished"), "ISO finished should not exist when not finished");

        // Try to resume from latest - should work even though not finished
        MockDeploymentJson newDeployment = new MockDeploymentJson();
        newDeployment.start("test_RevertWhen_ResumeFromUnfinishedRun", TEST_SALT, "latest");

        // Verify it loaded the contract from the unfinished run
        assertTrue(newDeployment.has("contracts.contract1"), "Should have loaded contract1");
    }

    // function test_RevertWhen_ConfigMissingOwner() public {
    //     string memory network = "test_RevertWhen_ConfigMissingOwner";
    //     _initDeploymentTest(MISSING_OWNER_SALT, network, "{}");

    //     MockDeploymentJson fresh = new MockDeploymentJson();
    //     fresh.start(network, MISSING_OWNER_SALT, "");

    //     string memory ownerKey = fresh.OWNER();
    //     vm.expectRevert(abi.encodeWithSelector(DeploymentDataMemory.ValueNotSet.selector, "owner"));
    //     fresh.getAddress(ownerKey);
    // }

    function test_ResumeFromFileCreatesActiveRun() public {
        _startDeployment("test_ResumeFromFileCreatesActiveRun");

        deployment.deploySimpleContract("contract1", "Contract 1");
        deployment.finish();
        // string memory json = deployment.toJson();

        // Save to file (path structure: results/deployments/{salt}/{network}/{filename})

        // Resume from file using start() with startPoint
        MockDeploymentJson resumed = new MockDeploymentJson();
        resumed.start("test_ResumeFromFileCreatesActiveRun", TEST_SALT, deployment.getFilename());

        assertTrue(resumed.has("contracts.contract1"), "loaded contract present after resume");
        assertEq(
            resumed.getString(resumed.SESSION_NETWORK()),
            "test_ResumeFromFileCreatesActiveRun",
            "network should match"
        );

        resumed.deploySimpleContract("contract2", "Contract 2");
        assertTrue(resumed.has("contracts.contract2"), "can continue deploying after resume");
        resumed.finish();
    }

    function test_SaveScalarValuesToFile() public {
        string memory network = "test_SaveScalarValuesToFile";
        _startDeployment(network);

        deployment.setAddress(JSON_CONFIG_GUARDIAN_KEY, address(0x1111));
        deployment.setString(JSON_CONFIG_SYMBOL_KEY, "BAO-JSON");
        deployment.setUint(JSON_CONFIG_SUPPLY_KEY, 42_000);
        deployment.setInt(JSON_CONFIG_THRESHOLD_KEY, -77);
        deployment.setBool(JSON_CONFIG_ENABLED_KEY, true);

        deployment.finish();

        string memory persisted = vm.readFile(deployment.getOutputConfigPath());

        assertEq(
            vm.parseJsonAddress(persisted, ".contracts.config.guardian"),
            address(0x1111),
            "scalar guardian persisted"
        );
        assertEq(vm.parseJsonString(persisted, ".contracts.config.symbol"), "BAO-JSON", "scalar symbol persisted");
        assertEq(vm.parseJsonUint(persisted, ".contracts.config.supply"), 42_000, "scalar supply persisted");
        assertEq(vm.parseJsonInt(persisted, ".contracts.config.threshold"), -77, "scalar threshold persisted");
        assertEq(vm.parseJsonBool(persisted, ".contracts.config.enabled"), true, "scalar enabled persisted");
    }

    function test_SaveArrayValuesToFile() public {
        string memory network = "test_SaveArrayValuesToFile";
        _startDeployment(network);

        address[] memory validators = new address[](2);
        validators[0] = address(0xAAAA);
        validators[1] = address(0xBBBB);
        deployment.setAddressArray(JSON_CONFIG_VALIDATORS_KEY, validators);

        string[] memory tags = new string[](2);
        tags[0] = "alpha";
        tags[1] = "beta";
        deployment.setStringArray(JSON_CONFIG_TAGS_KEY, tags);

        uint256[] memory limits = new uint256[](3);
        limits[0] = 5;
        limits[1] = 15;
        limits[2] = 25;
        deployment.setUintArray(JSON_CONFIG_LIMITS_KEY, limits);

        int256[] memory deltas = new int256[](3);
        deltas[0] = -9;
        deltas[1] = 0;
        deltas[2] = 11;
        deployment.setIntArray(JSON_CONFIG_DELTAS_KEY, deltas);

        deployment.finish();

        string memory persisted = vm.readFile(deployment.getOutputConfigPath());

        address[] memory parsedValidators = vm.parseJsonAddressArray(persisted, ".contracts.config.validators");
        assertEq(parsedValidators.length, 2, "array validators length persisted");
        assertEq(parsedValidators[0], address(0xAAAA), "array validators first persisted");
        assertEq(parsedValidators[1], address(0xBBBB), "array validators second persisted");

        string[] memory parsedTags = vm.parseJsonStringArray(persisted, ".contracts.config.tags");
        assertEq(parsedTags.length, 2, "array tags length persisted");
        assertEq(parsedTags[0], "alpha", "array tags first persisted");
        assertEq(parsedTags[1], "beta", "array tags second persisted");

        uint256[] memory parsedLimits = vm.parseJsonUintArray(persisted, ".contracts.config.limits");
        assertEq(parsedLimits.length, 3, "array limits length persisted");
        assertEq(parsedLimits[0], 5, "array limits first persisted");
        assertEq(parsedLimits[1], 15, "array limits second persisted");
        assertEq(parsedLimits[2], 25, "array limits third persisted");

        int256[] memory parsedDeltas = vm.parseJsonIntArray(persisted, ".contracts.config.deltas");
        assertEq(parsedDeltas.length, 3, "array deltas length persisted");
        assertEq(parsedDeltas[0], -9, "array deltas first persisted");
        assertEq(parsedDeltas[1], 0, "array deltas second persisted");
        assertEq(parsedDeltas[2], 11, "array deltas third persisted");
    }
}
