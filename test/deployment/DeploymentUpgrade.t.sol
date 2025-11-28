// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {DeploymentJsonTesting} from "@bao-script/deployment/DeploymentJsonTesting.sol";
import {DeploymentKeys} from "@bao-script/deployment/DeploymentKeys.sol";
import {OracleV1} from "../mocks/upgradeable/MockOracle.sol";

import {CounterV1} from "../mocks/upgradeable/MockCounter.sol";
import {IUUPSUpgradeableProxy} from "@bao-script/deployment/Deployment.sol";

// Upgraded version of Oracle for testing
contract OracleV2 is OracleV1 {
    uint256 public lastUpdateTime;

    function setPrice(uint256 _price) external override onlyOwner {
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
    function deployOracleProxy(string memory key, uint256 price, address admin) public returns (address) {
        OracleV1 impl = new OracleV1();
        bytes memory initData = abi.encodeCall(OracleV1.initialize, (price, admin));
        return
            this.deployProxy(
                key,
                address(impl),
                initData,
                "OracleV1",
                "test/mocks/upgradeable/MockOracle.sol",
                address(this)
            );
    }

    function deployCounterProxy(string memory key, uint256 initialValue, address admin) public returns (address) {
        CounterV1 impl = new CounterV1();

        bytes memory initData = abi.encodeCall(CounterV1.initialize, (initialValue, admin));
        return
            this.deployProxy(
                key,
                address(impl),
                initData,
                "CounterV1",
                "test/mocks/upgradeable/Counter.sol",
                address(this)
            );
    }

    function upgradeOracle(string memory key, address newImplementation) public {
        address proxy = get(key);
        IUUPSUpgradeableProxy(proxy).upgradeTo(newImplementation);
    }

    function upgradeCounter(string memory key, address newImplementation) public {
        address proxy = get(key);
        IUUPSUpgradeableProxy(proxy).upgradeTo(newImplementation);
    }

    /// @notice Count how many proxies are still owned by this harness (for testing)
    /// @dev Useful for verifying ownership transfer behavior in tests
    function countTransferrableProxies(address /* newOwner */) public view returns (uint256) {
        uint256 stillOwned = 0;
        string[] memory allKeysList = this.keys();

        for (uint256 i = 0; i < allKeysList.length; i++) {
            string memory key = allKeysList[i];

            // Check if this is a proxy by looking for .type metadata
            string memory typeKey = string.concat(key, ".type");
            if (!has(typeKey)) continue;

            string memory entryType = getString(typeKey);
            if (keccak256(bytes(entryType)) == keccak256(bytes("proxy"))) {
                address proxy = get(key);
                (bool success, bytes memory data) = proxy.staticcall(abi.encodeWithSignature("owner()"));
                if (success && data.length == 32) {
                    address currentOwner = abi.decode(data, (address));
                    if (currentOwner == address(this)) {
                        ++stillOwned;
                    }
                }
            }
        }

        return stillOwned;
    }

    /// @notice Helper for tests to compute implementation keys
    function implementationKey(string memory proxyKey, string memory contractType) public pure returns (string memory) {
        return string.concat(proxyKey, "__", contractType);
    }
}

/**
 * @title DeploymentUpgradeTest
 * @notice Tests proxy upgrade scenarios and implementation management
 */
contract DeploymentUpgradeTest is BaoDeploymentTest {
    MockDeploymentUpgrade public deployment;
    string constant TEST_NETWORK = "upgrade-test";
    string constant TEST_SALT = "upgrade-test-salt";

    function setUp() public override {
        super.setUp();
        deployment = new MockDeploymentUpgrade();
        deployment.start(TEST_NETWORK, TEST_SALT, "");
    }

    /// @notice Get the configured final owner from deployment data
    function getConfiguredOwner() internal view returns (address) {
        return deployment.getAddress(deployment.OWNER());
    }

    function test_BasicUpgrade() public {
        // Deploy initial proxy
        address oracle = deployment.deployOracleProxy("Oracle", 1000e18, getConfiguredOwner());

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
        OracleV1 oracleV1 = OracleV1(oracle);
        assertEq(oracleV1.price(), 1000e18, "Initial price should be set");
        assertEq(oracleV1.owner(), getConfiguredOwner(), "Owner should be set");

        // Deploy new implementation
        OracleV2 newImpl = new OracleV2();

        // Upgrade proxy (called from owner - this contract)
        IUUPSUpgradeableProxy(oracle).upgradeTo(address(newImpl));

        // Verify upgrade worked
        OracleV2 oracleV2 = OracleV2(oracle);
        assertEq(oracleV2.price(), 1000e18, "Price should persist after upgrade");
        assertEq(oracleV2.owner(), getConfiguredOwner(), "Owner should persist after upgrade");
        assertEq(oracleV2.getVersion(), 2, "Should be version 2");

        // Test new functionality
        oracleV2.setPrice(2000e18);
        assertEq(oracleV2.price(), 2000e18, "Price should be updated");
        assertGt(oracleV2.lastUpdateTime(), 0, "Update time should be set");
    }

    function test_MultipleProxyUpgrades() public {
        // Deploy multiple proxies
        address oracle1 = deployment.deployOracleProxy("Oracle1", 1000e18, getConfiguredOwner());
        address oracle2 = deployment.deployOracleProxy("Oracle2", 1500e18, getConfiguredOwner());
        address counter = deployment.deployCounterProxy("Counter", 10, getConfiguredOwner());

        // Finish deployment and transfer ownership
        deployment.finish();
        // Ownership transferred by finish()

        // Deploy new implementations
        OracleV2 newOracleImpl = new OracleV2();
        CounterV2 newCounterImpl = new CounterV2();

        // Upgrade Oracle1 (called from owner - this contract)
        IUUPSUpgradeableProxy(oracle1).upgradeTo(address(newOracleImpl));

        // Upgrade Counter (called from owner - this contract)
        IUUPSUpgradeableProxy(counter).upgradeTo(address(newCounterImpl));

        // Verify Oracle1 upgrade
        OracleV2 oracle1V2 = OracleV2(oracle1);
        assertEq(oracle1V2.getVersion(), 2, "Oracle1 should be version 2");
        assertEq(oracle1V2.price(), 1000e18, "Oracle1 price should persist");

        // Verify Oracle2 is still V1
        OracleV1 oracle2V1 = OracleV1(oracle2);
        assertEq(oracle2V1.price(), 1500e18, "Oracle2 should maintain original price");

        // Verify Counter upgrade
        CounterV2 counterV2 = CounterV2(counter);
        assertEq(counterV2.getVersion(), 2, "Counter should be version 2");
        assertEq(counterV2.value(), 10, "Counter value should persist");

        // Test new Counter functionality
        counterV2.decrement();
        assertEq(counterV2.value(), 9, "Counter should decrement");
        assertEq(counterV2.decrementCount(), 1, "Decrement count should be tracked");
    }

    function test_UpgradeWithStateTransition() public {
        // Deploy counter proxy
        address counter = deployment.deployCounterProxy("Counter", 5, getConfiguredOwner());

        // Finish deployment and transfer ownership
        deployment.finish();
        // Ownership transferred by finish()

        // Interact with V1
        CounterV1 counterV1 = CounterV1(counter);
        counterV1.increment();
        counterV1.increment();
        assertEq(counterV1.value(), 7, "Should have incremented to 7");

        // Deploy and upgrade to V2 (called from owner - this contract)
        CounterV2 newImpl = new CounterV2();
        IUUPSUpgradeableProxy(counter).upgradeTo(address(newImpl));

        // Verify state persisted
        CounterV2 counterV2 = CounterV2(counter);
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
        // Deploy oracle with getConfiguredOwner()
        address oracle = deployment.deployOracleProxy("Oracle", 1000e18, getConfiguredOwner());

        // Finish deployment and transfer ownership
        deployment.finish();
        // Ownership transferred by finish()

        // Deploy new implementation
        OracleV2 newImpl = new OracleV2();

        // Try to upgrade from unauthorized account
        address unauthorized = address(0xBEEF);
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        IUUPSUpgradeableProxy(oracle).upgradeTo(address(newImpl));

        // Verify upgrade from authorized account works
        vm.prank(getConfiguredOwner());
        IUUPSUpgradeableProxy(oracle).upgradeTo(address(newImpl));

        OracleV2 oracleV2 = OracleV2(oracle);
        assertEq(oracleV2.getVersion(), 2, "Should be upgraded");
    }

    function test_UpgradeWithCall() public {
        // Deploy oracle proxy
        address oracle = deployment.deployOracleProxy("Oracle", 1000e18, getConfiguredOwner());

        // Finish deployment and transfer ownership
        deployment.finish();
        // Ownership transferred by finish()

        // Deploy new implementation
        OracleV2 newImpl = new OracleV2();

        // Upgrade with call to set new price
        bytes memory upgradeCall = abi.encodeCall(OracleV2.setPrice, (3000e18));
        IUUPSUpgradeableProxy(oracle).upgradeToAndCall(address(newImpl), upgradeCall);

        // Verify upgrade and call execution
        OracleV2 oracleV2 = OracleV2(oracle);
        assertEq(oracleV2.getVersion(), 2, "Should be upgraded");
        assertEq(oracleV2.price(), 3000e18, "Price should be set by upgrade call");
        assertGt(oracleV2.lastUpdateTime(), 0, "Update time should be set");
    }

    function test_UpgradeTrackingInDeployment() public {
        // Deploy oracle proxy
        deployment.deployOracleProxy("Oracle", 1000e18, getConfiguredOwner());

        // Finish deployment and transfer ownership
        deployment.finish();
        // Ownership transferred by finish()

        // Verify initial deployment tracking
        assertEq(deployment.getString("Oracle.type"), "proxy", "Should be tracked as proxy");
        assertTrue(deployment.has("Oracle"), "Should have Oracle entry");

        // Deploy new implementation
        OracleV2 newImpl = new OracleV2();

        // Upgrade proxy (called from owner - this contract)
        address oracle = deployment.get("Oracle");
        IUUPSUpgradeableProxy(oracle).upgradeTo(address(newImpl));

        // Verify deployment tracking persists
        assertEq(deployment.getString("Oracle.type"), "proxy", "Should still be tracked as proxy");
        assertTrue(deployment.has("Oracle"), "Should still have Oracle entry");

        // Address should remain the same (proxy address, not implementation)
        address proxyAddr = deployment.get("Oracle");
        OracleV2 oracleV2 = OracleV2(proxyAddr);
        assertEq(oracleV2.getVersion(), 2, "Proxy should have new implementation");
    }

    function test_UpgradeJsonPersistence() public {
        // Deploy and upgrade
        address oracle = deployment.deployOracleProxy("Oracle", 1000e18, getConfiguredOwner());

        // Finish deployment and transfer ownership
        deployment.finish();
        // Ownership transferred by finish()

        OracleV2 newImpl = new OracleV2();
        IUUPSUpgradeableProxy(oracle).upgradeTo(address(newImpl));

        // Test JSON serialization after upgrade
        string memory json = deployment.toJson();
        assertTrue(vm.keyExistsJson(json, ".deployment.Oracle"), "Should contain Oracle in JSON");

        // Test JSON round-trip
        MockDeploymentUpgrade newDeployment = new MockDeploymentUpgrade();
        newDeployment.fromJson(json);

        address restoredOracle = newDeployment.get("Oracle");
        assertTrue(restoredOracle != address(0), "Oracle should be restored from JSON");

        // Verify the restored proxy still has V2 functionality
        OracleV2 restoredOracleV2 = OracleV2(restoredOracle);
        assertEq(restoredOracleV2.getVersion(), 2, "Restored proxy should have V2 implementation");
    }

    function test_UpgradeProxyWithNewImplementationKey() public {
        // Deploy counter with V1
        address counterAddr = deployment.deployCounterProxy("Counter", 10, getConfiguredOwner());
        CounterV1 counterV1 = CounterV1(counterAddr);
        assertEq(counterV1.value(), 10, "Initial value should be 10");

        // Verify ownership still with harness (needed for upgrade)
        assertEq(counterV1.owner(), address(deployment), "Owner should be harness before finish");

        // Deploy V2 implementation separately
        CounterV2 v2Impl = new CounterV2();

        // Upgrade proxy to V2 using deployment system (harness is owner)
        deployment.upgradeProxy(
            "Counter",
            address(v2Impl),
            "",
            "CounterV2",
            "test/mocks/upgradeable/MockCounter.sol",
            address(this)
        );

        // Now transfer ownership
        deployment.finish();

        // Verify it's now V2
        CounterV2 counterV2 = CounterV2(counterAddr);
        assertEq(counterV2.getVersion(), 2, "Should be version 2 after upgrade");
        assertEq(counterV2.value(), 10, "Value should persist");

        // Test new V2 functionality
        counterV2.decrement();
        assertEq(counterV2.value(), 9, "Decrement should work");
        assertEq(counterV2.decrementCount(), 1, "Decrement count should be 1");
    }

    function test_UpgradeAfterFinish() public {
        // Deploy and finish deployment
        address counterAddr = deployment.deployCounterProxy("Counter", 100, getConfiguredOwner());
        deployment.finish();

        // Verify ownership transferred
        CounterV1 counterV1 = CounterV1(counterAddr);
        assertEq(counterV1.owner(), getConfiguredOwner(), "Owner should be getConfiguredOwner() after finish");
        assertEq(counterV1.value(), 100, "Initial value should be 100");

        // Deploy V2 implementation
        CounterV2 v2Impl = new CounterV2();

        // Upgrade from getConfiguredOwner() (owner) using UUPS directly since deployment is finished
        vm.prank(getConfiguredOwner());
        IUUPSUpgradeableProxy(counterAddr).upgradeTo(address(v2Impl));

        // Verify upgrade worked
        CounterV2 counterV2 = CounterV2(counterAddr);
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
        // Deploy V1
        address counterAddr = deployment.deployCounterProxy("Counter", 50, getConfiguredOwner());

        CounterV1 counterV1 = CounterV1(counterAddr);
        assertEq(counterV1.value(), 50, "Initial V1 value");

        // Increment in V1
        vm.prank(getConfiguredOwner());
        counterV1.increment();
        assertEq(counterV1.value(), 51, "After increment");

        // Upgrade to V2
        CounterV2 v2Impl = new CounterV2();

        deployment.upgradeProxy(
            "Counter",
            address(v2Impl),
            "",
            "CounterV2",
            "test/mocks/upgradeable/MockCounter.sol",
            address(this)
        );

        CounterV2 counterV2 = CounterV2(counterAddr);
        assertEq(counterV2.getVersion(), 2, "Should be V2");
        assertEq(counterV2.value(), 51, "Value persists to V2");

        // Use V2 functionality
        vm.prank(address(deployment)); // Still owned by harness
        counterV2.decrement();
        assertEq(counterV2.value(), 50, "After decrement");
        assertEq(counterV2.decrementCount(), 1, "Decrement count");

        // Downgrade back to V1
        CounterV1 v1ImplNew = new CounterV1();
        deployment.upgradeProxy(
            "Counter",
            address(v1ImplNew),
            "",
            "CounterV1",
            "test/mocks/upgradeable/MockCounter.sol",
            address(this)
        );

        CounterV1 counterV1Again = CounterV1(counterAddr);
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

contract DeploymentNonBaoOwnableTest is BaoDeploymentTest {
    MockDeploymentUpgrade public deployment;
    address public admin;
    string constant TEST_NETWORK = "non-bao-test";
    string constant TEST_SALT = "non-bao-test-salt";

    function setUp() public override {
        super.setUp();
        deployment = new MockDeploymentUpgrade();
        admin = address(this);
        deployment.start(TEST_NETWORK, TEST_SALT, "");
    }

    function test_OZOwnableWorks() public {
        // Deploy proxy with OZ Ownable (not BaoOwnable)
        // This test verifies that OZ Ownable works with the deployment system
        MockImplementationOZOwnable ozImpl = new MockImplementationOZOwnable();
        // Initialize with harness as owner
        bytes memory initData = abi.encodeCall(MockImplementationOZOwnable.initialize, (address(deployment), 42));
        address proxyAddr = deployment.deployProxy(
            "oz_proxy",
            address(ozImpl),
            initData,
            "MockImplementationOZOwnable",
            "test/mocks/MockImplementationOZOwnable.sol",
            address(this)
        );

        assertTrue(proxyAddr != address(0), "Proxy should deploy");
        MockImplementationOZOwnable proxy = MockImplementationOZOwnable(proxyAddr);

        // With OZ Ownable, owner is immediately the harness
        assertEq(proxy.owner(), address(deployment), "Owner should be harness");

        // finish() calls transferOwnership(admin) which works with OZ Ownable
        uint256 transferred = deployment.finish();

        assertEq(transferred, 1, "OZ Ownable ownership transfer succeeds");
        assertEq(proxy.owner(), admin, "Owner transferred to admin");
    }

    function test_OZOwnableDoesNotSupportPendingOwner() public {
        // Deploy proxy with OZ Ownable
        MockImplementationOZOwnable ozImpl = new MockImplementationOZOwnable();
        bytes memory initData = abi.encodeCall(MockImplementationOZOwnable.initialize, (address(deployment), 42));
        address proxyAddr = deployment.deployProxy("oz_proxy", address(ozImpl), initData,
            "MockImplementationOZOwnable",
            "test/mocks/MockImplementationOZOwnable.sol", address(this));

        // OZ Ownable doesn't have pendingOwner() method
        (bool success, ) = proxyAddr.staticcall(abi.encodeWithSignature("pendingOwner()"));
        assertFalse(success, "OZ Ownable should not support pendingOwner()");

        // BaoOwnable also doesn't expose pendingOwner() publicly (only BaoOwnableTransferrable does)
        // So this test demonstrates the difference between OZ Ownable and BaoOwnableTransferrable
        // not between OZ Ownable and BaoOwnable
    }
}
