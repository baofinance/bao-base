// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {TestDeployment} from "./TestDeployment.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {MockERC20} from "../mocks/tokens/MockERC20.sol";

contract OracleV1 is Initializable, UUPSUpgradeable {
    uint256 public price;
    address public admin;

    function initialize(uint256 _price, address _admin) external initializer {
        price = _price;
        admin = _admin;
    }

    function setPrice(uint256 _price) external {
        require(msg.sender == admin, "Not admin");
        price = _price;
    }

    function _authorizeUpgrade(address) internal view override {
        require(msg.sender == admin, "Not admin");
    }
}

contract MinterV1 is Initializable, UUPSUpgradeable {
    address public collateralToken;
    address public peggedToken;
    address public oracle;
    address public admin;

    function initialize(address _collateral, address _pegged, address _oracle, address _admin) external initializer {
        collateralToken = _collateral;
        peggedToken = _pegged;
        oracle = _oracle;
        admin = _admin;
    }

    function _authorizeUpgrade(address) internal view override {
        require(msg.sender == admin, "Not admin");
    }
}

library ConfigLib {
    struct Config {
        uint256 fee;
        uint256 maxAmount;
    }

    function validate(Config memory cfg) internal pure returns (bool) {
        return cfg.fee <= 10000 && cfg.maxAmount > 0;
    }
}

// Integration test harness
contract IntegrationTestHarness is TestDeployment {
    function deployMockERC20(string memory key, string memory name, string memory symbol) public returns (address) {
        MockERC20 token = new MockERC20(name, symbol, 18);
        return registerContract(key, address(token), "MockERC20", "test/mocks/tokens/MockERC20.sol", "mock");
    }

    function deployOracleProxy(string memory key, uint256 price, address admin) public returns (address) {
        OracleV1 impl = new OracleV1();
        bytes memory initData = abi.encodeCall(OracleV1.initialize, (price, admin));
        return deployProxy(key, address(impl), initData, string.concat(key, "-salt"));
    }

    function deployMinterProxy(
        string memory key,
        string memory collateralKey,
        string memory peggedKey,
        string memory oracleKey,
        address admin
    ) public returns (address) {
        address collateral = _get(collateralKey);
        address pegged = _get(peggedKey);
        address oracle = _get(oracleKey);

        MinterV1 impl = new MinterV1();
        bytes memory initData = abi.encodeCall(MinterV1.initialize, (collateral, pegged, oracle, admin));
        return deployProxy(key, address(impl), initData, string.concat(key, "-salt"));
    }

    function deployConfigLibrary(string memory key) public returns (address) {
        bytes memory bytecode = type(ConfigLib).creationCode;
        return deployLibrary(key, bytecode, "ConfigLib", "test/ConfigLib.sol");
    }
}

/**
 * @title DeploymentIntegrationTest
 * @notice End-to-end integration tests with complex scenarios
 */
