// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {Vm} from "forge-std/Vm.sol";
import {DeploymentJsonTesting} from "@bao-script/deployment/DeploymentJsonTesting.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";

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

contract MockMinter is Initializable, UUPSUpgradeable {
    // Constructor parameters: immutable token addresses (rarely change, require upgrade to modify)
    address public immutable collateralToken;
    address public immutable peggedToken;
    address public immutable leveragedToken;

    // Initialize parameters: oracle (has update function), admin (owner)
    address public oracle;
    address public admin;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _collateral, address _pegged, address _leveraged) {
        collateralToken = _collateral;
        peggedToken = _pegged;
        leveragedToken = _leveraged;
    }

    function initialize(address _oracle, address _admin) external initializer {
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
contract MockDeploymentIntegration is DeploymentJsonTesting {
    constructor() {
        // Register all possible contract keys used in tests
        addContract("collateral");
        addContract("pegged");
        addProxy("oracle");
        addProxy("oracle1");
        addProxy("oracle2");
        addProxy("oracle3");
        addProxy("minter");
        addProxy("minter1");
        addProxy("minter2");
        addContract("configLib");
        addContract("wstETH");
        addContract("token1");
        addContract("token2");
        addProxy("proxy2");
    }

    function deployMockERC20(string memory key, string memory name, string memory symbol) public {
        MockERC20 token = new MockERC20(name, symbol, 18);
        registerContract(key, address(token), "MockERC20", "test/mocks/tokens/MockERC20.sol", address(this));
    }

    function deployOracleProxy(string memory key, uint256 price, address admin) public {
        OracleV1 impl = new OracleV1();
        bytes memory initData = abi.encodeCall(OracleV1.initialize, (price, admin));
        this.deployProxy(
            key,
            address(impl),
            initData,
            "OracleV1",
            "test/mocks/upgradeable/MockOracle.sol",
            address(this)
        );
    }

    function deployMinterProxy(
        string memory key,
        string memory collateralKey,
        string memory peggedKey,
        string memory oracleKey,
        address admin
    ) public {
        address collateral = get(collateralKey);
        address pegged = get(peggedKey);
        address oracle = get(oracleKey);

        // Constructor parameters: immutable token addresses (rarely change, require upgrade to modify)
        MockMinter impl = new MockMinter(collateral, pegged, oracle);
        // Initialize parameters: oracle (has update function), owner (two-step pattern)
        bytes memory initData = abi.encodeCall(MockMinter.initialize, (oracle, admin));
        this.deployProxy(
            key,
            address(impl),
            initData,
            "MockMinter",
            "test/mocks/upgradeable/MockMinter.sol",
            address(this)
        );
    }

    function deployConfigLibrary(string memory key) public {
        bytes memory bytecode = type(ConfigLib).creationCode;
        deployLibrary(key, bytecode, "ConfigLib", "test/ConfigLib.sol", address(this));
    }
}

/**
 * @title MockDeploymentPhase
 * @notice Simplified deployment harness for incremental deployment testing
 * @dev Used for test_IncrementalDeployment without snapshot functionality
 */
contract MockDeploymentPhase is MockDeploymentIntegration {
    // Phase snapshots removed - rely on autosave functionality instead
}

/**
 * @title DeploymentIntegrationTest
 * @notice End-to-end integration tests with complex scenarios
 */
contract DeploymentIntegrationTest is BaoDeploymentTest {
    MockDeploymentIntegration public deployment;
    address public admin;
    string constant TEST_NETWORK = "test-network";
    string constant TEST_SALT = "integration-test-salt";

    function setUp() public override {
        super.setUp();
        admin = address(this);
        deployment = new MockDeploymentIntegration();
        _resetDeploymentLogs(TEST_SALT, TEST_NETWORK, "{}");
        deployment.start(TEST_NETWORK, TEST_SALT, "");
    }

    function test_DeployFullSystem() public {
        // Deploy tokens
        deployment.deployMockERC20("collateral", "Wrapped ETH", "wETH");
        deployment.deployMockERC20("pegged", "USD Stablecoin", "USD");

        // Deploy oracle
        deployment.deployOracleProxy("oracle", 2000e18, admin);
        // Deploy minter (depends on all above)
        deployment.deployMinterProxy("minter", "collateral", "pegged", "oracle", admin);

        // Deploy library
        deployment.deployConfigLibrary("configLib");

        // Verify all deployed
        assertTrue(deployment.has("collateral"));
        assertTrue(deployment.has("pegged"));
        assertTrue(deployment.has("oracle"));
        assertTrue(deployment.has("minter"));
        assertTrue(deployment.has("configLib"));

        // Verify contract functionality
        OracleV1 oracleContract = OracleV1(deployment.get("oracle"));
        assertEq(oracleContract.price(), 2000e18);
        assertEq(oracleContract.admin(), admin);

        MockMinter minterContract = MockMinter(deployment.get("minter"));
        assertEq(minterContract.collateralToken(), deployment.get("collateral"));
        assertEq(minterContract.peggedToken(), deployment.get("pegged"));
        assertEq(minterContract.oracle(), deployment.get("oracle"));

        // Verify keys (collateral, pegged, oracle__OracleV1, oracle, minter__MockMinter, minter, configLib = 7)
        string[] memory keys = deployment.keys();
        assertEq(keys.length, 7);
    }

    function test_SaveAndLoadFullSystem() public {
        // Deploy full system (auto-save is automatic)
        deployment.deployMockERC20("collateral", "wETH", "wETH");
        deployment.deployMockERC20("pegged", "USD", "USD");
        deployment.deployOracleProxy("oracle", 2000e18, admin);
        deployment.deployMinterProxy("minter", "collateral", "pegged", "oracle", admin);
        deployment.deployConfigLibrary("configLib");

        deployment.finish();

        // Load into new deployment using 'latest' startPoint
        MockDeploymentIntegration newDeployment = new MockDeploymentIntegration();
        newDeployment.start(TEST_NETWORK, TEST_SALT, "latest");

        // Verify all loaded correctly
        assertTrue(newDeployment.has("collateral"));
        assertTrue(newDeployment.has("pegged"));
        assertTrue(newDeployment.has("oracle"));
        assertTrue(newDeployment.has("minter"));
        assertTrue(newDeployment.has("configLib"));

        // Verify addresses match
        assertEq(newDeployment.get("collateral"), deployment.get("collateral"));
        assertEq(newDeployment.get("oracle"), deployment.get("oracle"));
        assertEq(newDeployment.get("minter"), deployment.get("minter"));

        // // Verify entry types
        // assertEq(uint(newDeployment.keyType("collateral")), uint(DataType.COONTRACT));
        // assertEq(uint(newDeployment.keyType("oracle")), "proxy");
        // assertEq(uint(newDeployment.keyType("configLib")), "library");
    }

    function test_DeploymentWithExistingContracts() public {
        // Use existing mainnet contracts (simulated)
        address wstEth = address(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
        deployment.useExisting("wstETH", wstEth);

        // Deploy new contracts that depend on existing
        deployment.deployMockERC20("pegged", "USD", "USD");
        deployment.deployOracleProxy("oracle", 2000e18, admin);
        deployment.finish();

        // Verify existing contract is in registry
        assertEq(deployment.get("wstETH"), wstEth);
        assertTrue(deployment.has("wstETH"));

        // Read autosaved file
        string memory json = deployment.toJson();
        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");
        address loaded = vm.parseJsonAddress(json, ".deployment.wstETH.address");
        assertEq(loaded, wstEth);

        string memory category = vm.parseJsonString(json, ".deployment.wstETH.category");
        assertEq(category, "existing");
    }

    function test_IncrementalDeployment() public {
        // Use unique salt to avoid conflicts with other tests
        string memory incrementalSalt = "integration-incremental-salt";
        _resetDeploymentLogs(incrementalSalt, TEST_NETWORK, "{}");
        // Phase 1: Deploy tokens with autosave
        vm.warp(1000000); // Set initial timestamp
        vm.roll(100); // Set initial block number
        MockDeploymentPhase phase1 = new MockDeploymentPhase();
        phase1.start(TEST_NETWORK, incrementalSalt, "");
        phase1.deployMockERC20("collateral", "wETH", "wETH");
        phase1.deployMockERC20("pegged", "USD", "USD");
        phase1.finish(); // autosaves

        // Phase 2: Resume and add oracle (simulate time passing)
        vm.warp(2000000); // Advance timestamp by 1M seconds
        vm.roll(200); // Advance by 100 blocks
        MockDeploymentPhase phase2 = new MockDeploymentPhase();
        phase2.start(TEST_NETWORK, incrementalSalt, "latest");
        phase2.deployOracleProxy("oracle", 2000e18, admin);
        phase2.finish(); // autosaves

        // Phase 3: Resume and add minter (simulate more time passing)
        vm.warp(3000000); // Advance timestamp by another 1M seconds
        vm.roll(300); // Advance by another 100 blocks
        MockDeploymentPhase phase3 = new MockDeploymentPhase();
        phase3.start(TEST_NETWORK, incrementalSalt, "latest");
        phase3.deployMinterProxy("minter", "collateral", "pegged", "oracle", admin);
        phase3.finish(); // autosaves

        // Verify final state
        MockDeploymentIntegration finalDeployment = new MockDeploymentPhase();
        finalDeployment.start(TEST_NETWORK, incrementalSalt, "latest");

        assertTrue(finalDeployment.has("collateral"));
        assertTrue(finalDeployment.has("pegged"));
        assertTrue(finalDeployment.has("oracle"));
        assertTrue(finalDeployment.has("minter"));
    }

    function test_MultipleProxiesWithSameImplementation() public {
        // Deploy one implementation
        OracleV1 impl = new OracleV1();

        // Deploy multiple proxies
        bytes memory initData1 = abi.encodeCall(OracleV1.initialize, (1000e18, admin));
        bytes memory initData2 = abi.encodeCall(OracleV1.initialize, (2000e18, admin));
        bytes memory initData3 = abi.encodeCall(OracleV1.initialize, (3000e18, admin));

        deployment.deployProxy(
            "oracle1",
            address(impl),
            initData1,
            "OracleV1",
            "test/mocks/upgradeable/MockOracle.sol",
            address(this)
        );
        deployment.deployProxy(
            "oracle2",
            address(impl),
            initData2,
            "OracleV1",
            "test/mocks/upgradeable/MockOracle.sol",
            address(this)
        );
        deployment.deployProxy(
            "oracle3",
            address(impl),
            initData3,
            "OracleV1",
            "test/mocks/upgradeable/MockOracle.sol",
            address(this)
        );

        // Verify each has different address but same implementation
        assertNotEq(deployment.get("oracle1"), deployment.get("oracle2"));
        assertNotEq(deployment.get("oracle2"), deployment.get("oracle3"));

        // Verify each has correct initialized value
        assertEq(OracleV1(deployment.get("oracle1")).price(), 1000e18);
        assertEq(OracleV1(deployment.get("oracle2")).price(), 2000e18);
        assertEq(OracleV1(deployment.get("oracle3")).price(), 3000e18);
    }

    function test_ComplexDependencyChain() public {
        // Build: tokens -> oracle -> minter1 -> minter2 (uses minter1 as collateral)

        deployment.deployMockERC20("token1", "Token1", "TK1");
        deployment.deployMockERC20("token2", "Token2", "TK2");
        deployment.deployOracleProxy("oracle", 1000e18, admin);
        deployment.deployMinterProxy("minter1", "token1", "token2", "oracle", admin);

        // Now deploy minter2 that depends on minter1
        // Constructor: immutable token addresses
        MockMinter minter2Impl = new MockMinter(
            deployment.get("minter1"),
            deployment.get("token2"),
            deployment.get("oracle")
        );
        // Initialize: oracle (has update function), owner
        bytes memory initData = abi.encodeCall(MockMinter.initialize, (deployment.get("oracle"), admin));
        deployment.deployProxy(
            "minter2",
            address(minter2Impl),
            initData,
            "MockMinter",
            "test/mocks/upgradeable/MockMinter.sol",
            address(this)
        );

        // Verify dependency chain
        MockMinter m2 = MockMinter(deployment.get("minter2"));
        assertEq(m2.collateralToken(), deployment.get("minter1"));
        assertEq(m2.oracle(), deployment.get("oracle"));
    }
}
