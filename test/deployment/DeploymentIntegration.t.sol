// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockDeployment} from "./MockDeployment.sol";
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
contract IntegrationTestHarness is MockDeployment {
    function deployMockERC20(string memory key, string memory name, string memory symbol) public returns (address) {
        MockERC20 token = new MockERC20(name, symbol, 18);
        registerContract(key, address(token), "MockERC20", "test/mocks/tokens/MockERC20.sol", "mock");
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
        string memory oracleKey,
        address admin
    ) public returns (address) {
        address collateral = _get(collateralKey);
        address pegged = _get(peggedKey);
        address oracle = _get(oracleKey);

        // Constructor parameters: immutable token addresses (rarely change, require upgrade to modify)
        MockMinter impl = new MockMinter(collateral, pegged, oracle);
        string memory implKey = string.concat(key, "_impl");
        registerImplementation(implKey, address(impl), "MockMinter", "test/mocks/upgradeable/MockMinter.sol");

        // Initialize parameters: oracle (has update function), owner (two-step pattern)
        bytes memory initData = abi.encodeCall(MockMinter.initialize, (oracle, admin));
        return this.deployProxy(key, implKey, initData);
    }

    function deployConfigLibrary(string memory key) public returns (address) {
        bytes memory bytecode = type(ConfigLib).creationCode;
        deployLibrary(key, bytecode, "ConfigLib", "test/ConfigLib.sol");
        return _get(key);
    }
}

/**
 * @title PhaseSnapshotHarness
 * @notice Captures snapshots at finish() to show state after each deployment phase
 * @dev Used for test_IncrementalDeployment to capture phase1, phase2, phase3 states
 */
contract PhaseSnapshotHarness is IntegrationTestHarness {
    /// @notice Foundry VM for file operations
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Counter for phase snapshots
    uint256 private _phaseCounter;

    constructor() {
        _phaseCounter = 0;
    }

    /// @notice Override finish to capture phase snapshot
    /// @dev Saves a numbered phase snapshot after each finish() call
    function finish() public override returns (uint256 transferred) {
        transferred = super.finish();

        // Increment phase counter
        _phaseCounter++;

        // Copy the autosaved file to a phase-numbered snapshot
        string memory sourcePath = _filepath();
        string memory destPath = string.concat(
            _removeJsonExtension(sourcePath),
            "-phase",
            _uintToString(_phaseCounter),
            ".json"
        );

        // Read from autosaved file and write to phase snapshot
        string memory content = vm.readFile(sourcePath);
        vm.writeFile(destPath, content);
    }
}

/**
 * @title OperationSnapshotHarness
 * @notice Captures snapshots after each deployment operation for detailed regression testing
 * @dev Used to demonstrate autosave capturing every deploy, register, etc.
 */
contract OperationSnapshotHarness is IntegrationTestHarness {
    /// @notice Counter for operation snapshots
    uint256 private _operationCounter;

    constructor() {
        _operationCounter = 0;
    }

    /// @notice Override to save snapshot after each operation
    /// @dev Captures state after deploy, register, useExisting, setParameter, etc.
    function _saveToRegistry() internal override {
        super._saveToRegistry();

        // Save snapshot with operation counter
        string memory snapshotPath = string.concat(_filepath(), "-op", _uintToString(_operationCounter));
        saveToJson(snapshotPath);
        _operationCounter++;
    }
}

/**
 * @title DeploymentIntegrationTest
 * @notice End-to-end integration tests with complex scenarios
 */
