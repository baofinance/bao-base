// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {Vm} from "forge-std/Vm.sol";
import {DeploymentTesting} from "@bao-script/deployment/DeploymentTesting.sol";
import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {OracleV1} from "@bao-test/mocks/upgradeable/MockOracle.sol";
import {MockMinter} from "@bao-test/mocks/upgradeable/MockMinter.sol";
import {MathLib} from "@bao-test/mocks/TestLibraries.sol";
import {LibString} from "@solady/utils/LibString.sol";

/**
 * @title MockDeploymentWorkflow
 * @notice Test harness for full deployment workflows
 */
contract MockDeploymentWorkflow is DeploymentTesting {
    function deployMockERC20(string memory key, string memory name, string memory symbol) public returns (address) {
        MockERC20 token = new MockERC20(name, symbol, 18);
        registerContract(key, address(token), "MockERC20", "test/mocks/tokens/MockERC20.sol");
        return get(key);
    }

    function deployOracleProxy(string memory key, uint256 price, address admin) public returns (address) {
        OracleV1 impl = new OracleV1();
        string memory implKey = registerImplementation(
            key,
            address(impl),
            "OracleV1",
            "test/mocks/upgradeable/MockOracle.sol"
        );
        bytes memory initData = abi.encodeCall(OracleV1.initialize, (price, admin));
        this.deployProxy(key, implKey, initData);
        return get(key);
    }

    function deployMinterProxy(
        string memory key,
        string memory collateralKey,
        string memory peggedKey,
        string memory leveragedKey,
        string memory oracleKey,
        address admin
    ) public returns (address) {
        address collateral = get(collateralKey);
        address pegged = get(peggedKey);
        address leveraged = get(leveragedKey);
        address oracle = get(oracleKey);

        // Constructor parameters: immutable token addresses (rarely change)
        MockMinter impl = new MockMinter(collateral, pegged, leveraged);
        string memory implKey = registerImplementation(
            key,
            address(impl),
            "MockMinter",
            "test/mocks/upgradeable/MockMinter.sol"
        );

        // Initialize parameters: oracle (has update function), owner (two-step pattern)
        return this.deployProxy(key, implKey, abi.encodeCall(MockMinter.initialize, (oracle, admin)));
    }

    function deployMathLibrary(string memory key) public returns (address) {
        bytes memory bytecode = type(MathLib).creationCode;
        deployLibrary(key, bytecode, "MathLib", "test/mocks/TestLibraries.sol");
        return get(key);
    }
}

/**
 * @title MockDeploymentOperation
 * @notice Captures snapshots after each deployment operation
 * @dev Demonstrates autosave capturing every deploy, register, setParameter, etc.
 */
// TODO:
// contract MockDeploymentOperation is MockDeploymentWorkflow {
//     /// @notice Foundry VM for file operations
//     Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

//     /// @notice Counter for operation snapshots
//     uint256 private _operationCounter;

//     constructor() {
//         _operationCounter = 0;
//     }

//     function _filesuffix() internal view override returns (string memory) {
//         return string.concat("-op", LibString.toString(_operationCounter));
//     }

//     /// @notice Override to save snapshot after each operation
//     /// @dev Captures state after deploy, register, useExisting, setParameter, etc.
//     function _saveRegistry() internal virtual override {
//         super._saveRegistry();
//         _operationCounter++;
//     }
// }

/**
 * @title DeploymentWorkflowTest
 * @notice Tests complete deployment workflows from start to finish
 */
// TODO:
// contract DeploymentWorkflowTest is BaoDeploymentTest {
//     MockDeploymentWorkflow public deployment;
//     address public admin;
//     string constant TEST_NETWORK = "workflow-test";
//     string constant TEST_SALT = "workflow-test-salt";
//     string constant TEST_VERSION = "v2.0.0";

//     function setUp() public override {
//         super.setUp();
//         deployment = new MockDeploymentWorkflow();
//         admin = makeAddr("admin");
//         startDeploymentSession(deployment, admin, TEST_NETWORK, TEST_VERSION, TEST_SALT);
//     }

