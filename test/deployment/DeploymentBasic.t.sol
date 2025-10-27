// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {TestDeployment} from "./TestDeployment.sol";

import {DeploymentRegistry} from "@bao-script/deployment/DeploymentRegistry.sol";
import {Deployment} from "@bao-script/deployment/Deployment.sol";

// Simple mock contracts for testing
contract MockContract {
    string public name;

    constructor(string memory _name) {
        name = _name;
    }
}

contract MockImplementation {
    uint256 public value;

    function initialize(uint256 _value) external {
        value = _value;
    }
}

// Test harness
contract DeploymentHarness is TestDeployment {
    function deployMockContract(string memory key, string memory mockName) public returns (address) {
        MockContract mock = new MockContract(mockName);
        return registerContract(key, address(mock), "MockContract", "test/MockContract.sol", "contract");
    }

    function deployMockImplementation(string memory key, uint256 initValue) public returns (address) {
        MockImplementation impl = new MockImplementation();
        impl.initialize(initValue);
        return registerContract(key, address(impl), "MockImplementation", "test/MockImplementation.sol", "contract");
    }
}

/**
 * @title DeploymentBasicTest
 * @notice Tests basic deployment functionality with string keys
 */
contract DeploymentBasicTest is Test {
    DeploymentHarness public deployment;

    function setUp() public {
        deployment = new DeploymentHarness();
        deployment.startDeployment(address(this), "test", "v1.0.0");
    }

    function test_StartDeployment() public view {
        Deployment.DeploymentMetadata memory metadata = deployment.getMetadata();
        assertEq(metadata.deployer, address(this));
        assertEq(metadata.network, "test");
        assertEq(metadata.version, "v1.0.0");
        assertTrue(metadata.startedAt > 0);
        assertTrue(metadata.startBlock > 0);
    }

    function test_DeployContract() public {
        address mockAddr = deployment.deployMockContract("mock1", "Mock Contract 1");

        assertTrue(mockAddr != address(0));
        assertTrue(deployment.hasByString("mock1"));
        assertEq(deployment.getByString("mock1"), mockAddr);
        assertEq(deployment.getEntryType("mock1"), "contract");
    }

    function test_DeployMultipleContracts() public {
        address mock1 = deployment.deployMockContract("mock1", "Mock 1");
        address mock2 = deployment.deployMockContract("mock2", "Mock 2");
        address mock3 = deployment.deployMockContract("mock3", "Mock 3");

        assertNotEq(mock1, mock2);
        assertNotEq(mock2, mock3);

        assertTrue(deployment.hasByString("mock1"));
        assertTrue(deployment.hasByString("mock2"));
        assertTrue(deployment.hasByString("mock3"));

        string[] memory keys = deployment.keys();
        assertEq(keys.length, 3);
    }

    function test_UseExistingContract() public {
        MockContract mock = new MockContract("Existing Mock");
        address mockAddr = deployment.useExistingByString("existing1", address(mock));

        assertEq(mockAddr, address(mock));
        assertTrue(deployment.hasByString("existing1"));
        assertEq(deployment.getByString("existing1"), address(mock));
        assertEq(deployment.getEntryType("existing1"), "contract");
    }

    function test_Has() public {
        assertFalse(deployment.hasByString("nonexistent"));

        deployment.deployMockContract("mock1", "Mock 1");

        assertTrue(deployment.hasByString("mock1"));
        assertFalse(deployment.hasByString("mock2"));
    }

    function test_Keys() public {
        string[] memory keys = deployment.keys();
        assertEq(keys.length, 0);

        deployment.deployMockContract("mock1", "Mock 1");
        deployment.deployMockContract("mock2", "Mock 2");

        keys = deployment.keys();
        assertEq(keys.length, 2);
        assertEq(keys[0], "mock1");
        assertEq(keys[1], "mock2");
    }

    function test_RevertWhen_ContractNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(DeploymentRegistry.ContractNotFound.selector, "nonexistent"));
        deployment.getByString("nonexistent");
    }

    function test_RevertWhen_ContractAlreadyExists() public {
        deployment.deployMockContract("mock1", "Mock 1");

        vm.expectRevert(abi.encodeWithSelector(DeploymentRegistry.ContractAlreadyExists.selector, "mock1"));
        deployment.deployMockContract("mock1", "Mock 1");
    }

    function test_RevertWhen_InvalidAddress() public {
        vm.expectRevert(abi.encodeWithSelector(DeploymentRegistry.InvalidAddress.selector, "invalid"));
        deployment.useExistingByString("invalid", address(0));
    }

    function test_FinishDeployment() public {
        deployment.finishDeployment();

        Deployment.DeploymentMetadata memory metadata = deployment.getMetadata();
        assertTrue(metadata.finishedAt > 0);
        assertTrue(metadata.finishedAt >= metadata.startedAt);
    }
}
