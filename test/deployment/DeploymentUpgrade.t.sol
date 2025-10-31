// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {TestDeployment} from "./TestDeployment.sol";
import {OracleV1} from "../mocks/upgradeable/MockOracle.sol";

import {CounterV1} from "../mocks/upgradeable/MockCounter.sol";
import {IUUPSUpgradeableProxy} from "@bao-script/deployment/Deployment.sol";
import {UUPSProxyDeployStub} from "@bao-script/deployment/UUPSProxyDeployStub.sol";

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
 * @title UpgradeTestHarness
 * @notice Test harness for proxy upgrade scenarios
 */
contract UpgradeTestHarness is TestDeployment {
    function deployOracleProxy(string memory key, uint256 price, address admin) public returns (address) {
        OracleV1 impl = new OracleV1();
        bytes memory initData = abi.encodeCall(OracleV1.initialize, (price, admin));
        return deployProxy(key, address(impl), initData);
    }

    function deployCounterProxy(string memory key, uint256 initialValue, address admin) public returns (address) {
        CounterV1 impl = new CounterV1();
        bytes memory initData = abi.encodeCall(CounterV1.initialize, (initialValue, admin));
        return deployProxy(key, address(impl), initData);
    }

    function upgradeOracle(string memory key, address newImplementation) public {
        address proxy = _get(key);
        IUUPSUpgradeableProxy(proxy).upgradeTo(newImplementation);
    }

    function upgradeCounter(string memory key, address newImplementation) public {
        address proxy = _get(key);
        IUUPSUpgradeableProxy(proxy).upgradeTo(newImplementation);
    }
}

/**
 * @title DeploymentUpgradeTest
 * @notice Tests proxy upgrade scenarios and implementation management
 */
