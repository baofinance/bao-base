// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {TestDeployment} from "./TestDeployment.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {DeploymentRegistry} from "@bao-script/deployment/DeploymentRegistry.sol";

// UUPS implementation for testing
contract CounterV1 is Initializable, UUPSUpgradeable {
    uint256 public value;

    function initialize(uint256 _value) external initializer {
        value = _value;
    }

    function increment() external {
        value++;
    }

    function _authorizeUpgrade(address) internal override {}
}

// Test harness
contract ProxyTestHarness is TestDeployment {
    function deployCounterProxy(
        string memory key,
        string memory saltString,
        uint256 initialValue
    ) public returns (address) {
        CounterV1 impl = new CounterV1();
        bytes memory initData = abi.encodeCall(CounterV1.initialize, (initialValue));
        return deployProxy(key, address(impl), initData, saltString);
    }
}

/**
 * @title DeploymentProxyTest
 * @notice Tests proxy deployment functionality (CREATE3)
 */
contract DeploymentProxyTest is Test {
    ProxyTestHarness public deployment;

    function setUp() public {
        deployment = new ProxyTestHarness();
        deployment.startDeployment(address(this), "test", "v1.0.0");
    }

    function test_DeployProxy() public {
        address proxyAddr = deployment.deployCounterProxy("counter", "counter-v1", 42);

        assertTrue(proxyAddr != address(0));
        assertTrue(deployment.hasByString("counter"));
        assertEq(deployment.getByString("counter"), proxyAddr);
        assertEq(deployment.getEntryType("counter"), "proxy");

        // Verify proxy is working
        CounterV1 counter = CounterV1(proxyAddr);
        assertEq(counter.value(), 42);

        counter.increment();
        assertEq(counter.value(), 43);
    }

    function test_PredictProxyAddress() public {
        address predicted = deployment.predictProxyAddress("counter-v1");
        address actual = deployment.deployCounterProxy("counter", "counter-v1", 42);

        assertEq(predicted, actual);
    }

    function test_DeterministicProxyAddress() public {
        // Deploy with same salt should produce same address
        address addr1 = deployment.predictProxyAddress("deterministic-salt");

        // Deploy proxy
        address deployed = deployment.deployCounterProxy("counter1", "deterministic-salt", 100);
        assertEq(deployed, addr1);

        // Prediction should still work for different salt
        address addr2 = deployment.predictProxyAddress("different-salt");
        assertNotEq(addr2, addr1);
    }

    function test_MultipleProxies() public {
        address proxy1 = deployment.deployCounterProxy("counter1", "counter-1", 10);
        address proxy2 = deployment.deployCounterProxy("counter2", "counter-2", 20);
        address proxy3 = deployment.deployCounterProxy("counter3", "counter-3", 30);

        assertNotEq(proxy1, proxy2);
        assertNotEq(proxy2, proxy3);

        assertTrue(deployment.hasByString("counter1"));
        assertTrue(deployment.hasByString("counter2"));
        assertTrue(deployment.hasByString("counter3"));

        CounterV1 c1 = CounterV1(proxy1);
        CounterV1 c2 = CounterV1(proxy2);
        CounterV1 c3 = CounterV1(proxy3);

        assertEq(c1.value(), 10);
        assertEq(c2.value(), 20);
        assertEq(c3.value(), 30);
    }

    function test_RevertWhen_ProxyAlreadyExists() public {
        deployment.deployCounterProxy("counter", "counter-v1", 42);

        vm.expectRevert(abi.encodeWithSelector(DeploymentRegistry.ContractAlreadyExists.selector, "counter"));
        deployment.deployCounterProxy("counter", "counter-v1", 100);
    }

    function test_RevertWhen_ProxyWithoutSalt() public {
        CounterV1 impl = new CounterV1();
        bytes memory initData = abi.encodeCall(CounterV1.initialize, (42));

        vm.expectRevert(Deployment.SaltRequired.selector);
        deployment.deployProxy("counter", address(impl), initData, "");
    }

    function test_RevertWhen_ProxyWithoutImplementation() public {
        vm.expectRevert(Deployment.ImplementationRequired.selector);
        deployment.deployProxy("counter", address(0), "", "counter-v1");
    }
}
