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
        addContract("contracts.collateral");
        addContract("contracts.pegged");
        addProxy("contracts.oracle");
        addProxy("contracts.oracle1");
        addProxy("contracts.oracle2");
        addProxy("contracts.oracle3");
        addProxy("contracts.minter");
        addProxy("contracts.minter1");
        addProxy("contracts.minter2");
        addContract("contracts.configLib");
        addContract("contracts.wstETH");
        addContract("contracts.token1");
        addContract("contracts.token2");
        addProxy("contracts.proxy2");
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
        address collateral = _get(collateralKey);
        address pegged = _get(peggedKey);
        address oracle = _get(oracleKey);

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
    string constant TEST_SALT = "DeploymentIntegrationTest";

    function setUp() public override {
        super.setUp();
        admin = address(this);
        deployment = new MockDeploymentIntegration();
    }

    function _startDeployment(string memory network) internal {
        _initDeploymentTest(TEST_SALT, network);
        deployment.start(network, TEST_SALT, "");
    }

    function test_DeployFullSystem() public {
        _startDeployment("test_DeployFullSystem");

        // Deploy tokens
        deployment.deployMockERC20("contracts.collateral", "Wrapped ETH", "wETH");
        deployment.deployMockERC20("contracts.pegged", "USD Stablecoin", "USD");

        // Deploy oracle
        deployment.deployOracleProxy("contracts.oracle", 2000e18, admin);
        // Deploy minter (depends on all above)
        deployment.deployMinterProxy(
            "contracts.minter",
            "contracts.collateral",
            "contracts.pegged",
            "contracts.oracle",
            admin
        );

        // Deploy library
        deployment.deployConfigLibrary("contracts.configLib");

        // Verify all deployed
        assertTrue(deployment.has("contracts.collateral"));
        assertTrue(deployment.has("contracts.pegged"));
        assertTrue(deployment.has("contracts.oracle"));
        assertTrue(deployment.has("contracts.minter"));
        assertTrue(deployment.has("contracts.configLib"));

        // Verify contract functionality
        OracleV1 oracleContract = OracleV1(deployment.get("contracts.oracle"));
        assertEq(oracleContract.price(), 2000e18);
        assertEq(oracleContract.admin(), admin);

        MockMinter minterContract = MockMinter(deployment.get("contracts.minter"));
        assertEq(minterContract.collateralToken(), deployment.get("contracts.collateral"));
        assertEq(minterContract.peggedToken(), deployment.get("contracts.pegged"));
        assertEq(minterContract.oracle(), deployment.get("contracts.oracle"));
    }

    function test_SaveAndLoadFullSystem() public {
        _startDeployment("test_SaveAndLoadFullSystem");

        // Deploy full system (auto-save is automatic)
        deployment.deployMockERC20("contracts.collateral", "wETH", "wETH");
        deployment.deployMockERC20("contracts.pegged", "USD", "USD");
        deployment.deployOracleProxy("contracts.oracle", 2000e18, admin);
        deployment.deployMinterProxy(
            "contracts.minter",
            "contracts.collateral",
            "contracts.pegged",
            "contracts.oracle",
            admin
        );
        deployment.deployConfigLibrary("contracts.configLib");

        deployment.finish();

        // Load into new deployment using 'latest' startPoint
        MockDeploymentIntegration newDeployment = new MockDeploymentIntegration();
        newDeployment.start("test_SaveAndLoadFullSystem", TEST_SALT, "latest");

        // Verify all loaded correctly
        assertTrue(newDeployment.has("contracts.collateral"));
        assertTrue(newDeployment.has("contracts.pegged"));
        assertTrue(newDeployment.has("contracts.oracle"));
        assertTrue(newDeployment.has("contracts.minter"));
        assertTrue(newDeployment.has("contracts.configLib"));

        // Verify addresses match
        assertEq(newDeployment.get("contracts.collateral"), deployment.get("contracts.collateral"));
        assertEq(newDeployment.get("contracts.oracle"), deployment.get("contracts.oracle"));
        assertEq(newDeployment.get("contracts.minter"), deployment.get("contracts.minter"));

        // // Verify entry types
        // assertEq(uint(newDeployment.keyType("contracts.collateral")), uint(DataType.COONTRACT));
        // assertEq(uint(newDeployment.keyType("contracts.oracle")), "proxy");
        // assertEq(uint(newDeployment.keyType("contracts.configLib")), "library");
    }

    function test_DeploymentWithExistingContracts() public {
        _startDeployment("test_DeploymentWithExistingContracts");

        // Use existing mainnet contracts (simulated)
        address wstEth = address(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
        deployment.useExisting("contracts.wstETH", wstEth);

        // Deploy new contracts that depend on existing
        deployment.deployMockERC20("contracts.pegged", "USD", "USD");
        deployment.deployOracleProxy("contracts.oracle", 2000e18, admin);
        deployment.finish();

        // Verify existing contract is in registry
        assertEq(deployment.get("contracts.wstETH"), wstEth);
        assertTrue(deployment.has("contracts.wstETH"));

        // Read autosaved file
        string memory json = deployment.toJson();
        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        assertEq(schemaVersion, 1, "Schema version should be 1");
        address loaded = vm.parseJsonAddress(json, ".contracts.wstETH.address");
        assertEq(loaded, wstEth);

        string memory category = vm.parseJsonString(json, ".contracts.wstETH.category");
        assertEq(category, "existing");
    }

    function test_IncrementalDeployment() public {
        // This test demonstrates incremental deployment across multiple phases
        // Each phase uses setFilename BEFORE start() to get its own output file
        // Phases resume from previous phase's output using the startPoint parameter

        string memory network = "test_IncrementalDeployment";
        _initDeploymentTest(TEST_SALT, network);

        // Phase 1: Deploy tokens
        vm.warp(1000000);
        vm.roll(100);
        MockDeploymentPhase phase1 = new MockDeploymentPhase();
        phase1.setFilename("phase1"); // Set filename BEFORE start
        phase1.start(network, TEST_SALT, "");
        phase1.deployMockERC20("contracts.collateral", "wETH", "wETH");
        phase1.deployMockERC20("contracts.pegged", "USD", "USD");
        phase1.finish();

        // Phase 2: Resume from phase1 and add oracle
        vm.warp(2000000);
        vm.roll(200);
        MockDeploymentPhase phase2 = new MockDeploymentPhase();
        phase2.setFilename("phase2"); // Set filename BEFORE start
        phase2.start(network, TEST_SALT, "phase1"); // Resume from phase1.json
        phase2.deployOracleProxy("contracts.oracle", 2000e18, admin);
        phase2.finish();

        // Phase 3: Resume from phase2 and add minter
        vm.warp(3000000);
        vm.roll(300);
        MockDeploymentPhase phase3 = new MockDeploymentPhase();
        phase3.setFilename("phase3"); // Set filename BEFORE start
        phase3.start(network, TEST_SALT, "phase2"); // Resume from phase2.json
        phase3.deployMinterProxy(
            "contracts.minter",
            "contracts.collateral",
            "contracts.pegged",
            "contracts.oracle",
            admin
        );
        phase3.finish();

        // Verify final state by loading phase3
        MockDeploymentIntegration finalDeployment = new MockDeploymentPhase();
        finalDeployment.start(network, TEST_SALT, "phase3");

        assertTrue(finalDeployment.has("contracts.collateral"));
        assertTrue(finalDeployment.has("contracts.pegged"));
        assertTrue(finalDeployment.has("contracts.oracle"));
        assertTrue(finalDeployment.has("contracts.minter"));
    }

    function test_MultipleProxiesWithSameImplementation() public {
        _startDeployment("test_MultipleProxiesWithSameImplementation");
        // Deploy one implementation
        OracleV1 impl = new OracleV1();

        // Deploy multiple proxies
        bytes memory initData1 = abi.encodeCall(OracleV1.initialize, (1000e18, admin));
        bytes memory initData2 = abi.encodeCall(OracleV1.initialize, (2000e18, admin));
        bytes memory initData3 = abi.encodeCall(OracleV1.initialize, (3000e18, admin));

        deployment.deployProxy(
            "contracts.oracle1",
            address(impl),
            initData1,
            "OracleV1",
            "test/mocks/upgradeable/MockOracle.sol",
            address(this)
        );
        deployment.deployProxy(
            "contracts.oracle2",
            address(impl),
            initData2,
            "OracleV1",
            "test/mocks/upgradeable/MockOracle.sol",
            address(this)
        );
        deployment.deployProxy(
            "contracts.oracle3",
            address(impl),
            initData3,
            "OracleV1",
            "test/mocks/upgradeable/MockOracle.sol",
            address(this)
        );

        // Verify each has different address but same implementation
        assertNotEq(deployment.get("contracts.oracle1"), deployment.get("contracts.oracle2"));
        assertNotEq(deployment.get("contracts.oracle2"), deployment.get("contracts.oracle3"));

        // Verify each has correct initialized value
        assertEq(OracleV1(deployment.get("contracts.oracle1")).price(), 1000e18);
        assertEq(OracleV1(deployment.get("contracts.oracle2")).price(), 2000e18);
        assertEq(OracleV1(deployment.get("contracts.oracle3")).price(), 3000e18);
    }

    function test_ComplexDependencyChain() public {
        _startDeployment("test_ComplexDependencyChain");
        // Build: tokens -> oracle -> minter1 -> minter2 (uses minter1 as collateral)

        deployment.deployMockERC20("contracts.token1", "Token1", "TK1");
        deployment.deployMockERC20("contracts.token2", "Token2", "TK2");
        deployment.deployOracleProxy("contracts.oracle", 1000e18, admin);
        deployment.deployMinterProxy(
            "contracts.minter1",
            "contracts.token1",
            "contracts.token2",
            "contracts.oracle",
            admin
        );

        // Now deploy minter2 that depends on minter1
        // Constructor: immutable token addresses
        MockMinter minter2Impl = new MockMinter(
            deployment.get("contracts.minter1"),
            deployment.get("contracts.token2"),
            deployment.get("contracts.oracle")
        );
        // Initialize: oracle (has update function), owner
        bytes memory initData = abi.encodeCall(MockMinter.initialize, (deployment.get("contracts.oracle"), admin));
        deployment.deployProxy(
            "contracts.minter2",
            address(minter2Impl),
            initData,
            "MockMinter",
            "test/mocks/upgradeable/MockMinter.sol",
            address(this)
        );

        // Verify dependency chain
        MockMinter m2 = MockMinter(deployment.get("contracts.minter2"));
        assertEq(m2.collateralToken(), deployment.get("contracts.minter1"));
        assertEq(m2.oracle(), deployment.get("contracts.oracle"));
    }
}