contract DeploymentUpgradeTest is Test {
    UpgradeTestHarness public deployment;
    address public admin;
    UUPSProxyDeployStub internal stub;

    function setUp() public {
        deployment = new UpgradeTestHarness();
        admin = address(this);
        stub = UUPSProxyDeployStub(deployment.getDeployStub());
        deployment.startDeployment(admin, "upgrade-test", "v1.0.0", "upgrade-test-salt");
    }

    function test_BasicUpgrade() public {
        // Deploy initial proxy
        address oracle = deployment.deployOracleProxy("Oracle", 1000e18, admin);

        // Complete ownership transfer for all proxies
        uint256 transferred = deployment.finalizeOwnership(admin);
        assertEq(transferred, 1, "Should transfer ownership of 1 proxy");

        // Verify initial state
        OracleV1 oracleV1 = OracleV1(oracle);
        assertEq(oracleV1.price(), 1000e18, "Initial price should be set");
        assertEq(oracleV1.owner(), admin, "Owner should be set");

        // Deploy new implementation
        OracleV2 newImpl = new OracleV2();

        // Upgrade proxy (called from owner - this contract)
        IUUPSUpgradeableProxy(oracle).upgradeTo(address(newImpl));

        // Verify upgrade worked
        OracleV2 oracleV2 = OracleV2(oracle);
        assertEq(oracleV2.price(), 1000e18, "Price should persist after upgrade");
        assertEq(oracleV2.owner(), admin, "Owner should persist after upgrade");
        assertEq(oracleV2.getVersion(), 2, "Should be version 2");

        // Test new functionality
        oracleV2.setPrice(2000e18);
        assertEq(oracleV2.price(), 2000e18, "Price should be updated");
        assertGt(oracleV2.lastUpdateTime(), 0, "Update time should be set");
    }

    function test_MultipleProxyUpgrades() public {
        // Deploy multiple proxies
        address oracle1 = deployment.deployOracleProxy("Oracle1", 1000e18, admin);
        address oracle2 = deployment.deployOracleProxy("Oracle2", 1500e18, admin);
        address counter = deployment.deployCounterProxy("Counter", 10, admin);

        // Complete ownership transfer for all proxies
        uint256 transferred = deployment.finalizeOwnership(admin);
        assertEq(transferred, 3, "Should transfer ownership of all 3 proxies (2 oracles + 1 counter)");

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
        address counter = deployment.deployCounterProxy("Counter", 5, admin);

        // Complete ownership transfer for all proxies
        uint256 transferred = deployment.finalizeOwnership(admin);
        assertEq(transferred, 1, "Should transfer ownership of 1 proxy");

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
        // Deploy oracle with admin
        address oracle = deployment.deployOracleProxy("Oracle", 1000e18, admin);

        // Complete ownership transfer for all proxies
        uint256 transferred = deployment.finalizeOwnership(admin);
        assertEq(transferred, 1, "Should transfer ownership of 1 proxy");

        // Deploy new implementation
        OracleV2 newImpl = new OracleV2();

        // Try to upgrade from unauthorized account
        address unauthorized = address(0xBEEF);
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        IUUPSUpgradeableProxy(oracle).upgradeTo(address(newImpl));

        // Verify upgrade from authorized account works
        vm.prank(admin);
        IUUPSUpgradeableProxy(oracle).upgradeTo(address(newImpl));

        OracleV2 oracleV2 = OracleV2(oracle);
        assertEq(oracleV2.getVersion(), 2, "Should be upgraded");
    }

    function test_UpgradeWithCall() public {
        // Deploy oracle proxy
        address oracle = deployment.deployOracleProxy("Oracle", 1000e18, admin);

        // Complete ownership transfer for all proxies
        uint256 transferred = deployment.finalizeOwnership(admin);
        assertEq(transferred, 1, "Should transfer ownership of 1 proxy");

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
        deployment.deployOracleProxy("Oracle", 1000e18, admin);

        // Complete ownership transfer for all proxies
        uint256 transferred = deployment.finalizeOwnership(admin);
        assertEq(transferred, 1, "Should transfer ownership of 1 proxy");

        // Verify initial deployment tracking
        assertEq(deployment.getEntryType("Oracle"), "proxy", "Should be tracked as proxy");
        assertTrue(deployment.hasByString("Oracle"), "Should have Oracle entry");

        // Deploy new implementation
        OracleV2 newImpl = new OracleV2();

        // Upgrade proxy (called from owner - this contract)
        address oracle = deployment.getByString("Oracle");
        IUUPSUpgradeableProxy(oracle).upgradeTo(address(newImpl));

        // Verify deployment tracking persists
        assertEq(deployment.getEntryType("Oracle"), "proxy", "Should still be tracked as proxy");
        assertTrue(deployment.hasByString("Oracle"), "Should still have Oracle entry");

        // Address should remain the same (proxy address, not implementation)
        address proxyAddr = deployment.getByString("Oracle");
        OracleV2 oracleV2 = OracleV2(proxyAddr);
        assertEq(oracleV2.getVersion(), 2, "Proxy should have new implementation");
    }

    function test_UpgradeJsonPersistence() public {
        // Deploy and upgrade
        address oracle = deployment.deployOracleProxy("Oracle", 1000e18, admin);

        // Complete ownership transfer for all proxies
        uint256 transferred = deployment.finalizeOwnership(admin);
        assertEq(transferred, 1, "Should transfer ownership of 1 proxy");

        OracleV2 newImpl = new OracleV2();
        IUUPSUpgradeableProxy(oracle).upgradeTo(address(newImpl));

        deployment.finishDeployment();

        // Test JSON serialization after upgrade
        string memory json = deployment.toJson();
        assertTrue(vm.keyExistsJson(json, ".deployment.Oracle"), "Should contain Oracle in JSON");

        // Test JSON round-trip
        UpgradeTestHarness newDeployment = new UpgradeTestHarness();
        stub.setDeployer(address(newDeployment));
        newDeployment.fromJson(json);

        address restoredOracle = newDeployment.getByString("Oracle");
        assertTrue(restoredOracle != address(0), "Oracle should be restored from JSON");

        // Verify the restored proxy still has V2 functionality
        OracleV2 restoredOracleV2 = OracleV2(restoredOracle);
        assertEq(restoredOracleV2.getVersion(), 2, "Restored proxy should have V2 implementation");
    }
}
