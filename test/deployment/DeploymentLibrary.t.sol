// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {TestDeployment} from "./TestDeployment.sol";

import {DeploymentRegistry} from "@bao-script/deployment/DeploymentRegistry.sol";

// Simple library for testing
library MathLib {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        return a + b;
    }

    function multiply(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b;
    }
}

library StringLib {
    function concat(string memory a, string memory b) internal pure returns (string memory) {
        return string(abi.encodePacked(a, b));
    }
}

// Test harness
contract LibraryTestHarness is TestDeployment {
    function deployMathLibrary(string memory key) public returns (address) {
        bytes memory bytecode = type(MathLib).creationCode;
        return deployLibrary(key, bytecode, "MathLib", "test/MathLib.sol");
    }

    function deployStringLibrary(string memory key) public returns (address) {
        bytes memory bytecode = type(StringLib).creationCode;
        return deployLibrary(key, bytecode, "StringLib", "test/StringLib.sol");
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
        deployment.startDeployment(address(this), "test", "v1.0.0");
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
        deployment2.startDeployment(address(this), "test", "v1.0.0");
        address addr2 = deployment2.deployMathLibrary("mathLib2");

        // CREATE uses nonce, so addresses will differ
        assertNotEq(addr1, addr2);
    }
}