//     function test_SimpleWorkflow() public {
//         // Deploy a simple contract
//         address token = deployment.deployMockERC20("USDC", "USD Coin", "USDC");

//         // Verify deployment
//         assertTrue(token != address(0), "Token should be deployed");
//         assertEq(deployment.get("USDC"), token, "Token should be registered");
//         assertEq(deployment.getType("USDC"), "contract", "Should be contract type");

//         // Finish deployment
//         deployment.finish();

//         // Verify metadata
//         assertGt(deployment.getMetadata().finishTimestamp, 0, "Should be finished");
//     }

//     function test_OperationSnapshots() public {
//         // Use OperationSnapshotHarness to capture each operation
//         MockDeploymentOperation snapDeployment = new MockDeploymentOperation();
//         startDeploymentSession(snapDeployment, admin, TEST_NETWORK, TEST_VERSION, "workflow-operation-snapshots");
//         snapDeployment.enableAutoSave();

//         // op0: start()
//         // op1: deployMockERC20 - registerContract
//         snapDeployment.deployMockERC20("collateral", "ETH", "ETH");

//         // op2: deployMockERC20 - registerContract
//         snapDeployment.deployMockERC20("pegged", "USD", "USD");

//         // op3: useExisting
//         address existingContract = address(0x1234567890123456789012345678901234567890);
//         vm.etch(existingContract, hex"01"); // Make it non-empty
//         snapDeployment.useExisting("existingToken", existingContract);

//         // op4: setStringByKey parameter
//         snapDeployment.setString("configValue", "testValue");

//         // op5: setUintByKey parameter
//         snapDeployment.setUint("maxSupply", 1000000e18);

//         // op6: setIntByKey parameter
//         snapDeployment.setInt("offset", -100);

//         // op7: setBoolByKey parameter
//         snapDeployment.setBool("enabled", true);

//         // op8: registerImplementation (in deployOracleProxy)
//         // op9: deployProxy
//         snapDeployment.deployOracleProxy("oracle", 2000e18, admin);

//         // op10: upgradeProxy - deploy new implementation and upgrade
//         OracleV1 newImpl = new OracleV1();
//         string memory oracleImplV2Key = snapDeployment.registerImplementation(
//             "oracle_impl_v2",
//             address(newImpl),
//             "OracleV1",
//             "test/mocks/upgradeable/MockOracle.sol"
//         );
//         // op11: upgradeProxy (without initialization data to avoid reinitializing)
//         snapDeployment.upgradeProxy("oracle", oracleImplV2Key, bytes(""));

//         // op12: deployMathLibrary - registerLibrary
//         snapDeployment.deployMathLibrary("mathLib");

//         // op13: finish()
//         snapDeployment.finish();

//         // Verify all operations were captured
//         assertTrue(snapDeployment.has("collateral"));
//         assertTrue(snapDeployment.has("pegged"));
//         assertTrue(snapDeployment.has("existingToken"));
//         assertTrue(snapDeployment.has("oracle"));
//         assertTrue(snapDeployment.has("mathLib"));
//         assertEq(snapDeployment.getString("configValue"), "testValue");
//         assertEq(snapDeployment.getUint("maxSupply"), 1000000e18);
//         assertEq(snapDeployment.getInt("offset"), -100);
//         assertTrue(snapDeployment.getBool("enabled"));
//     }

//     function test_ProxyWorkflow() public {
//         // Deploy oracle proxy
//         address oracle = deployment.deployOracleProxy("PriceOracle", 1500e18, admin);

//         // Verify proxy deployment
//         assertTrue(oracle != address(0), "Oracle should be deployed");
//         assertEq(deployment.get("PriceOracle"), oracle, "Oracle should be registered");
//         assertEq(deployment.getType("PriceOracle"), "proxy", "Should be proxy type");

