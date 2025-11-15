// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {DeploymentFoundryTesting} from "./DeploymentFoundryTesting.sol";

import {DeploymentRegistry} from "@bao-script/deployment/DeploymentRegistry.sol";
import {MockOracle, MockToken, MockMinter} from "../mocks/basic/MockDependencies.sol";

// Test harness extends DeploymentFoundryTesting
contract MockDeploymentDependency is DeploymentFoundryTesting {
    function deployOracle(string memory key, uint256 price) public returns (address) {
        MockOracle oracle = new MockOracle(price);
        registerContract(key, address(oracle), "MockOracle", "test/mocks/basic/MockDependencies.sol", "contract");
        return get(key);
    }

    function deployToken(
        string memory key,
        string memory oracleKey,
        string memory name,
        uint8 decimals
    ) public returns (address) {
        address oracleAddr = get(oracleKey);
        MockToken token = new MockToken(oracleAddr, name, decimals);
        registerContract(key, address(token), "MockToken", "test/mocks/basic/MockDependencies.sol", "contract");
        return get(key);
    }

    function deployMinter(string memory key, string memory tokenKey, string memory oracleKey) public returns (address) {
        address tokenAddr = get(tokenKey);
        address oracleAddr = get(oracleKey);
        MockMinter minter = new MockMinter(tokenAddr, oracleAddr);
        registerContract(key, address(minter), "MockMinter", "test/MockMinter.sol", "contract");
        return get(key);
    }
}

/**
 * @title DeploymentDependencyTest
 * @notice Tests dependency management and error handling
 */
contract DeploymentDependencyTest is BaoDeploymentTest {
    MockDeploymentDependency public deployment;
    string constant TEST_NETWORK = "test";
    string constant TEST_SALT = "dependency-test-salt";
    string constant TEST_VERSION = "v1.0.0";

    function setUp() public override {
        super.setUp();
        deployment = new MockDeploymentDependency();
        startDeploymentSession(deployment, address(this), TEST_NETWORK, TEST_VERSION, TEST_SALT);
    }

    function test_SimpleDependency() public {
        // Deploy oracle first
        address oracleAddr = deployment.deployOracle("oracle", 100);

        // Deploy token that depends on oracle
        address tokenAddr = deployment.deployToken("token", "oracle", "TestToken", 18);

        assertTrue(tokenAddr != address(0));
        assertTrue(deployment.has("token"));

        MockToken token = MockToken(tokenAddr);
        assertEq(token.oracle(), oracleAddr);
    }

    function test_ChainedDependencies() public {
        // Deploy in correct order: oracle -> token -> minter
        address oracleAddr = deployment.deployOracle("oracle", 100);
        address tokenAddr = deployment.deployToken("token", "oracle", "TestToken", 18);
        address minterAddr = deployment.deployMinter("minter", "token", "oracle");

        assertTrue(minterAddr != address(0));

        MockMinter minter = MockMinter(minterAddr);
        assertEq(minter.token(), tokenAddr);
        assertEq(minter.oracle(), oracleAddr);
    }

    function test_RevertWhen_DependencyNotDeployed() public {
        // Try to deploy token without oracle
        vm.expectRevert(abi.encodeWithSelector(DeploymentRegistry.ContractNotFound.selector, "oracle"));
        deployment.deployToken("token", "oracle", "TestToken", 18);
    }

    function test_RevertWhen_ChainedDependencyMissing() public {
        // Deploy only oracle, skip token
        deployment.deployOracle("oracle", 100);

        // Try to deploy minter without token
        vm.expectRevert(abi.encodeWithSelector(DeploymentRegistry.ContractNotFound.selector, "token"));
        deployment.deployMinter("minter", "token", "oracle");
    }

    function test_MultipleDependentsOnSameContract() public {
        // Deploy oracle once
        address oracleAddr = deployment.deployOracle("oracle", 100);

        // Multiple contracts can depend on it
        address token1 = deployment.deployToken("token1", "oracle", "Token1", 18);
        address token2 = deployment.deployToken("token2", "oracle", "Token2", 6);

        MockToken t1 = MockToken(token1);
        MockToken t2 = MockToken(token2);

        assertEq(t1.oracle(), oracleAddr);
        assertEq(t2.oracle(), oracleAddr);
    }

    function test_GetBeforeDeployment() public {
        // Verify get() works for deployed contracts
        deployment.deployOracle("oracle", 100);
        address addr = deployment.get("oracle");
        assertTrue(addr != address(0));

        // Verify get() reverts for non-deployed
        vm.expectRevert(abi.encodeWithSelector(DeploymentRegistry.ContractNotFound.selector, "token"));
        deployment.get("token");
    }

    function test_ComplexDependencyGraph() public {
        // Deploy a complex graph:
        // oracle1, oracle2 -> token1 (uses oracle1) -> minter (uses token1, oracle2)

        deployment.deployOracle("oracle1", 100);
        address oracle2 = deployment.deployOracle("oracle2", 200);
        address token1 = deployment.deployToken("token1", "oracle1", "Token1", 18);
        address minter = deployment.deployMinter("minter", "token1", "oracle2");

        MockMinter m = MockMinter(minter);
        assertEq(m.token(), token1);
        assertEq(m.oracle(), oracle2);
    }
}
