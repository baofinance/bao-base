// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {MockDeployment} from "./MockDeployment.sol";

import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {DeploymentRegistry} from "@bao-script/deployment/DeploymentRegistry.sol";
import {CounterV1} from "../mocks/upgradeable/MockCounter.sol";

// Test harness extends MockDeployment
contract MockDeploymentProxy is MockDeployment {
    function deployCounterProxy(string memory key, uint256 initialValue, address owner) public returns (address) {
        string memory implKey = implementationKey(key, "CounterV1");

        // Only deploy implementation if it doesn't exist yet
        if (!has(implKey)) {
            CounterV1 impl = new CounterV1();
            implKey = registerImplementation(key, address(impl), "CounterV1", "test/mocks/upgradeable/MockCounter.sol");
        }

        bytes memory initData = abi.encodeCall(CounterV1.initialize, (initialValue, owner));
        return this.deployProxy(key, implKey, initData);
    }
}

/**
 * @title DeploymentProxyTest
 * @notice Tests proxy deployment functionality (CREATE3)
 */
contract DeploymentProxyTest is BaoDeploymentTest {
    MockDeploymentProxy public deployment;
    address internal admin;
    address internal outsider;
    string constant TEST_NETWORK = "test";
    string constant TEST_SALT = "proxy-test-salt";
    string constant TEST_VERSION = "v1.0.0";

    function setUp() public override {
        super.setUp();
        deployment = new MockDeploymentProxy();
        startDeploymentSession(deployment, address(this), TEST_NETWORK, TEST_VERSION, TEST_SALT, false);
        admin = makeAddr("admin");
        outsider = makeAddr("outsider");
    }

    function test_DeployProxy() public {
        address proxyAddr = deployment.deployCounterProxy("counter", 42, admin);

        assertTrue(proxyAddr != address(0));
        assertTrue(deployment.has("counter"));
        assertEq(deployment.get("counter"), proxyAddr);
        assertEq(deployment.getType("counter"), "proxy");

        // Verify proxy is working
        CounterV1 counter = CounterV1(proxyAddr);
        assertEq(counter.value(), 42);
        assertEq(counter.owner(), address(deployment)); // harness is initial owner

        // Complete ownership transfer (within 3600 second window)
        vm.prank(address(deployment));
        counter.transferOwnership(admin);
        assertEq(counter.owner(), admin);

        vm.prank(admin);
        counter.increment();
        assertEq(counter.value(), 43);
    }

    function test_PredictProxyAddress() public {
        address predicted = deployment.predictProxyAddress("counter");
        address actual = deployment.deployCounterProxy("counter", 42, admin);

        assertEq(predicted, actual);
    }

    function test_DeterministicProxyAddress() public {
        // Deploy with same key should produce same address
        address addr1 = deployment.predictProxyAddress("counter1");

        // Deploy proxy
        address deployed = deployment.deployCounterProxy("counter1", 100, admin);
        assertEq(deployed, addr1);

        // Prediction should work for different key
        address addr2 = deployment.predictProxyAddress("counter2");
        assertNotEq(addr2, addr1);
    }

    function test_MultipleProxies() public {
        address proxy1 = deployment.deployCounterProxy("counter1", 10, admin);
        address proxy2 = deployment.deployCounterProxy("counter2", 20, admin);
        address proxy3 = deployment.deployCounterProxy("counter3", 30, admin);

        assertNotEq(proxy1, proxy2);
        assertNotEq(proxy2, proxy3);

        assertTrue(deployment.has("counter1"));
        assertTrue(deployment.has("counter2"));
        assertTrue(deployment.has("counter3"));

        CounterV1 c1 = CounterV1(proxy1);
        CounterV1 c2 = CounterV1(proxy2);
        CounterV1 c3 = CounterV1(proxy3);

        assertEq(c1.value(), 10);
        assertEq(c2.value(), 20);
        assertEq(c3.value(), 30);
    }

    function test_RevertWhen_ProxyAlreadyExists() public {
        deployment.deployCounterProxy("counter", 42, admin);

        vm.expectRevert(abi.encodeWithSelector(DeploymentRegistry.ContractAlreadyExists.selector, "counter"));
        deployment.deployCounterProxy("counter", 100, admin);
    }

    function test_RevertWhen_ProxyWithEmptyKey() public {
        CounterV1 impl = new CounterV1();
        string memory implKey = deployment.registerImplementation(
            "testImplProxy",
            address(impl),
            "CounterV1",
            "test/mocks/upgradeable/MockCounter.sol"
        );
        bytes memory initData = abi.encodeCall(CounterV1.initialize, (42, admin));

        vm.expectRevert(DeploymentRegistry.KeyRequired.selector);
        deployment.deployProxy("", implKey, initData);
    }

    function test_RevertWhen_ProxyWithoutImplementation() public {
    vm.expectRevert();
    deployment.deployProxy("counter", "nonexistent_impl", "");
    }

    function test_ResumeRestoresPredictions_() public {
        address existingProxy = deployment.deployCounterProxy("counter", 11, admin);
        string memory expectedMessage = "resumed registry retains counter";
        assertEq(deployment.get("counter"), existingProxy, expectedMessage);

        deployment.finish();
        string memory json = deployment.toJsonString();

        MockDeploymentProxy resumed = new MockDeploymentProxy();
        resumed.fromJsonString(json);
        resumed.resumeAfterLoad();

        assertEq(resumed.get("counter"), existingProxy, "resumed counter address stable");

        address resumedPrediction = resumed.predictProxyAddress("counterNext");
        address resumedDeployed = resumed.deployCounterProxy("counterNext", 22, admin);

        assertEq(resumedPrediction, resumedDeployed, "resumed prediction matches deployment");
        assertEq(resumed.get("counterNext"), resumedDeployed, "resumed registry stores new proxy");
    }

    function test_FinalizeOwnershipAfterResumeSkipsResumedProxy() public {
        deployment.deployCounterProxy("counter", 5, admin);
        deployment.finish();
        string memory json = deployment.toJsonString();

        MockDeploymentProxy resumed = new MockDeploymentProxy();
        resumed.fromJsonString(json);

        uint256 transferred = resumed.countTransferrableProxies(admin);
        assertEq(transferred, 0, "resumed entries should be skipped");
    }

    function test_FinishSkipsProxiesWithUnexpectedOwner() public {
        address proxyAddr = deployment.deployCounterProxy("counter", 7, admin);
        CounterV1 counter = CounterV1(proxyAddr);

        // Transfer ownership from harness to outsider manually
        vm.prank(address(deployment));
        counter.transferOwnership(outsider);

        // finish() should skip this proxy since owner is not the harness
        uint256 transferred = deployment.finish();
        assertEq(transferred, 0, "Should not transfer ownership when current owner is not harness");
        assertEq(counter.owner(), outsider, "Owner should remain outsider");
    }
}