contract DeploymentIntegrationTest is Test {
    IntegrationTestHarness public deployment;
    address public admin;
    string constant TEST_OUTPUT_DIR = "results/deployment";

    function setUp() public {
        admin = address(this);
        deployment = new IntegrationTestHarness();
        deployment.startDeployment(admin, "test-network", "v1.0.0");
    }

    function test_DeployFullSystem() public {
        // Deploy tokens
        address collateral = deployment.deployMockERC20("collateral", "Wrapped ETH", "wETH");
        address pegged = deployment.deployMockERC20("pegged", "USD Stablecoin", "USD");

        // Deploy oracle
        address oracle = deployment.deployOracleProxy("oracle", 2000e18, admin);

        // Deploy minter (depends on all above)
        address minter = deployment.deployMinterProxy("minter", "collateral", "pegged", "oracle", admin);

        // Deploy library
        deployment.deployConfigLibrary("configLib");

        // Verify all deployed
        assertTrue(deployment.hasByString("collateral"));
        assertTrue(deployment.hasByString("pegged"));
        assertTrue(deployment.hasByString("oracle"));
        assertTrue(deployment.hasByString("minter"));
        assertTrue(deployment.hasByString("configLib"));

        // Verify contract functionality
        OracleV1 oracleContract = OracleV1(oracle);
        assertEq(oracleContract.price(), 2000e18);
        assertEq(oracleContract.admin(), admin);

        MinterV1 minterContract = MinterV1(minter);
        assertEq(minterContract.collateralToken(), collateral);
        assertEq(minterContract.peggedToken(), pegged);
        assertEq(minterContract.oracle(), oracle);

        // Verify keys
        string[] memory keys = deployment.keys();
        assertEq(keys.length, 5);
    }

    function test_SaveAndLoadFullSystem() public {
        string memory path = string.concat(TEST_OUTPUT_DIR, "/integration-full.json");
        // Deploy full system
        deployment.deployMockERC20("collateral", "wETH", "wETH");
        deployment.deployMockERC20("pegged", "USD", "USD");
        deployment.deployOracleProxy("oracle", 2000e18, admin);
        deployment.deployMinterProxy("minter", "collateral", "pegged", "oracle", admin);
        deployment.deployConfigLibrary("configLib");

        deployment.finishDeployment();
        deployment.saveToJson(path);

        // Load into new deployment
        IntegrationTestHarness newDeployment = new IntegrationTestHarness();
        newDeployment.loadFromJson(path);

        // Verify all loaded correctly
        assertTrue(newDeployment.hasByString("collateral"));
        assertTrue(newDeployment.hasByString("pegged"));
        assertTrue(newDeployment.hasByString("oracle"));
        assertTrue(newDeployment.hasByString("minter"));
        assertTrue(newDeployment.hasByString("configLib"));

        // Verify addresses match
        assertEq(newDeployment.getByString("collateral"), deployment.getByString("collateral"));
        assertEq(newDeployment.getByString("oracle"), deployment.getByString("oracle"));
        assertEq(newDeployment.getByString("minter"), deployment.getByString("minter"));

        // Verify entry types
        assertEq(newDeployment.getEntryType("collateral"), "contract");
        assertEq(newDeployment.getEntryType("oracle"), "proxy");
        assertEq(newDeployment.getEntryType("configLib"), "library");
    }

    function test_DeploymentWithExistingContracts() public {
        string memory path = string.concat(TEST_OUTPUT_DIR, "/integration-existing.json");
        // Use existing mainnet contracts (simulated)
        address wstEth = address(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
        deployment.useExistingByString("wstETH", wstEth);

        // Deploy new contracts that depend on existing
        deployment.deployMockERC20("pegged", "USD", "USD");
        deployment.deployOracleProxy("oracle", 2000e18, admin);

        // Verify existing contract is in registry
        assertEq(deployment.getByString("wstETH"), wstEth);
        assertTrue(deployment.hasByString("wstETH"));

        // Should be able to save with existing contracts
        deployment.saveToJson(path);

        string memory json = vm.readFile(path);
        address loaded = vm.parseJsonAddress(json, ".deployment.wstETH.address");
        assertEq(loaded, wstEth);

        string memory category = vm.parseJsonString(json, ".deployment.wstETH.category");
        assertEq(category, "existing");
    }

    function test_IncrementalDeployment() public {
        string memory path = string.concat(TEST_OUTPUT_DIR, "/integration-incremental.json");
        // Phase 1: Deploy tokens
        deployment.deployMockERC20("collateral", "wETH", "wETH");
        deployment.deployMockERC20("pegged", "USD", "USD");
        deployment.saveToJson(path);

        // Phase 2: Load and add oracle
        IntegrationTestHarness phase2 = new IntegrationTestHarness();
        phase2.loadFromJson(path);
        phase2.deployOracleProxy("oracle", 2000e18, admin);
        phase2.saveToJson(path);

        // Phase 3: Load and add minter
        IntegrationTestHarness phase3 = new IntegrationTestHarness();
        phase3.loadFromJson(path);
        phase3.deployMinterProxy("minter", "collateral", "pegged", "oracle", admin);
        phase3.saveToJson(path);

        // Verify final state
        IntegrationTestHarness finalDeployment = new IntegrationTestHarness();
        finalDeployment.loadFromJson(path);

        assertTrue(finalDeployment.hasByString("collateral"));
        assertTrue(finalDeployment.hasByString("pegged"));
        assertTrue(finalDeployment.hasByString("oracle"));
        assertTrue(finalDeployment.hasByString("minter"));
    }

    function test_MultipleProxiesWithSameImplementation() public {
        // Deploy one implementation
        OracleV1 impl = new OracleV1();

        // Deploy multiple proxies
        bytes memory initData1 = abi.encodeCall(OracleV1.initialize, (1000e18, admin));
        bytes memory initData2 = abi.encodeCall(OracleV1.initialize, (2000e18, admin));
        bytes memory initData3 = abi.encodeCall(OracleV1.initialize, (3000e18, admin));

        address proxy1 = deployment.deployProxy("oracle1", address(impl), initData1, "oracle-1");
        address proxy2 = deployment.deployProxy("oracle2", address(impl), initData2, "oracle-2");
        address proxy3 = deployment.deployProxy("oracle3", address(impl), initData3, "oracle-3");

        // Verify each has different address but same implementation
        assertNotEq(proxy1, proxy2);
        assertNotEq(proxy2, proxy3);

        // Verify each has correct initialized value
        assertEq(OracleV1(proxy1).price(), 1000e18);
        assertEq(OracleV1(proxy2).price(), 2000e18);
        assertEq(OracleV1(proxy3).price(), 3000e18);
    }

    function test_ComplexDependencyChain() public {
        // Build: tokens -> oracle -> minter1 -> minter2 (uses minter1 as collateral)

        deployment.deployMockERC20("token1", "Token1", "TK1");
        address token2 = deployment.deployMockERC20("token2", "Token2", "TK2");
        address oracle = deployment.deployOracleProxy("oracle", 1000e18, admin);
        address minter1 = deployment.deployMinterProxy("minter1", "token1", "token2", "oracle", admin);

        // Now deploy minter2 that depends on minter1
        MinterV1 minter2Impl = new MinterV1();
        bytes memory initData = abi.encodeCall(MinterV1.initialize, (minter1, token2, oracle, admin));
        address minter2 = deployment.deployProxy("minter2", address(minter2Impl), initData, "minter2-salt");

        // Verify dependency chain
        MinterV1 m2 = MinterV1(minter2);
        assertEq(m2.collateralToken(), minter1);
        assertEq(m2.oracle(), oracle);
    }
}
