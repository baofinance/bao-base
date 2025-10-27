// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {TestDeployment} from "./TestDeployment.sol";

import {DeploymentRegistry} from "@bao-script/deployment/DeploymentRegistry.sol";

// Mock contracts that depend on each other
contract MockOracle {
    string public name = "Oracle";
}

contract MockToken {
    address public oracle;

    constructor(address _oracle) {
        require(_oracle != address(0), "Oracle required");
        oracle = _oracle;
    }
}

contract MockMinter {
    address public token;
    address public oracle;

    constructor(address _token, address _oracle) {
        require(_token != address(0), "Token required");
        require(_oracle != address(0), "Oracle required");
        token = _token;
        oracle = _oracle;
    }
}

// Test harness
contract DependencyTestHarness is TestDeployment {
    function deployOracle(string memory key) public returns (address) {
        MockOracle oracle = new MockOracle();
        return registerContract(key, address(oracle), "MockOracle", "test/MockOracle.sol", "contract");
    }

    function deployToken(string memory key, string memory oracleKey) public returns (address) {
        address oracleAddr = _get(oracleKey);
        MockToken token = new MockToken(oracleAddr);
        return registerContract(key, address(token), "MockToken", "test/MockToken.sol", "contract");
    }

    function deployMinter(string memory key, string memory tokenKey, string memory oracleKey) public returns (address) {
        address tokenAddr = _get(tokenKey);
        address oracleAddr = _get(oracleKey);
        MockMinter minter = new MockMinter(tokenAddr, oracleAddr);
        return registerContract(key, address(minter), "MockMinter", "test/MockMinter.sol", "contract");
    }
}

/**
 * @title DeploymentDependencyTest
 * @notice Tests dependency management and error handling
 */
contract DeploymentDependencyTest is Test {
    DependencyTestHarness public deployment;

    function setUp() public {
        deployment = new DependencyTestHarness();
        deployment.startDeployment(address(this), "test", "v1.0.0");
    }

    function test_SimpleDependency() public {
        // Deploy oracle first
        address oracleAddr = deployment.deployOracle("oracle");

        // Deploy token that depends on oracle
        address tokenAddr = deployment.deployToken("token", "oracle");

        assertTrue(tokenAddr != address(0));
        assertTrue(deployment.hasByString("token"));

        MockToken token = MockToken(tokenAddr);
        assertEq(token.oracle(), oracleAddr);
    }

    function test_ChainedDependencies() public {
        // Deploy in correct order: oracle -> token -> minter
        address oracleAddr = deployment.deployOracle("oracle");
        address tokenAddr = deployment.deployToken("token", "oracle");
        address minterAddr = deployment.deployMinter("minter", "token", "oracle");

        assertTrue(minterAddr != address(0));

        MockMinter minter = MockMinter(minterAddr);
        assertEq(minter.token(), tokenAddr);
        assertEq(minter.oracle(), oracleAddr);
    }

    function test_RevertWhen_DependencyNotDeployed() public {
        // Try to deploy token without oracle
        vm.expectRevert(abi.encodeWithSelector(DeploymentRegistry.ContractNotFound.selector, "oracle"));
        deployment.deployToken("token", "oracle");
    }

    function test_RevertWhen_ChainedDependencyMissing() public {
        // Deploy only oracle, skip token
        deployment.deployOracle("oracle");

        // Try to deploy minter without token
        vm.expectRevert(abi.encodeWithSelector(DeploymentRegistry.ContractNotFound.selector, "token"));
        deployment.deployMinter("minter", "token", "oracle");
    }

    function test_MultipleDependentsOnSameContract() public {
        // Deploy oracle once
        address oracleAddr = deployment.deployOracle("oracle");

        // Multiple contracts can depend on it
        address token1 = deployment.deployToken("token1", "oracle");
        address token2 = deployment.deployToken("token2", "oracle");

        MockToken t1 = MockToken(token1);
        MockToken t2 = MockToken(token2);

        assertEq(t1.oracle(), oracleAddr);
        assertEq(t2.oracle(), oracleAddr);
    }

    function test_GetBeforeDeployment() public {
        // Verify get() works for deployed contracts
        deployment.deployOracle("oracle");
        address addr = deployment.getByString("oracle");
        assertTrue(addr != address(0));

        // Verify get() reverts for non-deployed
        vm.expectRevert(abi.encodeWithSelector(DeploymentRegistry.ContractNotFound.selector, "token"));
        deployment.getByString("token");
    }

    function test_ComplexDependencyGraph() public {
        // Deploy a complex graph:
        // oracle1, oracle2 -> token1 (uses oracle1) -> minter (uses token1, oracle2)

        deployment.deployOracle("oracle1");
        address oracle2 = deployment.deployOracle("oracle2");
        address token1 = deployment.deployToken("token1", "oracle1");
        address minter = deployment.deployMinter("minter", "token1", "oracle2");

        MockMinter m = MockMinter(minter);
        assertEq(m.token(), token1);
        assertEq(m.oracle(), oracle2);
    }
}
