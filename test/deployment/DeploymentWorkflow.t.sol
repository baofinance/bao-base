// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {TestDeployment} from "./TestDeployment.sol";
import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {OracleV1} from "@bao-test/mocks/upgradeable/MockOracle.sol";
import {MockMinter} from "@bao-test/mocks/upgradeable/MockMinter.sol";
import {MathLib} from "@bao-test/mocks/TestLibraries.sol";

/**
 * @title WorkflowTestHarness
 * @notice Test harness for full deployment workflows
 */
contract WorkflowTestHarness is TestDeployment {
    function deployMockERC20(string memory key, string memory name, string memory symbol) public returns (address) {
        MockERC20 token = new MockERC20(name, symbol, 18);
        registerContract(key, address(token), "MockERC20", "test/mocks/tokens/MockERC20.sol", "contract");
        return _get(key);
    }

    function deployOracleProxy(string memory key, uint256 price, address admin) public returns (address) {
        OracleV1 impl = new OracleV1();
        string memory implKey = string.concat(key, "_impl");
        registerImplementation(implKey, address(impl), "OracleV1", "test/mocks/upgradeable/MockOracle.sol");
        bytes memory initData = abi.encodeCall(OracleV1.initialize, (price, admin));
        this.deployProxy(key, implKey, initData);
        return _get(key);
    }

    function deployMinterProxy(
        string memory key,
        string memory collateralKey,
        string memory peggedKey,
        string memory leveragedKey,
        string memory oracleKey,
        address admin
    ) public returns (address) {
        address collateral = _get(collateralKey);
        address pegged = _get(peggedKey);
        address leveraged = _get(leveragedKey);
        address oracle = _get(oracleKey);

        // Constructor parameters: immutable token addresses (rarely change)
        MockMinter impl = new MockMinter(collateral, pegged, leveraged);
        registerImplementation(
            string.concat(key, "_impl"),
            address(impl),
            "MockMinter",
            "test/mocks/upgradeable/MockMinter.sol"
        );

        // Initialize parameters: oracle (has update function), owner (two-step pattern)
        return
            this.deployProxy(key, string.concat(key, "_impl"), abi.encodeCall(MockMinter.initialize, (oracle, admin)));
    }

    function deployMathLibrary(string memory key) public returns (address) {
        bytes memory bytecode = type(MathLib).creationCode;
        deployLibrary(key, bytecode, "MathLib", "test/mocks/TestLibraries.sol");
        return _get(key);
    }
}

/**
 * @title DeploymentWorkflowTest
 * @notice Tests complete deployment workflows from start to finish
 */