contract DeploymentIntegrationTest is BaoDeploymentTest {
    IntegrationTestHarness public deployment;
    address public admin;
    string constant TEST_OUTPUT_DIR = "results/deployments";
    string constant TEST_NETWORK = "test-network";
    string constant TEST_SALT = "integration-test-salt";
    string constant TEST_VERSION = "v1.0.0";

    function setUp() public {
        super.setUp();
        admin = address(this);
        deployment = new IntegrationTestHarness();
        deployment.start(admin, TEST_NETWORK, TEST_VERSION, TEST_SALT);
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

        MockMinter minterContract = MockMinter(minter);
        assertEq(minterContract.collateralToken(), collateral);
        assertEq(minterContract.peggedToken(), pegged);
        assertEq(minterContract.oracle(), oracle);

        // Verify keys (collateral, pegged, oracle_impl, oracle, minter_impl, minter, configLib = 7)
        string[] memory keys = deployment.keys();
        assertEq(keys.length, 7);
    }

    function test_SaveAndLoadFullSystem() public {
        // Enable auto-save for regression testing
        deployment.enableAutoSave();

        // Deploy full system
        deployment.deployMockERC20("collateral", "wETH", "wETH");
        deployment.deployMockERC20("pegged", "USD", "USD");
        deployment.deployOracleProxy("oracle", 2000e18, admin);
        deployment.deployMinterProxy("minter", "collateral", "pegged", "oracle", admin);
        deployment.deployConfigLibrary("configLib");

        deployment.finish();

        // Load into new deployment (autosave already wrote the file)
        string memory path = string.concat(TEST_OUTPUT_DIR, "/", TEST_SALT, ".json");
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
        // Enable auto-save for regression testing
        deployment.enableAutoSave();

        // Use existing mainnet contracts (simulated)
        address wstEth = address(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
        deployment.useExistingByString("wstETH", wstEth);

        // Deploy new contracts that depend on existing
        deployment.deployMockERC20("pegged", "USD", "USD");
        deployment.deployOracleProxy("oracle", 2000e18, admin);
        deployment.finish();

        // Verify existing contract is in registry
        assertEq(deployment.getByString("wstETH"), wstEth);
        assertTrue(deployment.hasByString("wstETH"));

        // Read autosaved file
        string memory path = string.concat(TEST_OUTPUT_DIR, "/", TEST_SALT, ".json");
        string memory json = vm.readFile(path);
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

        // Phase 1: Deploy tokens with autosave and snapshots
        vm.warp(1000000); // Set initial timestamp
        vm.roll(100); // Set initial block number
        PhaseSnapshotHarness phase1 = new PhaseSnapshotHarness();
        phase1.start(admin, TEST_NETWORK, TEST_VERSION, incrementalSalt);
        phase1.enableAutoSave();
        phase1.deployMockERC20("collateral", "wETH", "wETH");
        phase1.deployMockERC20("pegged", "USD", "USD");
        phase1.finish(); // autosaves and creates phase1 snapshot

        // Phase 2: Resume and add oracle (simulate time passing)
        vm.warp(2000000); // Advance timestamp by 1M seconds
        vm.roll(200); // Advance by 100 blocks
        PhaseSnapshotHarness phase2 = new PhaseSnapshotHarness();
        phase2.resume(TEST_NETWORK, incrementalSalt);
        phase2.enableAutoSave();
        phase2.deployOracleProxy("oracle", 2000e18, admin);
        phase2.finish(); // autosaves and creates phase2 snapshot

        // Phase 3: Resume and add minter (simulate more time passing)
        vm.warp(3000000); // Advance timestamp by another 1M seconds
        vm.roll(300); // Advance by another 100 blocks
        PhaseSnapshotHarness phase3 = new PhaseSnapshotHarness();
        phase3.resume(TEST_NETWORK, incrementalSalt);
        phase3.enableAutoSave();
        phase3.deployMinterProxy("minter", "collateral", "pegged", "oracle", admin);
        phase3.finish(); // autosaves and creates phase3 snapshot

        // Verify final state
        IntegrationTestHarness finalDeployment = new IntegrationTestHarness();
        finalDeployment.resume(TEST_NETWORK, incrementalSalt);

        assertTrue(finalDeployment.hasByString("collateral"));
        assertTrue(finalDeployment.hasByString("pegged"));
        assertTrue(finalDeployment.hasByString("oracle"));
        assertTrue(finalDeployment.hasByString("minter"));
    }

    function test_MultipleProxiesWithSameImplementation() public {
        // Deploy one implementation
        OracleV1 impl = new OracleV1();
        deployment.registerImplementation(
            "oracle_impl",
            address(impl),
            "OracleV1",
            "test/mocks/upgradeable/MockOracle.sol"
        );

        // Deploy multiple proxies
        bytes memory initData1 = abi.encodeCall(OracleV1.initialize, (1000e18, admin));
        bytes memory initData2 = abi.encodeCall(OracleV1.initialize, (2000e18, admin));
        bytes memory initData3 = abi.encodeCall(OracleV1.initialize, (3000e18, admin));

        address proxy1 = deployment.deployProxy("oracle1", "oracle_impl", initData1);
        address proxy2 = deployment.deployProxy("oracle2", "oracle_impl", initData2);
        address proxy3 = deployment.deployProxy("oracle3", "oracle_impl", initData3);

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
        // Constructor: immutable token addresses
        MockMinter minter2Impl = new MockMinter(minter1, token2, oracle);
        deployment.registerImplementation(
            "minter2_impl",
            address(minter2Impl),
            "MockMinter",
            "test/mocks/upgradeable/MockMinter.sol"
        );
        // Initialize: oracle (has update function), owner
        bytes memory initData = abi.encodeCall(MockMinter.initialize, (oracle, admin));
        address minter2 = deployment.deployProxy("minter2", "minter2_impl", initData);

        // Verify dependency chain
        MockMinter m2 = MockMinter(minter2);
        assertEq(m2.collateralToken(), minter1);
        assertEq(m2.oracle(), oracle);
    }
}
