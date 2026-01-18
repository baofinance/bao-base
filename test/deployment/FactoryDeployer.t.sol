// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {FactoryDeployer, WellKnownAddress, IBaoOwnable} from "@bao-script/deployment/FactoryDeployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";

/// @notice Mock upgradeable contract for testing proxy deployment.
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

    function saltString1(string memory a) external view returns (string memory) {
        return _saltString(a);
    }

    function saltString2(string memory a, string memory b) external view returns (string memory) {
        return _saltString(a, b);
    }

    function saltString3(string memory a, string memory b, string memory c) external view returns (string memory) {
        return _saltString(a, b, c);
    }

    function predictAddressFromFullSalt(string memory fullSalt) external view returns (address) {
        return _predictAddressFromFullSalt(fullSalt);
    }

    function predictAddress1(string memory a) external view returns (address) {
        return _predictAddress(a);
    }

    function predictAddress2(string memory a, string memory b) external view returns (address) {
        return _predictAddress(a, b);
    }

    function predictAddress3(string memory a, string memory b, string memory c) external view returns (address) {
        return _predictAddress(a, b, c);
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

    function deployProxyAndRecord(
        DeploymentTypes.State memory stateData,
        string memory proxyId,
        address implementation,
        string memory contractSource,
        string memory contractType,
        bytes memory initData
    ) external returns (address proxy) {
        return _deployProxyAndRecord(stateData, proxyId, implementation, contractSource, contractType, initData);
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
        _ensureBaoFactory();
        deployer.setSaltPrefix("test_v1");

        // Test all three overloads produce consistent results
        address predicted1 = deployer.predictAddress1("minter");
        address predictedFull = deployer.predictAddressFromFullSalt("test_v1::minter");
        assertEq(predicted1, predictedFull, "predictAddress1 matches predictAddressFromFullSalt");

        address predicted2 = deployer.predictAddress2("ETH", "minter");
        address predictedFull2 = deployer.predictAddressFromFullSalt("test_v1::ETH::minter");
        assertEq(predicted2, predictedFull2, "predictAddress2 matches predictAddressFromFullSalt");

        address predicted3 = deployer.predictAddress3("ETH", "fxUSD", "minter");
        address predictedFull3 = deployer.predictAddressFromFullSalt("test_v1::ETH::fxUSD::minter");
        assertEq(predicted3, predictedFull3, "predictAddress3 matches predictAddressFromFullSalt");
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

        address proxy = deployer.deployProxyAndRecord(
            state,
            "owned",
            address(impl),
            "test.sol",
            "MockUpgradeableOwnable",
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

        address proxy = deployer.deployProxyAndRecord(
            state,
            "owned",
            address(impl),
            "test.sol",
            "MockUpgradeableOwnable",
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

        address proxy = deployer.deployProxyAndRecord(
            state,
            "minter",
            address(impl),
            "@test/MockUpgradeableOwnable.sol",
            "MockUpgradeableOwnable",
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

        address proxy = deployer.deployProxyAndRecord(
            state,
            "check_impl",
            address(impl),
            "test.sol",
            "MockUpgradeableOwnable",
            abi.encodeCall(MockUpgradeableOwnable.initialize, (testOwner, 1))
        );

        address storedImpl = deployer.getImplementation(proxy);
        assertEq(storedImpl, address(impl), "implementation address matches");
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
