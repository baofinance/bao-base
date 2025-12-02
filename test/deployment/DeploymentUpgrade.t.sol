// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {DeploymentJsonTesting} from "@bao-script/deployment/DeploymentJsonTesting.sol";
import {DeploymentKeys} from "@bao-script/deployment/DeploymentKeys.sol";
import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {DeploymentDataMemory} from "@bao-script/deployment/DeploymentDataMemory.sol";
import {DeploymentJson} from "@bao-script/deployment/DeploymentJson.sol";
import {OracleV1} from "../mocks/upgradeable/MockOracle.sol";

import {CounterV1} from "../mocks/upgradeable/MockCounter.sol";
import {IUUPSUpgradeableProxy} from "@bao-script/deployment/Deployment.sol";

// Upgraded version of Oracle for testing
contract OracleV2 is OracleV1 {
    uint256 public lastUpdateTime;

    function setPrice(uint256 _price) external override {
        price = _price;
        lastUpdateTime = block.timestamp;
    }

    function getVersion() external pure returns (uint256) {
        return 2;
    }
}

// Upgraded version of Counter for testing
contract CounterV2 is CounterV1 {
    uint256 public decrementCount;

    function decrement() external {
        if (value > 0) {
            value--;
            decrementCount++;
        }
    }

    function getVersion() external pure returns (uint256) {
        return 2;
    }
}

/**
 * @title MockDeploymentUpgrade
 * @notice Test harness for proxy upgrade scenarios
 */
contract MockDeploymentUpgrade is DeploymentJsonTesting {
    uint private _sequenceNumber;

    constructor() {
        // Register all possible contract keys used in tests with contracts. prefix
        addProxy("contracts.oz_proxy");
        addProxy("contracts.counter");
        addProxy("contracts.counterV2");
        addProxy("contracts.Oracle");
        addProxy("contracts.Oracle1");
        addProxy("contracts.Oracle2");
        addProxy("contracts.Counter");

        _sequenceNumber = 1;
        // Register .type keys for metadata (addProxy registers .contractType but tests use .type)
    }

    function deployOracleProxy(string memory key, uint256 price, address admin) public {
        OracleV1 impl = new OracleV1();
        bytes memory initData = abi.encodeCall(OracleV1.initialize, (price, admin));
        string memory fullKey = string.concat("contracts.", key);
        this.deployProxy(
            fullKey,
            address(impl),
            initData,
            "OracleV1",
            "test/mocks/upgradeable/MockOracle.sol",
            address(this)
        );
    }

    function deployCounterProxy(string memory key, uint256 initialValue, address admin) public {
        CounterV1 impl = new CounterV1();

        bytes memory initData = abi.encodeCall(CounterV1.initialize, (initialValue, admin));
        string memory fullKey = string.concat("contracts.", key);
        this.deployProxy(
            fullKey,
            address(impl),
            initData,
            "CounterV1",
            "test/mocks/upgradeable/Counter.sol",
            address(this)
        );
    }

    function upgradeOracle(string memory key, address newImplementation) public {
        address proxy = _get(key);
        IUUPSUpgradeableProxy(proxy).upgradeTo(newImplementation);
    }

    function upgradeCounter(string memory key, address newImplementation) public {
        address proxy = _get(key);
        IUUPSUpgradeableProxy(proxy).upgradeTo(newImplementation);
    }

    /// @notice Count how many proxies still need ownership transfer
    /// @dev _getTransferrableProxies() already filters to only those needing transfer
    function countTransferrableProxies(address /* newOwner */) public view returns (uint256) {
        return _getTransferrableProxies().length;
    }

    // no increemental changes
    function _afterValueChanged(string memory key) internal override(DeploymentJson, DeploymentDataMemory) {}

    function _getFilename() internal view override returns (string memory) {
        return string.concat(super._getFilename(), ".op", _padZero(_sequenceNumber, 2));
    }

    function save() public {
        _save();
        _sequenceNumber++;
    }

    function fromJsonNoSave(string memory json) public {
        _fromJsonNoSave(json);
    }
}

/**
 * @title DeploymentUpgradeTest
 * @notice Tests proxy upgrade scenarios and implementation management
 */
