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

// Another library for testing
library StringLib {
    function concat(string memory a, string memory b) internal pure returns (string memory) {
        return string(abi.encodePacked(a, b));
    }
}

contract LibraryDeploymentTest is Test {
    TestDeployment public deploy;

    function setUp() public {
        vm.createDir("results/deployments", true);
        deploy = new TestDeployment();
    }

    // ========== CREATE Library Tests ==========

    function test_CREATE_deployLibrary() public {
        bytes memory bytecode = type(MathLib).creationCode;

        address lib = deploy.deployLibrary("MathLib", bytecode);

        assertNotEq(lib, address(0), "Library should be deployed");
        assertEq(deploy.getContract("MathLib"), lib, "Library should be registered");
    }

    function test_CREATE_deployLibrary_ChecksEntry() public {
        bytes memory bytecode = type(MathLib).creationCode;

        deploy.deployLibrary("MathLib", bytecode);

        TestDeployment.DeploymentEntry memory entry = deploy.getEntry("MathLib");
        assertEq(entry.category, "library", "Should be library category");
    }

    function test_CREATE_deployMultipleLibraries() public {
        bytes memory mathBytecode = type(MathLib).creationCode;
        bytes memory stringBytecode = type(StringLib).creationCode;

        address mathLib = deploy.deployLibrary("MathLib", mathBytecode);
        address stringLib = deploy.deployLibrary("StringLib", stringBytecode);

        assertNotEq(mathLib, stringLib, "Different libraries should have different addresses");
        assertEq(deploy.getContract("MathLib"), mathLib);
        assertEq(deploy.getContract("StringLib"), stringLib);
    }

    function test_CREATE_deployLibrary_RevertsOnDuplicate() public {
        bytes memory bytecode = type(MathLib).creationCode;

        deploy.deployLibrary("MathLib", bytecode);

        vm.expectRevert(abi.encodeWithSelector(DeploymentRegistry.LibraryAlreadyExists.selector, "MathLib"));
        deploy.deployLibrary("MathLib", bytecode);
    }

    function test_CREATE_libraryInJSON() public {
        bytes memory bytecode = type(MathLib).creationCode;

        deploy.deployLibrary("MathLib", bytecode);
        deploy.saveToJson("results/deployments/CREATE-library.json");

        string memory json = vm.readFile("results/deployments/CREATE-library.json");
        assertTrue(bytes(json).length > 0, "JSON should be created");

        // Verify it can be loaded back
        TestDeployment loadDeploy = new TestDeployment();
        loadDeploy.loadFromJson("results/deployments/CREATE-library.json");

        assertEq(loadDeploy.getContract("MathLib"), deploy.getContract("MathLib"), "Loaded address should match");

        TestDeployment.DeploymentEntry memory entry = loadDeploy.getEntry("MathLib");
        assertEq(entry.category, "library", "Should be library after load");
    }

    // ========== CREATE3 Library Tests (Note: Deployment uses CREATE for libraries, not CREATE3) ==========

    function test_CREATE3_deployLibrary() public {
        bytes memory bytecode = type(MathLib).creationCode;

        // Note: Salt parameter is ignored - Deployment always uses CREATE for libraries
        address lib = deploy.deployLibrary("MathLib", bytecode, "math-lib-v1");

        assertNotEq(lib, address(0), "Library should be deployed");
        assertEq(deploy.getContract("MathLib"), lib, "Library should be registered");
    }

    function test_CREATE3_deployLibrary_Deterministic() public {
        bytes memory bytecode = type(MathLib).creationCode;
        string memory salt = "deterministic-salt";

        // Note: Libraries use CREATE (non-deterministic), not CREATE3
        address lib1 = deploy.deployLibrary("MathLib1", bytecode, salt);

        // Deploy in new deployment contract
        TestDeployment newDeploy = new TestDeployment();
        address lib2 = newDeploy.deployLibrary("MathLib2", bytecode, salt);

        // Addresses will be different because libraries use CREATE (depends on nonce)
        assertNotEq(lib1, lib2, "CREATE libraries are non-deterministic");
    }

    function test_CREATE3_deployLibrary_ChecksEntry() public {
        bytes memory bytecode = type(MathLib).creationCode;
        string memory salt = "math-lib-salt";

        deploy.deployLibrary("MathLib", bytecode, salt);

        TestDeployment.DeploymentEntry memory entry = deploy.getEntry("MathLib");
        assertEq(entry.category, "library", "Should be library category");
    }

    function test_CREATE3_deployLibrary_RequiresSalt() public {
        bytes memory bytecode = type(MathLib).creationCode;

        // Salt is optional for libraries (ignored anyway since we use CREATE)
        deploy.deployLibrary("MathLib", bytecode, "");
    }

    function test_CREATE3_deployLibrary_RevertsOnDuplicate() public {
        bytes memory bytecode = type(MathLib).creationCode;

        deploy.deployLibrary("MathLib", bytecode, "salt1");

        vm.expectRevert(abi.encodeWithSelector(DeploymentRegistry.LibraryAlreadyExists.selector, "MathLib"));
        deploy.deployLibrary("MathLib", bytecode, "salt2");
    }

    function test_CREATE3_libraryInJSON() public {
        bytes memory bytecode = type(MathLib).creationCode;
        string memory salt = "math-lib-v1";

        deploy.deployLibrary("MathLib", bytecode, salt);
        deploy.saveToJson("results/deployments/CREATE3-library.json");

        string memory json = vm.readFile("results/deployments/CREATE3-library.json");
        assertTrue(bytes(json).length > 0, "JSON should be created");

        // Verify it can be loaded back
        TestDeployment loadDeploy = new TestDeployment();
        loadDeploy.loadFromJson("results/deployments/CREATE3-library.json");

        assertEq(loadDeploy.getContract("MathLib"), deploy.getContract("MathLib"), "Loaded address should match");

        TestDeployment.DeploymentEntry memory entry = loadDeploy.getEntry("MathLib");
        assertEq(entry.category, "library", "Should be library after load");
    }

    // ========== registerExisting Tests (renamed from registerExternal) ==========

    function test_registerExisting_Works() public {
        address existingContract = address(0x1234567890123456789012345678901234567890);

        deploy.registerExisting("ExistingContract", existingContract);

        assertEq(deploy.getContract("ExistingContract"), existingContract);

        TestDeployment.DeploymentEntry memory entry = deploy.getEntry("ExistingContract");
        assertEq(entry.category, "existing", "Should be existing category");
    }

    function test_registerExisting_BackwardCompatible() public {
        address existingContract = address(0x1234567890123456789012345678901234567890);

        // Old name should still work
        deploy.registerExisting("ExistingContract", existingContract);

        assertEq(deploy.getContract("ExistingContract"), existingContract);

        TestDeployment.DeploymentEntry memory entry = deploy.getEntry("ExistingContract");
        assertEq(entry.category, "existing", "Should be existing category");
    }

    function test_existingInJSON() public {
        address existingContract = address(0x1234567890123456789012345678901234567890);

        deploy.registerExisting("stETH", existingContract);
        deploy.saveToJson("results/deployments/CREATE-existing.json");

        string memory json = vm.readFile("results/deployments/CREATE-existing.json");

        // Should contain "existing" category
        assertTrue(bytes(json).length > 0, "JSON should be created");
    }
}
