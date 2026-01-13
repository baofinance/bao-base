// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {FactoryDeployer} from "@bao-script/deployment/FactoryDeployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {UUPSProxyDeployStub} from "@bao-script/deployment/UUPSProxyDeployStub.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";

// Import needed for proxy deployment
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Simple UUPS-upgradeable contract for testing deployments.
contract MockUpgradeable is Initializable, UUPSUpgradeable, BaoOwnable {
    uint256 public value;

    function initialize(uint256 value_, address deployerOwner, address pendingOwner) external initializer {
        value = value_;
        _initializeOwner(deployerOwner, pendingOwner);
    }

    function _authorizeUpgrade(address) internal view override onlyOwner {}
}

/// @notice Alternative implementation for testing bytecode mismatch.
contract MockUpgradeableV2 is Initializable, UUPSUpgradeable, BaoOwnable {
    uint256 public value;
    uint256 public newField; // Different storage layout = different bytecode

    function initialize(uint256 value_, address deployerOwner, address pendingOwner) external initializer {
        value = value_;
        _initializeOwner(deployerOwner, pendingOwner);
    }

    function _authorizeUpgrade(address) internal view override onlyOwner {}
}

/// @notice Test harness exposing FactoryDeployer internals.
contract TestableFactoryDeployer is FactoryDeployer {
    address private _treasuryAddr;
    address private _ownerAddr;
    address private _factoryAddr;

    constructor(address treasury_, address owner_, address factory_) {
        _treasuryAddr = treasury_;
        _ownerAddr = owner_;
        _factoryAddr = factory_;
    }

    function treasury() public view override returns (address) {
        return _treasuryAddr;
    }

    function owner() public view override returns (address) {
        return _ownerAddr;
    }

    function baoFactory() public view override returns (address) {
        return _factoryAddr;
    }

    // Expose internal functions for testing

    function setSaltPrefix(string memory prefix) external {
        _setSaltPrefix(prefix);
    }

    function getOrDeployStub() external returns (UUPSProxyDeployStub) {
        return _getOrDeployStub();
    }

    function registerForOwnershipTransfer(address deployed, string memory salt) external {
        _registerForOwnershipTransfer(deployed, salt);
    }

    function transferAllOwnerships() external {
        _transferAllOwnerships();
    }

    function pendingOwnershipCount() external view returns (uint256) {
        return _pendingOwnershipCount();
    }

    function addressLabel(address addr) external view returns (string memory) {
        return _addressLabel(addr);
    }

    function saltString1(string memory part1) external view returns (string memory) {
        return _saltString(part1);
    }

    function saltString2(string memory part1, string memory part2) external view returns (string memory) {
        return _saltString(part1, part2);
    }

    function saltString3(
        string memory part1,
        string memory part2,
        string memory part3
    ) external view returns (string memory) {
        return _saltString(part1, part2, part3);
    }

    function predictAddress1(string memory part1) external view returns (address) {
        return _predictAddress(part1);
    }

    function predictAddress2(string memory part1, string memory part2) external view returns (address) {
        return _predictAddress(part1, part2);
    }

    function predictAddress3(
        string memory part1,
        string memory part2,
        string memory part3
    ) external view returns (address) {
        return _predictAddress(part1, part2, part3);
    }

    /// @dev Returns both proxy and modified state since external calls work on copies.
    function deployProxyAndRecordExposed(
        DeploymentTypes.State memory stateData,
        string memory proxyId,
        address implementation,
        string memory contractSource,
        string memory contractType,
        bytes memory initData
    ) external returns (address proxy, DeploymentTypes.State memory updatedState) {
        proxy = _deployProxyAndRecord(stateData, proxyId, implementation, contractSource, contractType, initData);
        return (proxy, stateData);
    }

    function getImplementation(address proxy) external view returns (address) {
        return _getImplementation(proxy);
    }
}

