// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {DeploymentFoundryTesting} from "./DeploymentFoundryTesting.sol";

import {DeploymentRegistry} from "@bao-script/deployment/DeploymentRegistry.sol";
import {MathLib, StringLib} from "../mocks/TestLibraries.sol";

// Test harness extends DeploymentFoundryTesting
contract MockDeploymentLibrary is DeploymentFoundryTesting {
    function deployMathLibrary(string memory key) public returns (address) {
        bytes memory bytecode = type(MathLib).creationCode;
        deployLibrary(key, bytecode, "MathLib", "test/mocks/TestLibraries.sol");
        return get(key);
    }

    function deployStringLibrary(string memory key) public returns (address) {
        bytes memory bytecode = type(StringLib).creationCode;
        deployLibrary(key, bytecode, "StringLib", "test/mocks/TestLibraries.sol");
        return get(key);
    }
}

/**
 * @title DeploymentLibraryTest
 * @notice Tests library deployment functionality (CREATE)
 */
contract DeploymentLibraryTest is BaoDeploymentTest {
    MockDeploymentLibrary public deployment;
    string constant TEST_NETWORK = "test";
    string constant TEST_SALT = "library-test-salt";
    string constant TEST_VERSION = "v1.0.0";

    function setUp() public override {
        super.setUp();
        deployment = new MockDeploymentLibrary();
        startDeploymentSession(deployment, address(this), TEST_NETWORK, TEST_VERSION, TEST_SALT);
    }

    function test_DeployLibrary() public {
        address libAddr = deployment.deployMathLibrary("mathLib");

        assertTrue(libAddr != address(0));
        assertTrue(deployment.has("mathLib"));
        assertEq(deployment.get("mathLib"), libAddr);
        assertEq(deployment.getType("mathLib"), "library");
    }

    function test_DeployMultipleLibraries() public {
        address mathLib = deployment.deployMathLibrary("mathLib");
        address stringLib = deployment.deployStringLibrary("stringLib");

        assertNotEq(mathLib, stringLib);

        assertTrue(deployment.has("mathLib"));
        assertTrue(deployment.has("stringLib"));

        string[] memory keys = deployment.keys();
        assertEq(keys.length, 2);
    }

    function test_RevertWhen_LibraryAlreadyExists() public {
        deployment.deployMathLibrary("mathLib");

        vm.expectRevert(abi.encodeWithSelector(DeploymentRegistry.LibraryAlreadyExists.selector, "mathLib"));
        deployment.deployMathLibrary("mathLib");
    }

    function test_LibraryAddressesAreNonDeterministic() public {
        // Deploy library, reset, deploy again - addresses should differ
        address addr1 = deployment.deployMathLibrary("mathLib1");

        // Create new deployment instance
        MockDeploymentLibrary deployment2 = new MockDeploymentLibrary();
        startDeploymentSession(deployment2, address(this), TEST_NETWORK, TEST_VERSION, "library-test-salt-2");
        address addr2 = deployment2.deployMathLibrary("mathLib2");

        // CREATE uses nonce, so addresses will differ
        assertNotEq(addr1, addr2);
    }

    function test_LibraryEntryType() public {
        deployment.deployMathLibrary("mathLib");

        assertEq(deployment.getType("mathLib"), "library");
    }

    function test_LibraryJsonSerialization() public {
        address libAddr = deployment.deployMathLibrary("mathLib");
        deployment.finish();

        // Test in-memory JSON serialization (no filesystem)
        string memory json = deployment.toJsonString();

        assertTrue(bytes(json).length > 0, "JSON should not be empty");
        assertTrue(vm.keyExistsJson(json, ".deployment.mathLib"), "Should contain mathLib");

        // Verify round-trip
        MockDeploymentLibrary newDeployment = new MockDeploymentLibrary();
        newDeployment.fromJsonString(json);

        assertEq(newDeployment.get("mathLib"), libAddr, "Address should match after JSON round-trip");
        assertEq(newDeployment.getType("mathLib"), "library", "Entry type should be preserved");
    }
}