contract DeploymentUpgradeTest is BaoDeploymentTest {
    MockDeploymentUpgrade public deployment;
    string constant TEST_SALT = "DeploymentUpgradeTest";

    function setUp() public override {
        super.setUp();
        deployment = new MockDeploymentUpgrade();
    }

    /// @notice Helper to start deployment with test-specific network name
    function _startDeployment(string memory network) internal {
        _initDeploymentTest(TEST_SALT, network);
        deployment.start(network, TEST_SALT, "");
        deployment.save();
    }

    /// @notice Get the configured final owner from deployment data
    function getConfiguredOwner() internal view returns (address) {
        return deployment.getAddress(deployment.OWNER());
    }

    function test_BasicUpgrade() public {
        _startDeployment("test_BasicUpgrade");

        // Deploy initial proxy
        deployment.deployOracleProxy("Oracle", 1000e18, getConfiguredOwner());

        // Verify ownership still with harness before finish
        uint256 stillOwned = deployment.countTransferrableProxies(getConfiguredOwner());
        assertEq(stillOwned, 1, "Ownership should still be with harness");

        // Complete ownership transfer
        uint256 transferred = deployment.finish();
        assertEq(transferred, 1, "Should transfer 1 proxy");

        // Verify ownership transferred
        stillOwned = deployment.countTransferrableProxies(getConfiguredOwner());
        assertEq(stillOwned, 0, "Ownership should be transferred after finish");

        // Verify initial state
        OracleV1 oracleV1 = OracleV1(deployment.get("contracts.Oracle"));
        assertEq(oracleV1.price(), 1000e18, "Initial price should be set");
        assertEq(oracleV1.owner(), getConfiguredOwner(), "Owner should be set");

        // Capture BEFORE state
        deployment.save(); // Advances to .002 for AFTER state

        // Deploy new implementation
        OracleV2 newImpl = new OracleV2();

        // Upgrade proxy (called from owner - getConfiguredOwner)
        address proxyAddr = deployment.get("contracts.Oracle");
        vm.prank(getConfiguredOwner());
        IUUPSUpgradeableProxy(proxyAddr).upgradeTo(address(newImpl));

        // Verify upgrade worked (AFTER upgrade)
        OracleV2 oracleV2 = OracleV2(deployment.get("contracts.Oracle"));
        assertEq(oracleV2.price(), 1000e18, "Price should persist after upgrade");
        assertEq(oracleV2.owner(), getConfiguredOwner(), "Owner should persist after upgrade");
        assertEq(oracleV2.getVersion(), 2, "Should be version 2");

        // Test new functionality
        oracleV2.setPrice(2000e18);
        assertEq(oracleV2.price(), 2000e18, "Price should be updated");
        assertGt(oracleV2.lastUpdateTime(), 0, "Update time should be set");
    }

    function test_MultipleProxyUpgrades() public {
        _startDeployment("test_MultipleProxyUpgrades");

        // Deploy multiple proxies
        deployment.deployOracleProxy("Oracle1", 1000e18, getConfiguredOwner());
        deployment.deployOracleProxy("Oracle2", 1500e18, getConfiguredOwner());
        deployment.deployCounterProxy("Counter", 10, getConfiguredOwner());

        // Finish deployment and transfer ownership
        deployment.finish();
        // Ownership transferred by finish()

        // Capture BEFORE state (all proxies at V1)
        deployment.save(); // Advances to .002

        // Deploy new implementations
        OracleV2 newOracleImpl = new OracleV2();
        CounterV2 newCounterImpl = new CounterV2();

        // Upgrade Oracle1 (called from owner - getConfiguredOwner)
        address oracle1Proxy = deployment.get("contracts.Oracle1");
        vm.prank(getConfiguredOwner());
        IUUPSUpgradeableProxy(oracle1Proxy).upgradeTo(address(newOracleImpl));

        // Capture intermediate state (Oracle1 upgraded, Counter still V1)
        deployment.save(); // Advances to .003

        // Upgrade Counter (called from owner - getConfiguredOwner)
        address counterProxy = deployment.get("contracts.Counter");
        vm.prank(getConfiguredOwner());
        IUUPSUpgradeableProxy(counterProxy).upgradeTo(address(newCounterImpl));

        // Verify Oracle1 upgrade
        OracleV2 oracle1V2 = OracleV2(deployment.get("contracts.Oracle1"));
        assertEq(oracle1V2.getVersion(), 2, "Oracle1 should be version 2");
        assertEq(oracle1V2.price(), 1000e18, "Oracle1 price should persist");

        // Verify Oracle2 is still V1
        OracleV1 oracle2V1 = OracleV1(deployment.get("contracts.Oracle2"));
        assertEq(oracle2V1.price(), 1500e18, "Oracle2 should maintain original price");

        // Verify Counter upgrade
        CounterV2 counterV2 = CounterV2(deployment.get("contracts.Counter"));
        assertEq(counterV2.getVersion(), 2, "Counter should be version 2");
        assertEq(counterV2.value(), 10, "Counter value should persist");

        // Test new Counter functionality
        counterV2.decrement();
        assertEq(counterV2.value(), 9, "Counter should decrement");
        assertEq(counterV2.decrementCount(), 1, "Decrement count should be tracked");
    }

    function test_UpgradeWithStateTransition() public {
        _startDeployment("test_UpgradeWithStateTransition");

        // Deploy counter proxy
        deployment.deployCounterProxy("Counter", 5, getConfiguredOwner());

        // Finish deployment and transfer ownership
        deployment.finish();
        // Ownership transferred by finish()

        // Interact with V1
        CounterV1 counterV1 = CounterV1(deployment.get("contracts.Counter"));
        counterV1.increment();
        counterV1.increment();
        assertEq(counterV1.value(), 7, "Should have incremented to 7");

        // Deploy and upgrade to V2 (called from owner - getConfiguredOwner)
        CounterV2 newImpl = new CounterV2();
        address counterProxy = deployment.get("contracts.Counter");
        vm.prank(getConfiguredOwner());
        IUUPSUpgradeableProxy(counterProxy).upgradeTo(address(newImpl));

        // Verify state persisted
        CounterV2 counterV2 = CounterV2(deployment.get("contracts.Counter"));
        assertEq(counterV2.value(), 7, "Value should persist after upgrade");
        assertEq(counterV2.decrementCount(), 0, "New state should be initialized");

        // Test both old and new functionality
        counterV2.increment();
        assertEq(counterV2.value(), 8, "Old functionality should work");

        counterV2.decrement();
        assertEq(counterV2.value(), 7, "New functionality should work");
        assertEq(counterV2.decrementCount(), 1, "New state should be tracked");
    }

    function test_UpgradeAuthorization() public {
        _startDeployment("test_UpgradeAuthorization");

        // Deploy oracle with getConfiguredOwner()
        deployment.deployOracleProxy("Oracle", 1000e18, getConfiguredOwner());

        // Finish deployment and transfer ownership
        deployment.finish();
        // Ownership transferred by finish()

        // Deploy new implementation
        OracleV2 newImpl = new OracleV2();

        // Try to upgrade from unauthorized account (should fail)
        address unauthorized = address(0xBEEF);
        address oracleProxy = deployment.get("contracts.Oracle");
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        IUUPSUpgradeableProxy(oracleProxy).upgradeTo(address(newImpl));

        // Verify upgrade from authorized account works
        vm.prank(getConfiguredOwner());
        IUUPSUpgradeableProxy(oracleProxy).upgradeTo(address(newImpl));
        OracleV2 oracleV2 = OracleV2(deployment.get("contracts.Oracle"));
        assertEq(oracleV2.getVersion(), 2, "Should be upgraded");
    }

    function test_UpgradeWithCall() public {
        _startDeployment("test_UpgradeWithCall");

        // Deploy oracle proxy
        deployment.deployOracleProxy("Oracle", 1000e18, getConfiguredOwner());

        // Finish deployment and transfer ownership
        deployment.finish();
        // Ownership transferred by finish()

        // Deploy new implementation
        OracleV2 newImpl = new OracleV2();

        // Upgrade with call to setPrice
        bytes memory upgradeCall = abi.encodeCall(OracleV2.setPrice, (3000e18));
        address oracleProxy = deployment.get("contracts.Oracle");
        vm.prank(getConfiguredOwner());
        IUUPSUpgradeableProxy(oracleProxy).upgradeToAndCall(address(newImpl), upgradeCall);

        // Verify upgrade and call execution
        OracleV2 oracleV2 = OracleV2(deployment.get("contracts.Oracle"));
        assertEq(oracleV2.getVersion(), 2, "Should be upgraded");
        assertEq(oracleV2.price(), 3000e18, "Price should be set by upgrade call");
        assertGt(oracleV2.lastUpdateTime(), 0, "Update time should be set");
    }

    function test_UpgradeTrackingInDeployment() public {
        _startDeployment("test_UpgradeTrackingInDeployment");

        // Deploy oracle proxy
        deployment.deployOracleProxy("Oracle", 1000e18, getConfiguredOwner());

        assertEq(
            deployment.getString("contracts.Oracle.implementation.ownershipModel"),
            "transfer-after-deploy",
            "Should show ownership was not transferred"
        );
        // Finish deployment and transfer ownership
        deployment.finish();
        // Ownership transferred by finish()

        // Verify deployment tracking after finish
        assertEq(
            deployment.getString("contracts.Oracle.implementation.ownershipModel"),
            "transferred-after-deploy",
            "Should show ownership was transferred"
        );
        assertTrue(deployment.has("contracts.Oracle"), "Should have Oracle entry");

        // Deploy new implementation
        OracleV2 newImpl = new OracleV2();

        // Upgrade proxy (called from owner - getConfiguredOwner)
        address oracle = deployment.get("contracts.Oracle");
        vm.prank(getConfiguredOwner());
        IUUPSUpgradeableProxy(oracle).upgradeTo(address(newImpl));

        // Verify deployment tracking persists
        assertEq(
            deployment.getString("contracts.Oracle.implementation.ownershipModel"),
            "transferred-after-deploy",
            "Should still show ownership was transferred"
        );
        assertTrue(deployment.has("contracts.Oracle"), "Should still have Oracle entry");

        // Address should remain the same (proxy address, not implementation)
        address proxyAddr = deployment.get("contracts.Oracle");
        OracleV2 oracleV2 = OracleV2(proxyAddr);
        assertEq(oracleV2.getVersion(), 2, "Proxy should have new implementation");
    }

    function test_UpgradeJsonPersistence() public {
        _startDeployment("test_UpgradeJsonPersistence");

        // Deploy and upgrade
        deployment.deployOracleProxy("Oracle", 1000e18, getConfiguredOwner());

        // Finish deployment and transfer ownership
        deployment.finish();
        // Ownership transferred by finish()

        OracleV2 newImpl = new OracleV2();
        address oracleProxy = deployment.get("contracts.Oracle");
        vm.prank(getConfiguredOwner());
        IUUPSUpgradeableProxy(oracleProxy).upgradeTo(address(newImpl));

        // Test JSON serialization after upgrade
        string memory json = deployment.toJson();
        assertTrue(vm.keyExistsJson(json, ".contracts.Oracle"), "Should contain Oracle in JSON");

        // Test JSON round-trip
        MockDeploymentUpgrade newDeployment = new MockDeploymentUpgrade();
        newDeployment.fromJsonNoSave(json);

        address restoredOracle = newDeployment.get("contracts.Oracle");
        assertTrue(restoredOracle != address(0), "Oracle should be restored from JSON");

        // Verify the restored proxy still has V2 functionality
        OracleV2 restoredOracleV2 = OracleV2(restoredOracle);
        assertEq(restoredOracleV2.getVersion(), 2, "Restored proxy should have V2 implementation");
    }

    function test_UpgradeProxyWithNewImplementationKey() public {
        _startDeployment("test_UpgradeProxyWithNewImplementationKey");

        // Deploy counter with V1
        deployment.deployCounterProxy("Counter", 10, getConfiguredOwner());
        CounterV1 counterV1 = CounterV1(deployment.get("contracts.Counter"));
        assertEq(counterV1.value(), 10, "Initial value should be 10");

        // Verify ownership still with harness (needed for upgrade)
        assertEq(counterV1.owner(), address(deployment), "Owner should be harness before finish");

        // Deploy V2 implementation separately
        CounterV2 v2Impl = new CounterV2();

        // Upgrade proxy to V2 using deployment system (harness is owner)
        deployment.upgradeProxy(
            "contracts.Counter",
            address(v2Impl),
            "",
            "CounterV2",
            "test/mocks/upgradeable/MockCounter.sol",
            address(this)
        );

        // Now transfer ownership
        deployment.finish();

        // Verify it's now V2
        CounterV2 counterV2 = CounterV2(deployment.get("contracts.Counter"));
        assertEq(counterV2.getVersion(), 2, "Should be version 2 after upgrade");
        assertEq(counterV2.value(), 10, "Value should persist");

        // Test new V2 functionality
        counterV2.decrement();
        assertEq(counterV2.value(), 9, "Decrement should work");
        assertEq(counterV2.decrementCount(), 1, "Decrement count should be 1");
    }

    function test_UpgradeAfterFinish() public {
        _startDeployment("test_UpgradeAfterFinish");

        // Deploy and finish deployment
        deployment.deployCounterProxy("Counter", 100, getConfiguredOwner());
        deployment.finish();

        // Verify ownership transferred
        CounterV1 counterV1 = CounterV1(deployment.get("contracts.Counter"));
        assertEq(counterV1.owner(), getConfiguredOwner(), "Owner should be getConfiguredOwner() after finish");
        assertEq(counterV1.value(), 100, "Initial value should be 100");

        // Deploy V2 implementation
        CounterV2 v2Impl = new CounterV2();

        // After finish(), deployment session is closed. Post-deployment upgrades
        // are performed directly by the final owner using UUPS (not through deployment system)
        address counterProxy = deployment.get("contracts.Counter");
        vm.prank(getConfiguredOwner());
        IUUPSUpgradeableProxy(counterProxy).upgradeTo(address(v2Impl));

        // Verify upgrade worked
        CounterV2 counterV2 = CounterV2(deployment.get("contracts.Counter"));
        assertEq(counterV2.getVersion(), 2, "Should be version 2");
        assertEq(counterV2.value(), 100, "Value should persist");
        assertEq(counterV2.owner(), getConfiguredOwner(), "Owner should still be getConfiguredOwner()");

        // Test V2 functionality
        vm.prank(getConfiguredOwner());
        counterV2.decrement();
        assertEq(counterV2.value(), 99, "Decrement should work");
        assertEq(counterV2.decrementCount(), 1, "Should track decrements");
    }

    function test_Downgrade_V1_to_V2_to_V1() public {
        _startDeployment("test_Downgrade_V1_to_V2_to_V1");

        // Deploy V1
        deployment.deployCounterProxy("Counter", 50, getConfiguredOwner());

        CounterV1 counterV1 = CounterV1(deployment.get("contracts.Counter"));
        assertEq(counterV1.value(), 50, "Initial V1 value");

        // Increment in V1
        vm.prank(getConfiguredOwner());
        counterV1.increment();
        assertEq(counterV1.value(), 51, "After increment");

        // Capture BEFORE first upgrade (V1 state)
        deployment.save(); // Advances to .002

        // Upgrade to V2
        CounterV2 v2Impl = new CounterV2();

        deployment.upgradeProxy(
            "contracts.Counter",
            address(v2Impl),
            "",
            "CounterV2",
            "test/mocks/upgradeable/MockCounter.sol",
            address(this)
        );

        CounterV2 counterV2 = CounterV2(deployment.get("contracts.Counter"));
        assertEq(counterV2.getVersion(), 2, "Should be V2");
        assertEq(counterV2.value(), 51, "Value persists to V2");

        // Use V2 functionality
        vm.prank(address(deployment)); // Still owned by harness
        counterV2.decrement();
        assertEq(counterV2.value(), 50, "After decrement");
        assertEq(counterV2.decrementCount(), 1, "Decrement count");

        // Capture AFTER first upgrade (V2 state)
        deployment.save(); // Advances to .003

        // Downgrade back to V1
        CounterV1 v1ImplNew = new CounterV1();
        deployment.upgradeProxy(
            "contracts.Counter",
            address(v1ImplNew),
            "",
            "CounterV1",
            "test/mocks/upgradeable/MockCounter.sol",
            address(this)
        );

        CounterV1 counterV1Again = CounterV1(deployment.get("contracts.Counter"));
        assertEq(counterV1Again.value(), 50, "Value persists to V1 again");

        // V1 doesn't have decrementCount, but value is preserved
        vm.prank(address(deployment));
        counterV1Again.increment();
        assertEq(counterV1Again.value(), 51, "Can still increment in V1");

        // Finish deployment
        deployment.finish();
        assertEq(counterV1Again.owner(), getConfiguredOwner(), "Owner transferred");
    }
}

