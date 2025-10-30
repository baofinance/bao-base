// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {TestDeployment} from "./TestDeployment.sol";

import {DeploymentRegistry} from "@bao-script/deployment/DeploymentRegistry.sol";

/**
 * @title DeploymentParameterTest
 * @notice Tests parameter storage and retrieval (typed configuration values)
 */
contract DeploymentParameterTest is Test {
    ParameterTestHarness public deployment;

    function setUp() public {
        deployment = new ParameterTestHarness();
        deployment.startDeployment(address(this), "test", "v1.0.0", "parameter-test-salt", address(0), "Stem_v1");
    }

    function test_SetAndGetString() public {
        deployment.setStringByKey("tokenName", "BaoUSD");

        assertEq(deployment.getStringByKey("tokenName"), "BaoUSD");
        assertEq(deployment.getEntryType("tokenName"), "string");
    }

    function test_SetAndGetUint() public {
        deployment.setUintByKey("decimals", 18);

        assertEq(deployment.getUintByKey("decimals"), 18);
        assertEq(deployment.getEntryType("decimals"), "uint256");
    }

    function test_SetAndGetInt() public {
        deployment.setIntByKey("offset", -100);

        assertEq(deployment.getIntByKey("offset"), -100);
        assertEq(deployment.getEntryType("offset"), "int256");
    }

    function test_SetAndGetBool() public {
        deployment.setBoolByKey("enabled", true);

        assertTrue(deployment.getBoolByKey("enabled"));
        assertEq(deployment.getEntryType("enabled"), "bool");
    }

    function test_CannotOverwriteParameter() public {
        deployment.setUintByKey("value", 100);
        assertEq(deployment.getUintByKey("value"), 100);

        // Attempting to overwrite should revert
        vm.expectRevert(abi.encodeWithSelector(DeploymentRegistry.ParameterAlreadyExists.selector, "value"));
        deployment.setUintByKey("value", 200);
    }

    function test_MultipleParameters() public {
        deployment.setStringByKey("name", "Harbor");
        deployment.setStringByKey("symbol", "HBR");
        deployment.setUintByKey("decimals", 18);
        deployment.setBoolByKey("transferable", true);

        assertEq(deployment.getStringByKey("name"), "Harbor");
        assertEq(deployment.getStringByKey("symbol"), "HBR");
        assertEq(deployment.getUintByKey("decimals"), 18);
        assertTrue(deployment.getBoolByKey("transferable"));
    }

    function test_RevertWhen_ParameterNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(DeploymentRegistry.ParameterNotFound.selector, "nonexistent"));
        deployment.getStringByKey("nonexistent");
    }

    function test_RevertWhen_TypeMismatch() public {
        deployment.setStringByKey("name", "Test");

        vm.expectRevert(
            abi.encodeWithSelector(DeploymentRegistry.ParameterTypeMismatch.selector, "name", "uint256", "string")
        );
        deployment.getUintByKey("name");
    }

    function test_ParametersInKeysList() public {
        deployment.setStringByKey("param1", "value1");
        deployment.setUintByKey("param2", 42);

        string[] memory allKeys = deployment.keys();
        assertEq(allKeys.length, 2);
    }

    function test_SaveAndLoadParameters() public {
        // Set parameters
        deployment.setStringByKey("tokenName", "BaoUSD");
        deployment.setStringByKey("tokenSymbol", "BAOUSD");
        deployment.setUintByKey("decimals", 18);
        deployment.setBoolByKey("enabled", true);
        deployment.setIntByKey("offset", -50);

        // Save to JSON
        string memory filepath = "results/deployment/test-parameters.json";
        deployment.saveToJson(filepath);

        // Create new deployment and load
        ParameterTestHarness newDeployment = new ParameterTestHarness();
        newDeployment.loadFromJson(filepath);

        // Verify all parameters loaded correctly
        assertEq(newDeployment.getStringByKey("tokenName"), "BaoUSD");
        assertEq(newDeployment.getStringByKey("tokenSymbol"), "BAOUSD");
        assertEq(newDeployment.getUintByKey("decimals"), 18);
        assertTrue(newDeployment.getBoolByKey("enabled"));
        assertEq(newDeployment.getIntByKey("offset"), -50);
    }

    function test_MixedContractsAndParameters() public {
        // Deploy a mock contract
        address mockAddr = deployment.deployMockContract("token", "MockToken");

        // Set parameters
        deployment.setStringByKey("symbol", "MTK");
        deployment.setUintByKey("decimals", 18);

        // Verify both work
        assertEq(deployment.getByString("token"), mockAddr);
        assertEq(deployment.getStringByKey("symbol"), "MTK");
        assertEq(deployment.getUintByKey("decimals"), 18);

        // Verify keys include both
        string[] memory allKeys = deployment.keys();
        assertEq(allKeys.length, 3);
    }
}

// Test harness with mock deployment method
contract ParameterTestHarness is TestDeployment {
    function deployMockContract(string memory key, string memory name) public returns (address) {
        // Simple mock - just create a minimal contract
        address mock = address(new MockContract(name));
        return registerContract(key, mock, "MockContract", "test/MockContract.sol", "mock");
    }
}

contract MockContract {
    string public name;

    constructor(string memory _name) {
        name = _name;
    }
}