//         // Finish deployment and transfer ownership
//         deployment.finish();
//         // Ownership transferred by finish()

//         // Verify proxy functionality
//         OracleV1 oracleContract = OracleV1(oracle);
//         assertEq(oracleContract.price(), 1500e18, "Price should be initialized");
//         assertEq(oracleContract.owner(), admin, "Owner should be set");
//     }

//     function test_LibraryWorkflow() public {
//         // Deploy library
//         address mathLib = deployment.deployMathLibrary("MathLib");

//         // Verify library deployment
//         assertTrue(mathLib != address(0), "Library should be deployed");
//         assertEq(deployment.get("MathLib"), mathLib, "Library should be registered");
//         assertEq(deployment.getType("MathLib"), "library", "Should be library type");

//         deployment.finish();
//     }

//     function test_ComplexWorkflow() public {
//         // Enable auto-save to generate workflow-test-salt.json for regression
//         deployment.enableAutoSave();

//         // Deploy tokens
//         address usdc = deployment.deployMockERC20("USDC", "USD Coin", "USDC");
//         address baoUSD = deployment.deployMockERC20("baoUSD", "Bao USD", "baoUSD");
//         address leveragedUSD = deployment.deployMockERC20("leveragedUSD", "Bao leveragedUSD", "leveragedUSD");

//         // Deploy oracle
//         address oracle = deployment.deployOracleProxy("PriceOracle", 1500e18, admin);

//         // Deploy minter with dependencies
//         address minter = deployment.deployMinterProxy("Minter", "USDC", "baoUSD", "leveragedUSD", "PriceOracle", admin);

//         // Deploy library
//         address mathLib = deployment.deployMathLibrary("MathLib");

//         // Finish deployment and transfer ownership
//         deployment.finish();
//         // Ownership transferred by finish()

//         // Add parameters
//         deployment.setString("systemName", "BaoFinance");
//         deployment.setUint("version", 2);
//         deployment.setBool("testnet", true);

//         // Verify all components
//         assertTrue(usdc != address(0), "USDC should be deployed");
//         assertTrue(baoUSD != address(0), "baoUSD should be deployed");
//         assertTrue(oracle != address(0), "Oracle should be deployed");
//         assertTrue(minter != address(0), "Minter should be deployed");
//         assertTrue(mathLib != address(0), "MathLib should be deployed");

//         // Verify minter dependencies
//         MockMinter minterContract = MockMinter(minter);
//         assertEq(minterContract.WRAPPED_COLLATERAL_TOKEN(), usdc, "Collateral should be USDC");
//         assertEq(minterContract.PEGGED_TOKEN(), baoUSD, "Pegged should be peggedUSD");
//         assertEq(minterContract.LEVERAGED_TOKEN(), leveragedUSD, "Leveraged should be leveragedUSD");
//         assertEq(minterContract.oracle(), oracle, "Oracle should be connected");
//         assertEq(minterContract.owner(), admin, "Owner should be set");
//         OracleV1 oracleContract = OracleV1(oracle);
//         assertEq(oracleContract.owner(), admin, "Oracle owner should be admin");

//         // Verify parameters
//         assertEq(deployment.getString("systemName"), "BaoFinance", "System name should be set");
//         assertEq(deployment.getUint("version"), 2, "Version should be set");
//         assertTrue(deployment.getBool("testnet"), "Testnet flag should be true");

//         // Verify key count (3 tokens + 2 proxies + 2 implementations + 1 library + 3 parameters)
//         string[] memory keys = deployment.keys();
//         assertEq(keys.length, 11, "Should have 11 entries (8 contracts + 3 parameters)");
//     }

//     function test_WorkflowWithExistingContracts() public {
//         // Register existing contracts
//         address existingUSDC = address(0x1234567890123456789012345678901234567890);
//         deployment.useExisting("ExistingUSDC", existingUSDC);

//         // Register existing baoUSD contract
//         address existingBaoUSD = address(0x9876543210987654321098765432109876543210);
//         deployment.useExisting("baoUSD", existingBaoUSD);