// Import for non-BaoOwnable test
import {MockImplementationOZOwnable} from "../mocks/MockImplementationOZOwnable.sol";
import {DeploymentTesting} from "@bao-script/deployment/DeploymentTesting.sol";

/// @notice Memory-only harness for OZ Ownable tests (no file I/O)
contract MockDeploymentOZOwnable is DeploymentTesting {
    constructor() {
        addProxy("contracts.oz_proxy");
    }
}

contract DeploymentNonBaoOwnableTest is BaoDeploymentTest {
    MockDeploymentOZOwnable public deployment;
    address public admin;

    function setUp() public override {
        super.setUp();
        deployment = new MockDeploymentOZOwnable();
        admin = address(0x1234);
    }

    /// @notice Start deployment in memory-only mode
    function _startDeployment() internal {
        deployment.start("test", "DeploymentNonBaoOwnableTest", "");
        deployment.setAddress("owner", admin);
    }

    function test_OZOwnableWorks() public {
        _startDeployment();

        // Deploy proxy with OZ Ownable (not BaoOwnable)
        // This test verifies that OZ Ownable works with the deployment system
        MockImplementationOZOwnable ozImpl = new MockImplementationOZOwnable();
        // Initialize with harness as owner
        bytes memory initData = abi.encodeCall(MockImplementationOZOwnable.initialize, (address(deployment), 42));
        deployment.deployProxy(
            "contracts.oz_proxy",
            address(ozImpl),
            initData,
            "MockImplementationOZOwnable",
            "test/mocks/MockImplementationOZOwnable.sol",
            address(this)
        );

        assertNotEq(deployment.get("contracts.oz_proxy"), address(0), "Proxy should deploy");
        MockImplementationOZOwnable proxy = MockImplementationOZOwnable(deployment.get("contracts.oz_proxy"));

        // With OZ Ownable, owner is immediately the harness
        assertEq(proxy.owner(), address(deployment), "Owner should be harness");

        // finish() calls transferOwnership(admin) which works with OZ Ownable
        uint256 transferred = deployment.finish();

        assertEq(transferred, 1, "OZ Ownable ownership transfer succeeds");
        assertEq(proxy.owner(), admin, "Owner transferred to admin");
    }

    function test_OZOwnableDoesNotSupportPendingOwner() public {
        _startDeployment();

        // Deploy proxy with OZ Ownable
        MockImplementationOZOwnable ozImpl = new MockImplementationOZOwnable();
        bytes memory initData = abi.encodeCall(MockImplementationOZOwnable.initialize, (address(deployment), 42));
        deployment.deployProxy(
            "contracts.oz_proxy",
            address(ozImpl),
            initData,
            "MockImplementationOZOwnable",
            "test/mocks/MockImplementationOZOwnable.sol",
            address(this)
        );

        // OZ Ownable doesn't have pendingOwner() method
        (bool success, ) = deployment.get("contracts.oz_proxy").staticcall(abi.encodeWithSignature("pendingOwner()"));
        assertFalse(success, "OZ Ownable should not support pendingOwner()");

        // BaoOwnable also doesn't expose pendingOwner() publicly (only BaoOwnableTransferrable does)
        // So this test demonstrates the difference between OZ Ownable and BaoOwnableTransferrable
        // not between OZ Ownable and BaoOwnable
    }
}