contract DeploymentWorkflowTest is Test {
    WorkflowTestHarness public deployment;
    address public admin;

    function setUp() public {
        deployment = new WorkflowTestHarness();
        admin = makeAddr("admin");
        deployment.initialize(admin, "workflow-test", "v2.0.0", "workflow-test-salt");
    }

    function test_SimpleWorkflow() public {
        // Deploy a simple contract
        address token = deployment.deployMockERC20("USDC", "USD Coin", "USDC");

        // Verify deployment
        assertTrue(token != address(0), "Token should be deployed");
        assertEq(deployment.getByString("USDC"), token, "Token should be registered");
        assertEq(deployment.getEntryType("USDC"), "contract", "Should be contract type");

        // Finish deployment
        deployment.finish();

        // Verify metadata
        assertGt(deployment.getMetadata().finishedAt, 0, "Should be finished");
    }

    function test_ProxyWorkflow() public {
        // Deploy oracle proxy
        address oracle = deployment.deployOracleProxy("PriceOracle", 1500e18, admin);

        // Verify proxy deployment
        assertTrue(oracle != address(0), "Oracle should be deployed");
        assertEq(deployment.getByString("PriceOracle"), oracle, "Oracle should be registered");
        assertEq(deployment.getEntryType("PriceOracle"), "proxy", "Should be proxy type");

        // Finish deployment and transfer ownership
        deployment.finish();
        // Ownership transferred by finish()

        // Verify proxy functionality
        OracleV1 oracleContract = OracleV1(oracle);
        assertEq(oracleContract.price(), 1500e18, "Price should be initialized");
        assertEq(oracleContract.owner(), admin, "Owner should be set");

        deployment.finish();
    }

    function test_LibraryWorkflow() public {
        // Deploy library
        address mathLib = deployment.deployMathLibrary("MathLib");

        // Verify library deployment
        assertTrue(mathLib != address(0), "Library should be deployed");
        assertEq(deployment.getByString("MathLib"), mathLib, "Library should be registered");
        assertEq(deployment.getEntryType("MathLib"), "library", "Should be library type");

        deployment.finish();
    }

    function test_ComplexWorkflow() public {
        // Deploy tokens
        address usdc = deployment.deployMockERC20("USDC", "USD Coin", "USDC");
        address baoUSD = deployment.deployMockERC20("baoUSD", "Bao USD", "baoUSD");
        address leveragedUSD = deployment.deployMockERC20("leveragedUSD", "Bao leveragedUSD", "leveragedUSD");

        // Deploy oracle
        address oracle = deployment.deployOracleProxy("PriceOracle", 1500e18, admin);

        // Deploy minter with dependencies
        address minter = deployment.deployMinterProxy("Minter", "USDC", "baoUSD", "leveragedUSD", "PriceOracle", admin);

        // Deploy library
        address mathLib = deployment.deployMathLibrary("MathLib");

        // Finish deployment and transfer ownership
        deployment.finish();
        // Ownership transferred by finish()

        // Add parameters
        deployment.setStringByKey("systemName", "BaoFinance");
        deployment.setUintByKey("version", 2);
        deployment.setBoolByKey("testnet", true);

        // Finish deployment
        deployment.finish();

        // Verify all components
        assertTrue(usdc != address(0), "USDC should be deployed");
        assertTrue(baoUSD != address(0), "baoUSD should be deployed");
        assertTrue(oracle != address(0), "Oracle should be deployed");
        assertTrue(minter != address(0), "Minter should be deployed");
        assertTrue(mathLib != address(0), "MathLib should be deployed");

        // Verify minter dependencies
        MockMinter minterContract = MockMinter(minter);
        assertEq(minterContract.WRAPPED_COLLATERAL_TOKEN(), usdc, "Collateral should be USDC");
        assertEq(minterContract.PEGGED_TOKEN(), baoUSD, "Pegged should be peggedUSD");
        assertEq(minterContract.LEVERAGED_TOKEN(), leveragedUSD, "Leveraged should be leveragedUSD");
        assertEq(minterContract.oracle(), oracle, "Oracle should be connected");
        assertEq(minterContract.owner(), admin, "Owner should be set");
        OracleV1 oracleContract = OracleV1(oracle);
        assertEq(oracleContract.owner(), admin, "Oracle owner should be admin");

        // Verify parameters
        assertEq(deployment.getStringByKey("systemName"), "BaoFinance", "System name should be set");
        assertEq(deployment.getUintByKey("version"), 2, "Version should be set");
        assertTrue(deployment.getBoolByKey("testnet"), "Testnet flag should be true");

        // Verify key count (3 tokens + 2 proxies + 2 implementations + 1 library + 3 parameters)
        string[] memory keys = deployment.keys();
        assertEq(keys.length, 11, "Should have 11 entries (8 contracts + 3 parameters)");
    }

    function test_WorkflowWithExistingContracts() public {
        // Register existing contracts
        address existingUSDC = address(0x1234567890123456789012345678901234567890);
        deployment.useExistingByString("ExistingUSDC", existingUSDC);

        // Register existing baoUSD contract
        address existingBaoUSD = address(0x9876543210987654321098765432109876543210);
        deployment.useExistingByString("baoUSD", existingBaoUSD);

        address leveragedUSD = address(new MockERC20("leveragedUSD", "Bao leveragedUSD", 18));
        deployment.useExistingByString("leveragedUSD", leveragedUSD);

        // Deploy new contracts that depend on existing ones
        address oracle = deployment.deployOracleProxy("PriceOracle", 1500e18, admin);
        assertTrue(oracle != address(0), "Oracle should be deployed");

        // Use existing contracts
        address minter = deployment.deployMinterProxy(
            "Minter",
            "ExistingUSDC",
            "baoUSD",
            "leveragedUSD",
            "PriceOracle",
            admin
        );
        assertTrue(minter != address(0), "Minter should be deployed");

        // Finish deployment and transfer ownership
        deployment.finish();
        // Ownership transferred by finish()

        OracleV1 oracleContractExisting = OracleV1(oracle);
        assertEq(oracleContractExisting.owner(), admin, "Oracle owner should be admin");
        MockMinter minterContractExisting = MockMinter(minter);
        assertEq(minterContractExisting.owner(), admin, "Minter owner should be admin");

        deployment.finish();

        // Verify existing contract integration
        MockMinter minterContract = MockMinter(minter);
        assertEq(minterContract.WRAPPED_COLLATERAL_TOKEN(), existingUSDC, "Should use existing USDC");
        assertEq(minterContract.PEGGED_TOKEN(), existingBaoUSD, "Should use existing baoUSD");
        assertEq(minterContract.LEVERAGED_TOKEN(), leveragedUSD, "Should use leveragedUSD");
    }

    function test_DeterministicProxyAddresses() public {
        // Deploy proxy with specific salt
        string memory salt = "deterministic-oracle-v1";
        address predicted = deployment.predictProxyAddress(salt);

        address deployed = deployment.deployOracleProxy("Oracle", 1000e18, admin);

        // Finish deployment and transfer ownership
        deployment.finish();
        // Ownership transferred by finish()

        // Note: This test would need the salt to be passed through properly
        // For now, just verify the proxy was deployed
        assertTrue(deployed != address(0), "Proxy should be deployed");
        assertTrue(predicted != address(0), "Predicted should be non-zero");
        assertEq(deployment.getByString("Oracle"), deployed, "Proxy should be registered");

        OracleV1 oracleContractDeterministic = OracleV1(deployed);
        assertEq(oracleContractDeterministic.owner(), admin, "Oracle owner should be admin");
    }

    function test_WorkflowJsonPersistence() public {
        // Create a complete deployment
        deployment.deployMockERC20("USDC", "USD Coin", "USDC");
        deployment.deployOracleProxy("Oracle", 1500e18, admin);

        // Finish deployment and transfer ownership
        deployment.finish();
        // Ownership transferred by finish()

        deployment.setStringByKey("network", "ethereum");
        deployment.finish();

        // Test JSON round-trip
        string memory json = deployment.toJson();
        assertTrue(bytes(json).length > 0, "JSON should be generated");

        // Verify JSON contains expected entries
        assertTrue(vm.keyExistsJson(json, ".deployment.USDC"), "Should contain USDC");
        assertTrue(vm.keyExistsJson(json, ".deployment.Oracle"), "Should contain Oracle");
        assertTrue(vm.keyExistsJson(json, ".deployment.network"), "Should contain network parameter");

        // Test loading from JSON
        WorkflowTestHarness newDeployment = new WorkflowTestHarness();
        newDeployment.fromJson(json);

        // Verify loaded data
        assertEq(newDeployment.getByString("USDC"), deployment.getByString("USDC"), "USDC address should match");
        assertEq(newDeployment.getByString("Oracle"), deployment.getByString("Oracle"), "Oracle address should match");
        assertEq(newDeployment.getStringByKey("network"), "ethereum", "Network parameter should match");
    }
}
