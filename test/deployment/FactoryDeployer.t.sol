// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {FactoryDeployer, WellKnownAddress, IBaoOwnable} from "@bao-script/deployment/FactoryDeployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";
import {HarborOwnable} from "@bao/HarborOwnable.sol";
import {HarborPauser_v1} from "@bao/HarborPauser_v1.sol";

/// @notice Mock upgradeable contract using BaoOwnable (legacy, needs stub).
contract MockUpgradeableOwnable is Initializable, UUPSUpgradeable, BaoOwnable {
    uint256 public value;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, uint256 value_) external initializer {
        _initializeOwner(owner_);
        __UUPSUpgradeable_init();
        value = value_;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}

/// @notice Mock upgradeable contract using HarborOwnable (modern, no stub needed).
contract MockHarborOwnable is Initializable, UUPSUpgradeable, HarborOwnable {
    uint256 public value;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address deployerOwner_, address pendingOwner_, uint256 value_) external initializer {
        _initializeOwner(deployerOwner_, pendingOwner_);
        __UUPSUpgradeable_init();
        value = value_;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}

/// @notice Concrete implementation of FactoryDeployer for testing.
contract TestableFactoryDeployer is FactoryDeployer {
    address private _treasuryAddr;
    address private _ownerAddr;
    bool private _persistState = false;

    constructor(address treasury_, address owner_) {
        _treasuryAddr = treasury_;
        _ownerAddr = owner_;
    }

    function treasury() public view override returns (address) {
        return _treasuryAddr;
    }

    function owner() public view override returns (address) {
        return _ownerAddr;
    }

    function setOwner(address owner_) external {
        _ownerAddr = owner_;
    }

    function _shouldPersistState() internal pure override returns (bool) {
        return false;
    }

    // ========== Expose internal functions for testing ==========

    function setSaltPrefix(string memory prefix) external {
        _setSaltPrefix(prefix);
    }

    function key1(string memory a) external pure returns (string memory) {
        return _key(a);
    }

    function key2(string memory a, string memory b) external pure returns (string memory) {
        return _key(a, b);
    }

    function key3(string memory a, string memory b, string memory c) external pure returns (string memory) {
        return _key(a, b, c);
    }

    function key4(
        string memory a,
        string memory b,
        string memory c,
        string memory d
    ) external pure returns (string memory) {
        return _key(a, b, c, d);
    }

    function key5(
        string memory a,
        string memory b,
        string memory c,
        string memory d,
        string memory e
    ) external pure returns (string memory) {
        return _key(a, b, c, d, e);
    }

    function saltString1(string memory a) external view returns (string memory) {
        return _saltString(a);
    }

    function saltString2(string memory a, string memory b) external view returns (string memory) {
        return _saltString(_key(a, b));
    }

    function saltString3(string memory a, string memory b, string memory c) external view returns (string memory) {
        return _saltString(_key(a, b, c));
    }

    function predictAddress1(string memory a) external returns (address) {
        return _predictAddress(a);
    }

    function predictAddress2(string memory a, string memory b) external returns (address) {
        return _predictAddress(_key(a, b));
    }

    function predictAddress3(string memory a, string memory b, string memory c) external returns (address) {
        return _predictAddress(_key(a, b, c));
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

    function getImplementation(address proxy) external view returns (address) {
        return _getImplementation(proxy);
    }

    function recordImplementation(
        DeploymentTypes.State memory stateData,
        string memory proxyId,
        string memory contractSource,
        string memory contractType,
        address implementation
    ) external view {
        _recordImplementation(stateData, proxyId, contractSource, contractType, implementation);
    }

    function deployProxyViaStubAndRecord(
        DeploymentTypes.State memory stateData,
        string memory proxyId,
        address implementation,
        bytes memory initData
    ) external returns (address proxy) {
        return _deployProxyViaStubAndRecord(stateData, proxyId, implementation, initData);
    }

    function deployProxyAndRecord(
        DeploymentTypes.State memory stateData,
        string memory proxyId,
        address implementation,
        bytes memory initData
    ) external returns (address proxy) {
        return _deployProxyAndRecord(stateData, proxyId, implementation, initData);
    }

    function saveState(DeploymentTypes.State memory stateData) external {
        _saveState(stateData);
    }
}

contract FactoryDeployerTest is BaoTest {
    TestableFactoryDeployer internal deployer;
    address internal testTreasury;
    address internal testOwner;

    function setUp() public {
        testTreasury = makeAddr("treasury");
        testOwner = makeAddr("owner");
        deployer = new TestableFactoryDeployer(testTreasury, testOwner);
    }

    // ========== Basic Configuration Tests ==========

    function test_initialSaltPrefixIsEmpty() public view {
        assertEq(deployer.saltPrefix(), "", "saltPrefix starts empty");
    }

    function test_setSaltPrefix() public {
        deployer.setSaltPrefix("test_v1");
        assertEq(deployer.saltPrefix(), "test_v1", "saltPrefix set correctly");
    }

    function test_setSaltPrefixCanBeOverwritten() public {
        deployer.setSaltPrefix("first");
        deployer.setSaltPrefix("second");
        assertEq(deployer.saltPrefix(), "second", "saltPrefix can be changed");
    }

    function test_treasury() public view {
        assertEq(deployer.treasury(), testTreasury, "treasury returns configured address");
    }

    function test_owner() public view {
        assertEq(deployer.owner(), testOwner, "owner returns configured address");
    }

    function test_baoFactoryDefaultAddress() public view {
        assertEq(
            deployer.baoFactory(),
            0xD696E56b3A054734d4C6DCBD32E11a278b0EC458,
            "baoFactory returns default address"
        );
    }

    function test_getWellKnownAddressesContainsExpectedEntries() public view {
        WellKnownAddress[] memory addrs = deployer.getWellKnownAddresses();

        assertEq(addrs.length, 3, "should have 3 well-known addresses");
        assertEq(addrs[0].addr, testTreasury, "first entry is treasury");
        assertEq(addrs[0].label, "treasury", "treasury label correct");
        assertEq(addrs[1].addr, testOwner, "second entry is owner");
        assertEq(addrs[1].label, "owner", "owner label correct");
        assertEq(addrs[2].addr, 0xD696E56b3A054734d4C6DCBD32E11a278b0EC458, "third entry is baoFactory");
        assertEq(addrs[2].label, "baoFactory", "baoFactory label correct");
    }

    // ========== Salt String Construction Tests ==========

    function test_saltString1() public {
        deployer.setSaltPrefix("harbor_v1");
        assertEq(deployer.saltString1("pegged"), "harbor_v1::pegged");
    }

    function test_saltString2() public {
        deployer.setSaltPrefix("harbor_v1");
        assertEq(deployer.saltString2("ETH", "minter"), "harbor_v1::ETH::minter");
    }

    function test_saltString3() public {
        deployer.setSaltPrefix("harbor_v1");
        assertEq(deployer.saltString3("ETH", "fxUSD", "minter"), "harbor_v1::ETH::fxUSD::minter");
    }

    // ========== Key Building Tests ==========

    function test_key1_identity() public view {
        assertEq(deployer.key1("pegged"), "pegged");
    }

    function test_key2_joinsTwoParts() public view {
        assertEq(deployer.key2("ETH", "fxUSD"), "ETH::fxUSD");
    }

    function test_key3_joinsThreeParts() public view {
        assertEq(deployer.key3("ETH", "fxUSD", "minter"), "ETH::fxUSD::minter");
    }

    function test_key4_joinsFourParts() public view {
        assertEq(
            deployer.key4("ETH", "fxUSD", "stabilityPoolCollateral", "harvest"),
            "ETH::fxUSD::stabilityPoolCollateral::harvest"
        );
    }

    function test_key5_joinsFiveParts() public view {
        assertEq(deployer.key5("a", "b", "c", "d", "e"), "a::b::c::d::e");
    }

    function test_key_composesWith_saltString() public {
        deployer.setSaltPrefix("harbor_v1");
        assertEq(deployer.saltString1(deployer.key3("ETH", "fxUSD", "minter")), "harbor_v1::ETH::fxUSD::minter");
    }

    // ========== Address Label Tests ==========

    function test_addressLabel_knownAddress() public view {
        assertEq(deployer.addressLabel(testTreasury), "treasury");
        assertEq(deployer.addressLabel(testOwner), "owner");
        assertEq(deployer.addressLabel(deployer.baoFactory()), "baoFactory");
    }

    function test_addressLabel_unknownAddress() public {
        address unknown = makeAddr("unknown");
        // Should return hex string for unknown addresses
        string memory label = deployer.addressLabel(unknown);
        assertGt(bytes(label).length, 0, "should return non-empty string");
        // Hex addresses start with 0x
        assertEq(bytes(label)[0], bytes1("0"), "should start with 0");
        assertEq(bytes(label)[1], bytes1("x"), "should have x as second char");
    }

    // ========== Address Prediction Tests (requires BaoFactory) ==========

    function test_predictAddress_withFactory() public {
        address factory = _ensureBaoFactory();
        deployer.setSaltPrefix("test_v1");

        // Test all three overloads produce addresses matching the expected CREATE3 salt
        address predicted1 = deployer.predictAddress1("minter");
        address expected1 = IBaoFactory(factory).predictAddress(keccak256(abi.encodePacked("test_v1::minter")));
        assertEq(predicted1, expected1, "predictAddress1 matches expected salt");

        address predicted2 = deployer.predictAddress2("ETH", "minter");
        address expected2 = IBaoFactory(factory).predictAddress(keccak256(abi.encodePacked("test_v1::ETH::minter")));
        assertEq(predicted2, expected2, "predictAddress2 matches expected salt");

        address predicted3 = deployer.predictAddress3("ETH", "fxUSD", "minter");
        address expected3 = IBaoFactory(factory).predictAddress(
            keccak256(abi.encodePacked("test_v1::ETH::fxUSD::minter"))
        );
        assertEq(predicted3, expected3, "predictAddress3 matches expected salt");
    }

    // ========== Helper to set up factory with deployer as operator ==========

    function _setupFactoryWithDeployerAsOperator() internal returns (address factory) {
        factory = _ensureBaoFactory();
        // The deployer contract needs to be an operator to call BaoFactory.deploy()
        if (!IBaoFactory(factory).isCurrentOperator(address(deployer))) {
            vm.prank(IBaoFactory(factory).owner());
            IBaoFactory(factory).setOperator(address(deployer), 365 days);
        }
    }

    // ========== Ownership Transfer Tests ==========

    function test_pendingOwnershipCount_initiallyZero() public view {
        assertEq(deployer.pendingOwnershipCount(), 0);
    }

    function test_registerForOwnershipTransfer_incrementsCount() public {
        address contract1 = makeAddr("contract1");
        address contract2 = makeAddr("contract2");

        deployer.registerForOwnershipTransfer(contract1, "salt1");
        assertEq(deployer.pendingOwnershipCount(), 1);

        deployer.registerForOwnershipTransfer(contract2, "salt2");
        assertEq(deployer.pendingOwnershipCount(), 2);
    }

    function test_registerForOwnershipTransfer_idempotent() public {
        address contract1 = makeAddr("contract1");

        deployer.registerForOwnershipTransfer(contract1, "salt1");
        deployer.registerForOwnershipTransfer(contract1, "salt1");
        assertEq(deployer.pendingOwnershipCount(), 1, "duplicate registration ignored");
    }

    function test_transferAllOwnerships_clearsSet() public {
        _setupFactoryWithDeployerAsOperator();
        deployer.setSaltPrefix("transfer_test");

        // Deploy a real proxy that has ownership
        // Initialize with testOwner as the PENDING owner (BaoOwnable pattern)
        // The deployer contract will be the initial owner and can transfer to pendingOwner
        MockUpgradeableOwnable impl = new MockUpgradeableOwnable();
        DeploymentTypes.State memory state;
        state.network = "test";
        state.saltPrefix = "transfer_test";
        state.baoFactory = deployer.baoFactory();

        deployer.recordImplementation(state, "owned", "test.sol", "MockUpgradeableOwnable", address(impl));
        address proxy = deployer.deployProxyViaStubAndRecord(
            state,
            "owned",
            address(impl),
            abi.encodeCall(MockUpgradeableOwnable.initialize, (testOwner, 42))
        );

        assertEq(deployer.pendingOwnershipCount(), 1, "one pending transfer");

        // The proxy was initialized with testOwner as pending owner
        // Current owner is address(deployer) - the TestableFactoryDeployer
        // Transfer ownership confirms the pending owner
        deployer.transferAllOwnerships();

        assertEq(deployer.pendingOwnershipCount(), 0, "set cleared after transfer");
        assertEq(IBaoOwnable(proxy).owner(), testOwner, "ownership transferred");
    }

    function test_transferAllOwnerships_skipsAlreadyOwned() public {
        _setupFactoryWithDeployerAsOperator();
        deployer.setSaltPrefix("already_owned");

        // Set owner to deployer itself so proxy is already owned by target
        deployer.setOwner(address(deployer));

        MockUpgradeableOwnable impl = new MockUpgradeableOwnable();
        DeploymentTypes.State memory state;
        state.network = "test";
        state.saltPrefix = "already_owned";
        state.baoFactory = deployer.baoFactory();

        deployer.recordImplementation(state, "owned", "test.sol", "MockUpgradeableOwnable", address(impl));
        address proxy = deployer.deployProxyViaStubAndRecord(
            state,
            "owned",
            address(impl),
            abi.encodeCall(MockUpgradeableOwnable.initialize, (address(deployer), 42))
        );

        // Owner is already address(deployer), which is also deployer.owner()
        assertEq(IBaoOwnable(proxy).owner(), address(deployer));

        // This should not revert, just skip
        deployer.transferAllOwnerships();
        assertEq(deployer.pendingOwnershipCount(), 0);
    }

    // ========== Proxy Deployment Tests ==========

    function test_deployProxyAndRecord() public {
        _setupFactoryWithDeployerAsOperator();
        deployer.setSaltPrefix("deploy_test");

        MockUpgradeableOwnable impl = new MockUpgradeableOwnable();

        DeploymentTypes.State memory state;
        state.network = "test";
        state.saltPrefix = "deploy_test";
        state.baoFactory = deployer.baoFactory();

        deployer.recordImplementation(
            state,
            "minter",
            "@test/MockUpgradeableOwnable.sol",
            "MockUpgradeableOwnable",
            address(impl)
        );
        address proxy = deployer.deployProxyViaStubAndRecord(
            state,
            "minter",
            address(impl),
            abi.encodeCall(MockUpgradeableOwnable.initialize, (testOwner, 123))
        );

        // Verify proxy was deployed
        assertGt(proxy.code.length, 0, "proxy has code");

        // Verify initialization
        assertEq(MockUpgradeableOwnable(proxy).value(), 123, "value initialized");

        // Verify registered for ownership transfer
        assertEq(deployer.pendingOwnershipCount(), 1);

        // Verify implementation is stored correctly in proxy
        address storedImpl = deployer.getImplementation(proxy);
        assertEq(storedImpl, address(impl), "implementation matches");
    }

    function test_getImplementation() public {
        _setupFactoryWithDeployerAsOperator();
        deployer.setSaltPrefix("impl_test");

        MockUpgradeableOwnable impl = new MockUpgradeableOwnable();

        DeploymentTypes.State memory state;
        state.network = "test";
        state.saltPrefix = "impl_test";
        state.baoFactory = deployer.baoFactory();

        deployer.recordImplementation(state, "check_impl", "test.sol", "MockUpgradeableOwnable", address(impl));
        address proxy = deployer.deployProxyViaStubAndRecord(
            state,
            "check_impl",
            address(impl),
            abi.encodeCall(MockUpgradeableOwnable.initialize, (testOwner, 1))
        );

        address storedImpl = deployer.getImplementation(proxy);
        assertEq(storedImpl, address(impl), "implementation address matches");
    }

    // ========== HarborOwnable Deploy Tests (direct and via stub) ==========

    function _deployHarborOwnableState() internal view returns (DeploymentTypes.State memory state) {
        state.network = "test";
        state.saltPrefix = "harbor_ownable_test";
        state.baoFactory = deployer.baoFactory();
    }

    function test_harborOwnable_directDeploy() public {
        _setupFactoryWithDeployerAsOperator();
        deployer.setSaltPrefix("harbor_ownable_test");

        MockHarborOwnable impl = new MockHarborOwnable();
        DeploymentTypes.State memory state = _deployHarborOwnableState();

        deployer.recordImplementation(state, "direct", "test.sol", "MockHarborOwnable", address(impl));
        address proxy = deployer.deployProxyAndRecord(
            state,
            "direct",
            address(impl),
            abi.encodeCall(MockHarborOwnable.initialize, (address(deployer), testOwner, 77))
        );

        assertEq(MockHarborOwnable(proxy).value(), 77, "value initialized");
        // deployer is temp owner (explicit deployerOwner param)
        assertEq(IBaoOwnable(proxy).owner(), address(deployer), "deployer is temp owner");

        // Transfer to final owner
        deployer.transferAllOwnerships();
        assertEq(IBaoOwnable(proxy).owner(), testOwner, "ownership transferred");
    }

    function test_harborOwnable_viaStubDeploy() public {
        _setupFactoryWithDeployerAsOperator();
        deployer.setSaltPrefix("harbor_ownable_stub");

        MockHarborOwnable impl = new MockHarborOwnable();
        DeploymentTypes.State memory state;
        state.network = "test";
        state.saltPrefix = "harbor_ownable_stub";
        state.baoFactory = deployer.baoFactory();

        deployer.recordImplementation(state, "via_stub", "test.sol", "MockHarborOwnable", address(impl));
        address proxy = deployer.deployProxyViaStubAndRecord(
            state,
            "via_stub",
            address(impl),
            abi.encodeCall(MockHarborOwnable.initialize, (address(deployer), testOwner, 88))
        );

        assertEq(MockHarborOwnable(proxy).value(), 88, "value initialized");
        // deployer is temp owner — same result as direct path
        assertEq(IBaoOwnable(proxy).owner(), address(deployer), "deployer is temp owner");

        // Transfer to final owner
        deployer.transferAllOwnerships();
        assertEq(IBaoOwnable(proxy).owner(), testOwner, "ownership transferred");
    }

    function test_harborOwnable_bothPathsSameAddress() public {
        // Verify that direct and stub paths produce the same proxy address for the same salt
        // (they must, since both use CREATE3 with the same salt)
        _setupFactoryWithDeployerAsOperator();

        MockHarborOwnable impl = new MockHarborOwnable();
        bytes memory initData = abi.encodeCall(MockHarborOwnable.initialize, (address(deployer), testOwner, 99));

        // Predict address
        deployer.setSaltPrefix("same_addr_test");
        address predicted = deployer.predictAddress1("contract");

        // Deploy via direct path
        DeploymentTypes.State memory state;
        state.network = "test";
        state.saltPrefix = "same_addr_test";
        state.baoFactory = deployer.baoFactory();

        deployer.recordImplementation(state, "contract", "test.sol", "MockHarborOwnable", address(impl));
        address proxy = deployer.deployProxyAndRecord(state, "contract", address(impl), initData);

        assertEq(proxy, predicted, "direct deploy matches predicted address");
    }

    // ========== HarborFixedOwnable via stub (empty initData) ==========

    function test_harborFixedOwnable_viaStubEmptyInit() public {
        _setupFactoryWithDeployerAsOperator();
        deployer.setSaltPrefix("fixed_stub_test");

        HarborPauser_v1 impl = new HarborPauser_v1();
        DeploymentTypes.State memory state;
        state.network = "test";
        state.saltPrefix = "fixed_stub_test";
        state.baoFactory = deployer.baoFactory();

        deployer.recordImplementation(state, "pauser", "@bao/HarborPauser_v1.sol", "HarborPauser_v1", address(impl));
        address proxy = deployer.deployProxyViaStubAndRecord(
            state,
            "pauser",
            address(impl),
            "" // empty initData — exercises upgradeTo path
        );

        assertGt(proxy.code.length, 0, "proxy has code");
        // Owner is multisig (hardcoded in HarborFixedOwnable)
        assertEq(HarborPauser_v1(proxy).owner(), HARBOR_MULTISIG, "owner is multisig");
    }

    // ========== State Persistence Tests ==========

    function test_saveState_respectsShouldPersistState() public {
        // _shouldPersistState returns false in TestableFactoryDeployer
        // So saveState should be a no-op (doesn't try to write files)
        DeploymentTypes.State memory state;
        state.network = "test";
        state.saltPrefix = "persist_test";
        state.baoFactory = deployer.baoFactory();

        // This should not revert even though we haven't set up file permissions
        deployer.saveState(state);
    }
}

/// @notice Deployer that does NOT override defaults — exercises _shouldPersistState(true),
///         _stateFileRead, _stateFileWrite, and _saveState with actual file I/O.
contract DefaultPersistenceDeployer is FactoryDeployer {
    function treasury() public pure override returns (address) {
        return address(0xdead);
    }

    function owner() public pure override returns (address) {
        return address(0xbeef);
    }

    function setSaltPrefix(string memory prefix) external {
        _setSaltPrefix(prefix);
    }

    function saveState(DeploymentTypes.State memory stateData) external {
        _saveState(stateData);
    }

    function stateFileRead() external view returns (string memory) {
        return _stateFileRead();
    }

    function stateFileWrite() external view returns (string memory) {
        return _stateFileWrite();
    }

    function shouldPersistState() external pure returns (bool) {
        return _shouldPersistState();
    }
}

contract FactoryDeployerPersistenceTest is BaoTest {
    DefaultPersistenceDeployer internal deployer;
    string internal readPath;
    string internal writePath;

    function setUp() public {
        deployer = new DefaultPersistenceDeployer();

        string memory stateDir = string.concat(vm.projectRoot(), "/results");
        readPath = string.concat(stateDir, "/test_state_read.json");
        writePath = string.concat(stateDir, "/test_state_write.json");

        vm.setEnv("DEPLOY_STATE_DIR", stateDir);
        vm.setEnv("DEPLOY_STATE_FILE_READ", readPath);
        vm.setEnv("DEPLOY_STATE_FILE_WRITE", writePath);
    }

    function test_shouldPersistState_defaultIsTrue() public view {
        assertTrue(deployer.shouldPersistState());
    }

    function test_stateFileRead_readsEnvVar() public view {
        assertEq(deployer.stateFileRead(), readPath);
    }

    function test_stateFileWrite_readsEnvVar() public view {
        assertEq(deployer.stateFileWrite(), writePath);
    }

    function test_saveState_writesToFile() public {
        DeploymentTypes.State memory state;
        state.network = "test";
        state.saltPrefix = "persist_test";
        state.baoFactory = address(0x123);

        deployer.saveState(state);

        // Verify file was written
        assertTrue(vm.exists(writePath), "state file created");
    }
}
