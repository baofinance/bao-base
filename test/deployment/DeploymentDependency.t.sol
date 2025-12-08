// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {DeploymentMemoryTesting} from "@bao-script/deployment/DeploymentMemoryTesting.sol";

import {DeploymentDataMemory} from "@bao-script/deployment/DeploymentDataMemory.sol";
import {MockOracle, MockToken} from "../mocks/basic/MockDependencies.sol";
import {MockMinter} from "../mocks/upgradeable/MockMinter.sol";

// Test harness extends DeploymentTesting
contract MockDeploymentDependency is DeploymentMemoryTesting {
    // Contract keys used in tests
    string public constant ORACLE = "contracts.oracle";
    string public constant ORACLE1 = "contracts.oracle1";
    string public constant ORACLE2 = "contracts.oracle2";
    string public constant TOKEN = "contracts.token";
    string public constant TOKEN1 = "contracts.token1";
    string public constant TOKEN2 = "contracts.token2";
    string public constant MINTER = "contracts.minter";

    constructor() {
        // Register all possible contract keys used in tests
        addContract(ORACLE);
        addContract(ORACLE1);
        addContract(ORACLE2);
        addContract(TOKEN);
        addContract(TOKEN1);
        addContract(TOKEN2);
        addProxy(MINTER); // MINTER is deployed as a proxy
    }

    function deployOracle(string memory key, uint256 price) public returns (address) {
        MockOracle oracle = new MockOracle(price);
        registerContract(key, address(oracle), "MockOracle", type(MockOracle).creationCode, address(this));
        return _get(key);
    }

    function deployToken(
        string memory key,
        string memory oracleKey,
        string memory name,
        uint8 decimals
    ) public returns (address) {
        address oracleAddr = _get(oracleKey);
        MockToken token = new MockToken(oracleAddr, name, decimals);
        registerContract(key, address(token), "MockToken", type(MockToken).creationCode, address(this));
        return _get(key);
    }

    function deployMinter(string memory key, string memory tokenKey, string memory oracleKey) public {
        address tokenAddr = _get(tokenKey);
        address oracleAddr = _get(oracleKey);

        // Deploy implementation (use same token for all three parameters in test)
        MockMinter implementation = new MockMinter(tokenAddr, tokenAddr, tokenAddr);

        // Encode initialization data: initialize(oracle, finalOwner)
        bytes memory initData = abi.encodeWithSignature("initialize(address,address)", oracleAddr, address(this));

        // Deploy proxy
        deployProxy(key, address(implementation), initData, "MockMinter", type(MockMinter).creationCode, address(this));
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

    function setUp() public override {
        super.setUp();
        deployment = new MockDeploymentDependency();
        deployment.start(TEST_NETWORK, TEST_SALT, "");
    }

    function test_SimpleDependency() public {
        // Deploy oracle first
        address oracleAddr = deployment.deployOracle("contracts.oracle", 100);

        // Deploy token that depends on oracle
        address tokenAddr = deployment.deployToken("contracts.token", "contracts.oracle", "TestToken", 18);

        assertTrue(tokenAddr != address(0));
        assertTrue(deployment.has("contracts.token"));

        MockToken token = MockToken(tokenAddr);
        assertEq(token.oracle(), oracleAddr);
    }

    function test_ChainedDependencies() public {
        // Deploy in correct order: oracle -> token -> minter
        address oracleAddr = deployment.deployOracle("contracts.oracle", 100);
        address tokenAddr = deployment.deployToken("contracts.token", "contracts.oracle", "TestToken", 18);
        deployment.deployMinter("contracts.minter", "contracts.token", "contracts.oracle");
        address minterAddr = deployment.get("contracts.minter");
        assertNotEq(minterAddr, address(0));

        MockMinter minter = MockMinter(minterAddr);
        assertEq(minter.PEGGED_TOKEN(), tokenAddr);
        assertEq(minter.oracle(), oracleAddr);
    }

    function test_RevertWhen_DependencyNotDeployed() public {
        // Try to deploy token without oracle (get() appends .address to key)
        vm.expectRevert(abi.encodeWithSelector(DeploymentDataMemory.ValueNotSet.selector, "contracts.oracle.address"));
        deployment.deployToken("contracts.token", "contracts.oracle", "TestToken", 18);
    }

    function test_RevertWhen_ChainedDependencyMissing() public {
        // Deploy only oracle, skip token
        deployment.deployOracle("contracts.oracle", 100);

        // Try to deploy minter without token (get() appends .address to key)
        vm.expectRevert(abi.encodeWithSelector(DeploymentDataMemory.ValueNotSet.selector, "contracts.token.address"));
        deployment.deployMinter("contracts.minter", "contracts.token", "contracts.oracle");
    }

    function test_MultipleDependentsOnSameContract() public {
        // Deploy oracle once
        address oracleAddr = deployment.deployOracle("contracts.oracle", 100);

        // Multiple contracts can depend on it
        address token1 = deployment.deployToken("contracts.token1", "contracts.oracle", "Token1", 18);
        address token2 = deployment.deployToken("contracts.token2", "contracts.oracle", "Token2", 6);

        MockToken t1 = MockToken(token1);
        MockToken t2 = MockToken(token2);

        assertEq(t1.oracle(), oracleAddr);
        assertEq(t2.oracle(), oracleAddr);
    }

    function test_GetBeforeDeployment() public {
        // Verify get() works for deployed contracts
        deployment.deployOracle("contracts.oracle", 100);
        address addr = deployment.get("contracts.oracle");
        assertTrue(addr != address(0));

        // Verify get() reverts for non-deployed (get() appends .address to key)
        vm.expectRevert(abi.encodeWithSelector(DeploymentDataMemory.ValueNotSet.selector, "contracts.token.address"));
        deployment.get("contracts.token");
    }

    function test_ComplexDependencyGraph() public {
        // Deploy a complex graph:
        // oracle1, oracle2 -> token1 (uses oracle1) -> minter (uses token1, oracle2)

        deployment.deployOracle("contracts.oracle1", 100);
        address oracle2 = deployment.deployOracle("contracts.oracle2", 200);
        address token1 = deployment.deployToken("contracts.token1", "contracts.oracle1", "Token1", 18);
        deployment.deployMinter("contracts.minter", "contracts.token1", "contracts.oracle2");
        address minter = deployment.get("contracts.minter");

        MockMinter m = MockMinter(minter);
        assertEq(m.PEGGED_TOKEN(), token1);
        assertEq(m.oracle(), oracle2);
    }
}