//         address leveragedUSD = address(new MockERC20("leveragedUSD", "Bao leveragedUSD", 18));
//         deployment.useExisting("leveragedUSD", leveragedUSD);

//         // Deploy new contracts that depend on existing ones
//         address oracle = deployment.deployOracleProxy("PriceOracle", 1500e18, admin);
//         assertTrue(oracle != address(0), "Oracle should be deployed");

//         // Use existing contracts
//         address minter = deployment.deployMinterProxy(
//             "Minter",
//             "ExistingUSDC",
//             "baoUSD",
//             "leveragedUSD",
//             "PriceOracle",
//             admin
//         );
//         assertTrue(minter != address(0), "Minter should be deployed");

//         // Finish deployment and transfer ownership
//         deployment.finish();
//         // Ownership transferred by finish()

//         OracleV1 oracleContractExisting = OracleV1(oracle);
//         assertEq(oracleContractExisting.owner(), admin, "Oracle owner should be admin");
//         MockMinter minterContractExisting = MockMinter(minter);
//         assertEq(minterContractExisting.owner(), admin, "Minter owner should be admin");

//         // Verify existing contract integration
//         MockMinter minterContract = MockMinter(minter);
//         assertEq(minterContract.WRAPPED_COLLATERAL_TOKEN(), existingUSDC, "Should use existing USDC");
//         assertEq(minterContract.PEGGED_TOKEN(), existingBaoUSD, "Should use existing baoUSD");
//         assertEq(minterContract.LEVERAGED_TOKEN(), leveragedUSD, "Should use leveragedUSD");
//     }

//     function test_DeterministicProxyAddresses() public {
//         // Deploy proxy with specific salt
//         string memory salt = "deterministic-oracle-v1";
//         address predicted = deployment.predictProxyAddress(salt);

//         address deployed = deployment.deployOracleProxy("Oracle", 1000e18, admin);

//         // Finish deployment and transfer ownership
//         deployment.finish();
//         // Ownership transferred by finish()

//         // Note: This test would need the salt to be passed through properly
//         // For now, just verify the proxy was deployed
//         assertTrue(deployed != address(0), "Proxy should be deployed");
//         assertTrue(predicted != address(0), "Predicted should be non-zero");
//         assertEq(deployment.get("Oracle"), deployed, "Proxy should be registered");

//         OracleV1 oracleContractDeterministic = OracleV1(deployed);
//         assertEq(oracleContractDeterministic.owner(), admin, "Oracle owner should be admin");
//     }

//     function test_WorkflowJsonPersistence() public {
//         // Create a complete deployment
//         deployment.deployMockERC20("USDC", "USD Coin", "USDC");
//         deployment.deployOracleProxy("Oracle", 1500e18, admin);

//         // Finish deployment and transfer ownership
//         deployment.finish();
//         // Ownership transferred by finish()

//         deployment.setString("network", "ethereum");

//         // Test JSON round-trip
//         string memory json = deployment.toJsonString();
//         assertTrue(bytes(json).length > 0, "JSON should be generated");

//         // Verify JSON contains expected entries
//         assertTrue(vm.keyExistsJson(json, ".deployment.USDC"), "Should contain USDC");
//         assertTrue(vm.keyExistsJson(json, ".deployment.Oracle"), "Should contain Oracle");
//         assertTrue(vm.keyExistsJson(json, ".deployment.network"), "Should contain network parameter");

//         // Test loading from JSON
//         MockDeploymentWorkflow newDeployment = new MockDeploymentWorkflow();
//         newDeployment.fromJson(json);

//         // Verify loaded data
//         assertEq(newDeployment.get("USDC"), deployment.get("USDC"), "USDC address should match");
//         assertEq(newDeployment.get("Oracle"), deployment.get("Oracle"), "Oracle address should match");
//         assertEq(newDeployment.getString("network"), "ethereum", "Network parameter should match");
//     }
// }