contract FactoryDeployerTest is BaoTest {
    TestableFactoryDeployer internal deployer;
    address internal testTreasury;
    address internal testOwner;
    address internal baoFactoryAddr;

    function setUp() public {
        testTreasury = makeAddr("treasury");
        testOwner = makeAddr("owner");
        baoFactoryAddr = _ensureBaoFactory();
        deployer = new TestableFactoryDeployer(testTreasury, testOwner, baoFactoryAddr);
        deployer.setSaltPrefix("test_v1");
    }

    /// @dev Create a properly initialized state for tests (writes to results/ directory).
    ///      Each test must pass a unique testName to avoid collisions in parallel test runs.
    function _createTestState(string memory testName) internal pure returns (DeploymentTypes.State memory stateData) {
        stateData.network = "";
        stateData.saltPrefix = string.concat("FactoryDeployerTest::", testName);
        stateData.directoryPrefix = "results";
        stateData.proxies = new DeploymentTypes.ProxyRecord[](0);
        stateData.implementations = new DeploymentTypes.ImplementationRecord[](0);
    }

    // ========== SALT STRING TESTS ==========

    function test_saltString_onePart() public view {
        string memory result = deployer.saltString1("pegged");
        assertEq(result, "test_v1::pegged", "single-part salt");
    }

    function test_saltString_twoParts() public view {
        string memory result = deployer.saltString2("ETH", "fxUSD");
        assertEq(result, "test_v1::ETH::fxUSD", "two-part salt");
    }

    function test_saltString_threeParts() public view {
        string memory result = deployer.saltString3("ETH", "fxUSD", "minter");
        assertEq(result, "test_v1::ETH::fxUSD::minter", "three-part salt");
    }

    function test_saltString_emptyPrefixStillWorks() public {
        deployer.setSaltPrefix("");
        string memory result = deployer.saltString1("test");
        assertEq(result, "::test", "empty prefix produces leading ::");
    }

    // ========== ADDRESS PREDICTION TESTS ==========

    function test_predictAddress_deterministic() public view {
        address addr1 = deployer.predictAddress1("token");
        address addr2 = deployer.predictAddress1("token");
        assertEq(addr1, addr2, "same key produces same address");
    }

    function test_predictAddress_differentKeysProduceDifferentAddresses() public view {
        address addr1 = deployer.predictAddress1("token1");
        address addr2 = deployer.predictAddress1("token2");
        assertTrue(addr1 != addr2, "different keys produce different addresses");
    }

    function test_predictAddress_matchesBaoFactoryPrediction() public view {
        string memory salt = "test_v1::myContract";
        bytes32 saltHash = keccak256(abi.encodePacked(salt));
        address expected = IBaoFactory(baoFactoryAddr).predictAddress(saltHash);
        address actual = deployer.predictAddress1("myContract");
        assertEq(actual, expected, "matches BaoFactory prediction");
    }

    // ========== ADDRESS LABEL TESTS ==========

    function test_addressLabel_returnsLabelForKnownAddress() public view {
        string memory label = deployer.addressLabel(testTreasury);
        assertEq(label, "treasury", "treasury address gets label");
    }

    function test_addressLabel_returnsHexForUnknownAddress() public {
        address unknown = makeAddr("unknown");
        string memory label = deployer.addressLabel(unknown);
        // Should be hex string starting with 0x
        bytes memory labelBytes = bytes(label);
        assertEq(labelBytes[0], "0", "starts with 0");
        assertEq(labelBytes[1], "x", "has x after 0");
    }

    // ========== STUB DEPLOYMENT TESTS ==========

    function test_getOrDeployStub_deploysOnFirstCall() public {
        UUPSProxyDeployStub stub = deployer.getOrDeployStub();
        assertTrue(address(stub) != address(0), "stub deployed");
        assertEq(stub.owner(), address(deployer), "deployer owns stub");
    }

    function test_getOrDeployStub_returnsSameOnSubsequentCalls() public {
        UUPSProxyDeployStub stub1 = deployer.getOrDeployStub();
        UUPSProxyDeployStub stub2 = deployer.getOrDeployStub();
        assertEq(address(stub1), address(stub2), "same stub returned");
    }

    // ========== OWNERSHIP TRANSFER TRACKING TESTS ==========

    function test_registerForOwnershipTransfer_incrementsCount() public {
        assertEq(deployer.pendingOwnershipCount(), 0, "starts at zero");

        deployer.registerForOwnershipTransfer(makeAddr("contract1"), "salt1");
        assertEq(deployer.pendingOwnershipCount(), 1, "one registered");

        deployer.registerForOwnershipTransfer(makeAddr("contract2"), "salt2");
        assertEq(deployer.pendingOwnershipCount(), 2, "two registered");
    }

    function test_transferAllOwnerships_callsTransferOwnershipOnEach() public {
        // Deploy a real ownable contract
        MockUpgradeable impl = new MockUpgradeable();

        // Create proxy via BaoFactory directly for this test
        bytes32 salt = keccak256("test_ownership");
        UUPSProxyDeployStub stub = deployer.getOrDeployStub();

        vm.prank(IBaoFactory(baoFactoryAddr).owner());
        IBaoFactory(baoFactoryAddr).setOperator(address(this), 365 days);

        address proxy = IBaoFactory(baoFactoryAddr).deploy(
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(address(stub), "")),
            salt
        );

        // Initialize with deployer as current owner, testOwner as pending
        vm.prank(address(deployer));
        UUPSProxyDeployStub(proxy).upgradeToAndCall(
            address(impl),
            abi.encodeCall(MockUpgradeable.initialize, (42, address(deployer), testOwner))
        );

        // Register for ownership transfer
        deployer.registerForOwnershipTransfer(proxy, "test::contract");

        // Transfer should complete the two-step ownership transfer
        deployer.transferAllOwnerships();

        // Verify ownership transferred
        assertEq(MockUpgradeable(proxy).owner(), testOwner, "ownership transferred");
        assertEq(deployer.pendingOwnershipCount(), 0, "pending list cleared");
    }

    // ========== GET IMPLEMENTATION TESTS ==========

    function test_getImplementation_readsERC1967Slot() public {
        // Deploy implementation
        MockUpgradeable impl = new MockUpgradeable();

        // Set up factory operator
        vm.prank(IBaoFactory(baoFactoryAddr).owner());
        IBaoFactory(baoFactoryAddr).setOperator(address(this), 365 days);

        // Create proxy via BaoFactory
        bytes32 salt = keccak256("test_getImpl");
        UUPSProxyDeployStub stub = deployer.getOrDeployStub();

        address proxy = IBaoFactory(baoFactoryAddr).deploy(
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(address(stub), "")),
            salt
        );

        // Upgrade to real implementation
        vm.prank(address(deployer));
        UUPSProxyDeployStub(proxy).upgradeToAndCall(
            address(impl),
            abi.encodeCall(MockUpgradeable.initialize, (42, address(deployer), testOwner))
        );

        // Verify getImplementation reads the correct address
        address readImpl = deployer.getImplementation(proxy);
        assertEq(readImpl, address(impl), "implementation address matches");
    }

    // ========== IDEMPOTENT DEPLOYMENT TESTS ==========

    /// @dev Tests idempotent deployment with both same and different implementation types.
    ///      State file shows: 3 proxies, 3 implementations (multiple entries)
    function test_deployProxyAndRecord_idempotent() public {
        // Deploy implementations
        MockUpgradeable impl1 = new MockUpgradeable();
        MockUpgradeable impl2 = new MockUpgradeable();
        MockUpgradeableV2 implV2 = new MockUpgradeableV2();

        // Set up factory operator
        vm.prank(IBaoFactory(baoFactoryAddr).owner());
        IBaoFactory(baoFactoryAddr).setOperator(address(deployer), 365 days);

        // Create initial state - starts empty
        DeploymentTypes.State memory stateData = _createTestState("idempotent_multipleProxies");
        address proxyA;
        address proxyB;
        address proxyC;

        // Deploy three different proxies, capturing returned state to accumulate
        vm.startPrank(address(deployer));

        (proxyA, stateData) = deployer.deployProxyAndRecordExposed(
            stateData,
            "contractA",
            address(impl1),
            "test/Mock.sol",
            "MockUpgradeable",
            abi.encodeCall(MockUpgradeable.initialize, (1, address(deployer), testOwner))
        );

        (proxyB, stateData) = deployer.deployProxyAndRecordExposed(
            stateData,
            "contractB",
            address(impl2),
            "test/Mock.sol",
            "MockUpgradeable",
            abi.encodeCall(MockUpgradeable.initialize, (2, address(deployer), testOwner))
        );

        (proxyC, stateData) = deployer.deployProxyAndRecordExposed(
            stateData,
            "contractC",
            address(implV2),
            "test/MockV2.sol",
            "MockUpgradeableV2",
            abi.encodeCall(MockUpgradeableV2.initialize, (3, address(deployer), testOwner))
        );

        // Verify we have 3 distinct proxies
        assertTrue(proxyA != proxyB && proxyB != proxyC, "proxies are distinct");

        // Verify state accumulated 3 entries
        assertEq(stateData.proxies.length, 3, "3 proxies in state");
        assertEq(stateData.implementations.length, 3, "3 implementations in state");

        // Test idempotency: redeploy all three - should return same addresses
        // Use distinct fresh implementations for each proxy (simulates real deployment where each
        // proxy gets its own impl, even if same bytecode - different CREATE = different address)
        MockUpgradeable freshImplA = new MockUpgradeable();
        MockUpgradeable freshImplB = new MockUpgradeable();
        address proxyA2;
        address proxyB2;
        address proxyC2;

        (proxyA2, stateData) = deployer.deployProxyAndRecordExposed(
            stateData,
            "contractA",
            address(freshImplA),
            "test/Mock.sol",
            "MockUpgradeable",
            abi.encodeCall(MockUpgradeable.initialize, (1, address(deployer), testOwner))
        );
        (proxyB2, stateData) = deployer.deployProxyAndRecordExposed(
            stateData,
            "contractB",
            address(freshImplB),
            "test/Mock.sol",
            "MockUpgradeable",
            abi.encodeCall(MockUpgradeable.initialize, (2, address(deployer), testOwner))
        );
        (proxyC2, stateData) = deployer.deployProxyAndRecordExposed(
            stateData,
            "contractC",
            address(implV2),
            "test/MockV2.sol",
            "MockUpgradeableV2",
            abi.encodeCall(MockUpgradeableV2.initialize, (3, address(deployer), testOwner))
        );

        vm.stopPrank();

        // Idempotent: same proxies returned
        assertEq(proxyA, proxyA2, "contractA idempotent");
        assertEq(proxyB, proxyB2, "contractB idempotent");
        assertEq(proxyC, proxyC2, "contractC idempotent");

        // Original implementations unchanged
        assertEq(deployer.getImplementation(proxyA), address(impl1), "impl1 unchanged");
        assertEq(deployer.getImplementation(proxyB), address(impl2), "impl2 unchanged");
        assertEq(deployer.getImplementation(proxyC), address(implV2), "implV2 unchanged");

        // Pending ownership count should be 3 (one per proxy, no duplicates)
        assertEq(deployer.pendingOwnershipCount(), 3, "3 proxies pending ownership");
    }

    /// @dev Tests state file with upgrade history: 1 proxy, 2 implementations.
    ///      Simulates a proxy that has been upgraded.
    function test_stateFile_upgradeHistory() public {
        // Create state and manually record upgrade history
        DeploymentTypes.State memory stateData = _createTestState("upgradeHistory");

        // Record old implementation (v1)
        DeploymentTypes.ImplementationRecord memory implV1;
        implV1.proxy = "upgradedContract";
        implV1.implementation = makeAddr("oldImpl");
        implV1.contractSource = "src/Contract.sol";
        implV1.contractType = "Contract_v1";
        DeploymentState.recordImplementation(stateData, implV1);

        // Record new implementation (v2) - same proxy, different impl
        DeploymentTypes.ImplementationRecord memory implV2;
        implV2.proxy = "upgradedContract";
        implV2.implementation = makeAddr("newImpl");
        implV2.contractSource = "src/Contract.sol";
        implV2.contractType = "Contract_v2";
        DeploymentState.recordImplementation(stateData, implV2);

        // Record the proxy pointing to the new implementation
        DeploymentTypes.ProxyRecord memory proxyRec;
        proxyRec.id = "upgradedContract";
        proxyRec.proxy = makeAddr("proxyAddr");
        proxyRec.implementation = makeAddr("newImpl");
        proxyRec.salt = "test::upgradedContract";
        DeploymentState.recordProxy(stateData, proxyRec);

        // Save state - should have 2 implementations, 1 proxy
        DeploymentState.save(stateData);

        // Verify state has expected structure
        assertEq(stateData.implementations.length, 2, "2 implementations recorded");
        assertEq(stateData.proxies.length, 1, "1 proxy recorded");
        assertEq(stateData.proxies[0].implementation, makeAddr("newImpl"), "proxy points to new impl");
    }

    /// @dev Tests empty state file (0 proxies, 0 implementations).
    function test_stateFile_empty() public {
        DeploymentTypes.State memory stateData = _createTestState("empty");

        // Save empty state
        DeploymentState.save(stateData);

        // Verify state is empty
        assertEq(stateData.implementations.length, 0, "no implementations");
        assertEq(stateData.proxies.length, 0, "no proxies");
    }

    function test_deployProxyAndRecord_existingProxy_stillRegistersForOwnershipIfNeeded() public {
        // This simulates the case where a previous run deployed the proxy but crashed
        // before ownership was transferred.

        // Deploy implementation
        MockUpgradeable impl = new MockUpgradeable();

        // Set up factory operator for deployer
        vm.prank(IBaoFactory(baoFactoryAddr).owner());
        IBaoFactory(baoFactoryAddr).setOperator(address(deployer), 365 days);

        // Create state data (unique per test to avoid collisions in parallel runs)
        DeploymentTypes.State memory stateData = _createTestState("existingProxy_stillRegistersForOwnershipIfNeeded");

        // First deployment - creates proxy owned by deployer
        vm.prank(address(deployer));
        (address proxy1,) = deployer.deployProxyAndRecordExposed(
            stateData,
            "testContract",
            address(impl),
            "test/Mock.sol",
            "MockUpgradeable",
            abi.encodeCall(MockUpgradeable.initialize, (42, address(deployer), testOwner))
        );

        // Verify proxy is owned by deployer, not final owner
        assertEq(MockUpgradeable(proxy1).owner(), address(deployer), "deployer owns proxy initially");

        // Simulate "crashed before ownership transfer" by clearing the pending list
        deployer.transferAllOwnerships(); // This will transfer ownership
        assertEq(MockUpgradeable(proxy1).owner(), testOwner, "ownership transferred first time");

        // Now reset scenario: manually set owner back to deployer to simulate "crashed mid-run"
        // We can't do this directly, so instead test with a fresh proxy where owner != target

        // For a true test, deploy a second proxy manually without going through our system
        bytes32 salt2 = keccak256(abi.encodePacked("test_v1", "::", "testContract2"));
        UUPSProxyDeployStub stub = deployer.getOrDeployStub();
        vm.prank(IBaoFactory(baoFactoryAddr).owner());
        IBaoFactory(baoFactoryAddr).setOperator(address(this), 365 days);
        address proxy2 = IBaoFactory(baoFactoryAddr).deploy(
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(address(stub), "")),
            salt2
        );
        // Initialize with deployer as owner (simulating incomplete deployment)
        vm.prank(address(deployer));
        UUPSProxyDeployStub(proxy2).upgradeToAndCall(
            address(impl),
            abi.encodeCall(MockUpgradeable.initialize, (42, address(deployer), testOwner))
        );

        assertEq(MockUpgradeable(proxy2).owner(), address(deployer), "proxy2 owned by deployer");
        assertEq(deployer.pendingOwnershipCount(), 0, "pending list empty before second deploy");

        // Now call deployProxyAndRecord for the same salt - proxy exists but ownership not transferred
        vm.prank(address(deployer));
        (address proxy2Again,) = deployer.deployProxyAndRecordExposed(
            stateData,
            "testContract2",
            address(impl),
            "test/Mock.sol",
            "MockUpgradeable",
            abi.encodeCall(MockUpgradeable.initialize, (42, address(deployer), testOwner))
        );

        // Same proxy returned
        assertEq(proxy2, proxy2Again, "existing proxy returned");

        // Should be registered for ownership transfer since owner != target
        assertEq(deployer.pendingOwnershipCount(), 1, "existing proxy registered for ownership transfer");

        // Transfer ownership
        deployer.transferAllOwnerships();
        assertEq(MockUpgradeable(proxy2).owner(), testOwner, "ownership transferred for existing proxy");
    }

    function test_registerForOwnershipTransfer_idempotent_noDuplicates() public {
        address fakeContract = makeAddr("fakeContract");

        // Register same contract twice
        deployer.registerForOwnershipTransfer(fakeContract, "test::contract");
        deployer.registerForOwnershipTransfer(fakeContract, "test::contract");
        deployer.registerForOwnershipTransfer(fakeContract, "test::contract");

        // Should only have one entry
        assertEq(deployer.pendingOwnershipCount(), 1, "no duplicates in pending list");
    }

    // ========== IDEMPOTENT OWNERSHIP TRANSFER TESTS ==========

    function test_transferAllOwnerships_idempotent_alreadyOwned() public {
        // Deploy a real ownable contract
        MockUpgradeable impl = new MockUpgradeable();

        // Create proxy via BaoFactory directly for this test
        bytes32 salt = keccak256("test_idempotent_ownership");
        UUPSProxyDeployStub stub = deployer.getOrDeployStub();

        vm.prank(IBaoFactory(baoFactoryAddr).owner());
        IBaoFactory(baoFactoryAddr).setOperator(address(this), 365 days);

        address proxy = IBaoFactory(baoFactoryAddr).deploy(
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(address(stub), "")),
            salt
        );

        // Initialize with testOwner directly as current owner (already owned by target)
        vm.prank(address(deployer));
        UUPSProxyDeployStub(proxy).upgradeToAndCall(
            address(impl),
            abi.encodeCall(MockUpgradeable.initialize, (42, testOwner, testOwner))
        );

        // Register for ownership transfer even though already owned
        deployer.registerForOwnershipTransfer(proxy, "test::contract");

        // Transfer should skip (already owned)
        deployer.transferAllOwnerships();

        // Verify ownership unchanged
        assertEq(MockUpgradeable(proxy).owner(), testOwner, "ownership unchanged");
        assertEq(deployer.pendingOwnershipCount(), 0, "pending list cleared");
    }
}
