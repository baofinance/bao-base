// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {MockDeployment} from "./MockDeployment.sol";

import {DeploymentRegistry} from "@bao-script/deployment/DeploymentRegistry.sol";

/**
 * @title DeploymentParameterTest
 * @notice Tests parameter storage and retrieval (typed configuration values)
 */
contract DeploymentParameterTest is BaoDeploymentTest {
    MockDeploymentParameter public deployment;
    string constant TEST_NETWORK = "test";
    string constant TEST_SALT = "parameter-test-salt";
    string constant TEST_VERSION = "v1.0.0";

    function setUp() public override {
        super.setUp();
        deployment = new MockDeploymentParameter();
        deployment.start(address(this), TEST_NETWORK, TEST_VERSION, TEST_SALT);
    }

    function test_SetAndGetString() public {
        deployment.setString("tokenName", "BaoUSD");

        assertEq(deployment.getString("tokenName"), "BaoUSD");
        assertEq(deployment.getType("tokenName"), "string");
    }

    function test_SetAndGetUint() public {
        deployment.setUint("decimals", 18);

        assertEq(deployment.getUint("decimals"), 18);
        assertEq(deployment.getType("decimals"), "uint256");
    }

    function test_SetAndGetInt() public {
        deployment.setInt("offset", -100);

        assertEq(deployment.getInt("offset"), -100);
        assertEq(deployment.getType("offset"), "int256");
    }

    function test_SetAndGetBool() public {
        deployment.setBool("enabled", true);

        assertTrue(deployment.getBool("enabled"));
        assertEq(deployment.getType("enabled"), "bool");
    }

    function test_CannotOverwriteParameter() public {
        deployment.setUint("value", 100);
        assertEq(deployment.getUint("value"), 100);

        // Attempting to overwrite should revert
        vm.expectRevert(abi.encodeWithSelector(DeploymentRegistry.ParameterAlreadyExists.selector, "value"));
        deployment.setUint("value", 200);
    }

    function test_MultipleParameters() public {
        deployment.setString("name", "Harbor");
        deployment.setString("symbol", "HBR");
        deployment.setUint("decimals", 18);
        deployment.setBool("transferable", true);

        assertEq(deployment.getString("name"), "Harbor");
        assertEq(deployment.getString("symbol"), "HBR");
        assertEq(deployment.getUint("decimals"), 18);
        assertTrue(deployment.getBool("transferable"));
    }

    function test_RevertWhen_ParameterNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(DeploymentRegistry.ParameterNotFound.selector, "nonexistent"));
        deployment.getString("nonexistent");
    }

    function test_RevertWhen_TypeMismatch() public {
        deployment.setString("name", "Test");

        vm.expectRevert(
            abi.encodeWithSelector(DeploymentRegistry.ParameterTypeMismatch.selector, "name", "uint256", "string")
        );
        deployment.getUint("name");
    }

    function test_ParametersInKeysList() public {
        deployment.setString("param1", "value1");
        deployment.setUint("param2", 42);

        string[] memory allKeys = deployment.keys();
        assertEq(allKeys.length, 2);
    }

    function test_SaveAndLoadParameters() public {
        // Set parameters
        deployment.setString("tokenName", "BaoUSD");
        deployment.setString("tokenSymbol", "BAOUSD");
        deployment.setUint("decimals", 18);
        deployment.setBool("enabled", true);
        deployment.setInt("offset", -50);

        // Save to JSON
        string memory filepath = "results/deployments/test-parameters.json";
        deployment.finish();
        deployment.toJsonFile(filepath);

        // Create new deployment and load
        MockDeploymentParameter newDeployment = new MockDeploymentParameter();
        newDeployment.fromJsonFile(filepath);

        // Verify all parameters loaded correctly
        assertEq(newDeployment.getString("tokenName"), "BaoUSD");
        assertEq(newDeployment.getString("tokenSymbol"), "BAOUSD");
        assertEq(newDeployment.getUint("decimals"), 18);
        assertTrue(newDeployment.getBool("enabled"));
        assertEq(newDeployment.getInt("offset"), -50);
    }

    function test_MixedContractsAndParameters() public {
        // Deploy a mock contract
        address mockAddr = deployment.deployMockContract("token", "MockToken");

        // Set parameters
        deployment.setString("symbol", "MTK");
        deployment.setUint("decimals", 18);

        // Verify both work
        assertEq(deployment.get("token"), mockAddr);
        assertEq(deployment.getString("symbol"), "MTK");
        assertEq(deployment.getUint("decimals"), 18);

        // Verify keys include both
        string[] memory allKeys = deployment.keys();
        assertEq(allKeys.length, 3);
    }
}

// Test harness with mock deployment method
contract MockDeploymentParameter is MockDeployment {
    function deployMockContract(string memory key, string memory name) public returns (address) {
        // Simple mock - just create a minimal contract
        address mock = address(new MockContract(name));
        registerContract(key, mock, "MockContract", "test/MockContract.sol", "mock");
        return get(key);
    }
}

contract MockContract {
    string public name;

    constructor(string memory _name) {
        name = _name;
    }
}
