// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {TestDeployment} from "./TestDeployment.sol";

import {DeploymentRegistry} from "@bao-script/deployment/DeploymentRegistry.sol";
import {MathLib, StringLib} from "../mocks/TestLibraries.sol";

// Test harness extends TestDeployment
contract LibraryTestHarness is TestDeployment {
    function deployMathLibrary(string memory key) public returns (address) {
        bytes memory bytecode = type(MathLib).creationCode;
        deployLibrary(key, bytecode, "MathLib", "test/mocks/TestLibraries.sol");
        return _get(key);
    }

    function deployStringLibrary(string memory key) public returns (address) {
        bytes memory bytecode = type(StringLib).creationCode;
        deployLibrary(key, bytecode, "StringLib", "test/mocks/TestLibraries.sol");
        return _get(key);
    }
}

/**
 * @title DeploymentLibraryTest
 * @notice Tests library deployment functionality (CREATE)
 */
contract DeploymentLibraryTest is Test {
    LibraryTestHarness public deployment;

    function setUp() public {
        deployment = new LibraryTestHarness();
        deployment.start(address(this), "test", "v1.0.0", "library-test-salt");
    }

    function test_DeployLibrary() public {
        address libAddr = deployment.deployMathLibrary("mathLib");

        assertTrue(libAddr != address(0));
        assertTrue(deployment.hasByString("mathLib"));
        assertEq(deployment.getByString("mathLib"), libAddr);
        assertEq(deployment.getEntryType("mathLib"), "library");
    }

    function test_DeployMultipleLibraries() public {
        address mathLib = deployment.deployMathLibrary("mathLib");
        address stringLib = deployment.deployStringLibrary("stringLib");

        assertNotEq(mathLib, stringLib);

        assertTrue(deployment.hasByString("mathLib"));
        assertTrue(deployment.hasByString("stringLib"));

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
        LibraryTestHarness deployment2 = new LibraryTestHarness();
        deployment2.start(address(this), "test", "v1.0.0", "library-test-salt-2");
        address addr2 = deployment2.deployMathLibrary("mathLib2");

        // CREATE uses nonce, so addresses will differ
        assertNotEq(addr1, addr2);
    }

    function test_LibraryEntryType() public {
        deployment.deployMathLibrary("mathLib");

        assertEq(deployment.getEntryType("mathLib"), "library");
    }

    function test_LibraryJsonSerialization() public {
        address libAddr = deployment.deployMathLibrary("mathLib");
        deployment.finish();

        // Test in-memory JSON serialization (no filesystem)
        string memory json = deployment.toJson();

        assertTrue(bytes(json).length > 0, "JSON should not be empty");
        assertTrue(vm.keyExistsJson(json, ".deployment.mathLib"), "Should contain mathLib");

        // Verify round-trip
        LibraryTestHarness newDeployment = new LibraryTestHarness();
        newDeployment.fromJson(json);

        assertEq(newDeployment.getByString("mathLib"), libAddr, "Address should match after JSON round-trip");
        assertEq(newDeployment.getEntryType("mathLib"), "library", "Entry type should be preserved");
    }
}
