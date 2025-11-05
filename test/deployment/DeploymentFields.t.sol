// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {MockDeployment} from "./MockDeployment.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {FundedVault} from "@bao-test/mocks/deployment/FundedVault.sol";

contract SimpleImplementation is Initializable, UUPSUpgradeable {
    uint256 public value;
    address public admin;

    function initialize(uint256 _value, address _admin) external initializer {
        value = _value;
        admin = _admin;
    }

    function _authorizeUpgrade(address) internal view override {
        require(msg.sender == admin, "Not admin");
    }
}

library TestLib {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        return a + b;
    }
}

// Test harness with helper methods
contract FieldsTestHarness is MockDeployment {
    function deployMockERC20(string memory key, string memory name, string memory symbol) public returns (address) {
        MockERC20 token = new MockERC20(name, symbol, 18);
        registerContract(key, address(token), "MockERC20", "test/mocks/tokens/MockERC20.sol", "contract");
        return _get(key);
    }

    function deploySimpleProxy(string memory key, uint256 value, address admin) public returns (address) {
        SimpleImplementation impl = new SimpleImplementation();
        string memory implKey = string.concat(key, "_impl");
        registerImplementation(implKey, address(impl), "SimpleImplementation", "test/SimpleImplementation.sol");
        bytes memory initData = abi.encodeCall(SimpleImplementation.initialize, (value, admin));
        address proxy = this.deployProxy(key, implKey, initData);
        return proxy;
    }

    function deployTestLibrary(string memory key) public returns (address) {
        bytes memory libBytecode = type(TestLib).creationCode;
        deployLibrary(key, libBytecode, "TestLib", "test/TestLib.sol");
        return _get(key);
    }
}

/**
 * @title DeploymentFieldsTest
 * @notice Tests that factory and deployer fields are correctly set for different entry types
 */
contract DeploymentFieldsTest is BaoDeploymentTest {
    FieldsTestHarness public deployment;
    address public admin;
    string constant TEST_NETWORK = "test-network";
    string constant TEST_SALT = "fields-test-salt";
    string constant TEST_VERSION = "v1.0.0";

    function setUp() public {
        super.setUp();
        deployment = new FieldsTestHarness();
        admin = address(this);
        deployment.start(admin, TEST_NETWORK, TEST_VERSION, TEST_SALT);
    }

    function test_ProxyHasFactoryAndDeployer() public {
        // Deploy a proxy
        deployment.deploySimpleProxy("proxy1", 100, admin);
        deployment.finish();

        // Use toJson() for verification without saving file
        string memory json = deployment.toJson();

        // Verify proxy has both factory and deployer
        address factory = vm.parseJsonAddress(json, ".deployment.proxy1.factory");
        address deployer = vm.parseJsonAddress(json, ".deployment.proxy1.deployer");

        // Both should be the deployment contract (which is the CREATE3 factory and executor)
        assertEq(factory, address(deployment), "Proxy factory should be deployment contract");
        assertEq(deployer, address(deployment), "Proxy deployer should be deployment contract");
        assertTrue(factory != address(0), "Factory should not be zero");
        assertTrue(deployer != address(0), "Deployer should not be zero");
    }

    function test_ImplementationHasDeployerNoFactory() public {
        // Deploy implementation (via proxy deployment which creates implementation entry)
        deployment.deploySimpleProxy("proxy1", 100, admin);
        deployment.finish();

        // Use toJson() for verification without saving file
        string memory json = deployment.toJson();

        // Implementation should have deployer but no factory (not CREATE3)
        bool hasFactory = vm.keyExistsJson(json, ".deployment.proxy1_impl.factory");
        address deployer = vm.parseJsonAddress(json, ".deployment.proxy1_impl.deployer");

        assertFalse(hasFactory, "Implementation should not have factory field");
        assertEq(deployer, address(deployment), "Implementation deployer should be deployment contract");
    }

    function test_RegularContractHasDeployerNoFactory() public {
        // Deploy regular contract
        deployment.deployMockERC20("token1", "Token1", "TK1");
        deployment.finish();

        // Use toJson() for verification without saving file
        string memory json = deployment.toJson();

        // Regular contract should have deployer but no factory
        bool hasFactory = vm.keyExistsJson(json, ".deployment.token1.factory");
        address deployer = vm.parseJsonAddress(json, ".deployment.token1.deployer");

        assertFalse(hasFactory, "Regular contract should not have factory field");
        assertEq(deployer, address(deployment), "Regular contract deployer should be deployment contract");
    }

    function test_ExistingContractHasNoDeployerNoFactory() public {
        // Register existing contract
        address existing = address(0x1234567890123456789012345678901234567890);
        deployment.useExisting("external1", existing);
        deployment.finish();

        // Use toJson() for verification without saving file
        string memory json = deployment.toJson();

        // Existing contract should have neither factory nor deployer
        bool hasFactory = vm.keyExistsJson(json, ".deployment.external1.factory");
        bool hasDeployer = vm.keyExistsJson(json, ".deployment.external1.deployer");

        assertFalse(hasFactory, "Existing contract should not have factory field");
        assertFalse(hasDeployer, "Existing contract should not have deployer field");
    }

    function test_LibraryHasDeployerNoFactory() public {
        // Deploy library
        deployment.deployTestLibrary("lib1");
        deployment.finish();

        // Use toJson() for verification without saving file
        string memory json = deployment.toJson();

        // Library should have deployer but no factory
        bool hasFactory = vm.keyExistsJson(json, ".deployment.lib1.factory");
        address deployer = vm.parseJsonAddress(json, ".deployment.lib1.deployer");

        assertFalse(hasFactory, "Library should not have factory field");
        assertEq(deployer, address(deployment), "Library deployer should be deployment contract");
    }

    function test_FactoryAndDeployerSameInTestEnvironment() public {
        // Deploy a proxy and verify factory == deployer
        deployment.deploySimpleProxy("proxy1", 100, admin);
        deployment.finish();

        // Use toJson() for verification without saving file
        string memory json = deployment.toJson();

        address factory = vm.parseJsonAddress(json, ".deployment.proxy1.factory");
        address deployer = vm.parseJsonAddress(json, ".deployment.proxy1.deployer");

        // In test environment, both should be the deployment contract
        assertEq(
            factory,
            deployer,
            "In test environment, factory and deployer should be the same (deployment contract)"
        );
    }

    function test_MultipleProxiesHaveSameFactoryAndDeployer() public {
        // Enable auto-save for regression testing of field structure
        deployment.enableAutoSave();

        // Deploy multiple proxies
        deployment.deploySimpleProxy("proxy1", 100, admin);
        deployment.deploySimpleProxy("proxy2", 200, admin);
        deployment.deploySimpleProxy("proxy3", 300, admin);

        deployment.finish();

        // Autosave writes to fields-test-salt.json - read from there
        string memory path = string.concat("results/deployments/", TEST_SALT, ".json");
        string memory json = vm.readFile(path);

        // All should have same factory and deployer
        address factory1 = vm.parseJsonAddress(json, ".deployment.proxy1.factory");
        address deployer1 = vm.parseJsonAddress(json, ".deployment.proxy1.deployer");
        address factory2 = vm.parseJsonAddress(json, ".deployment.proxy2.factory");
        address deployer2 = vm.parseJsonAddress(json, ".deployment.proxy2.deployer");
        address factory3 = vm.parseJsonAddress(json, ".deployment.proxy3.factory");
        address deployer3 = vm.parseJsonAddress(json, ".deployment.proxy3.deployer");

        assertEq(factory1, factory2, "All proxies should have same factory");
        assertEq(factory2, factory3, "All proxies should have same factory");
        assertEq(deployer1, deployer2, "All proxies should have same deployer");
        assertEq(deployer2, deployer3, "All proxies should have same deployer");
        assertEq(factory1, address(deployment), "Factory should be deployment contract");
        assertEq(deployer1, address(deployment), "Deployer should be deployment contract");
    }

    function test_FundedVaultDeployments_WithAndWithoutValue() public {
        // Enable auto-save for regression testing
        deployment.enableAutoSave();

        // Deploy funded vault with value
        bytes memory fundedCode = type(FundedVault).creationCode;
        vm.deal(address(deployment), 10 ether);
        deployment.deployContractWithValue{value: 5 ether}(
            "vault_funded", 5 ether, fundedCode, "FundedVault", "test/mocks/deployment/FundedVault.sol"
        );

        // Deploy unfunded vault (same contract type, zero value)
        deployment.deployContractWithValue("vault_unfunded", 0, fundedCode, "FundedVault", "test/mocks/deployment/FundedVault.sol");

        deployment.finish();

        // Read JSON output
        string memory path = string.concat("results/deployments/", TEST_SALT, ".json");
        string memory json = vm.readFile(path);

        // Verify both vaults have factory field (CREATE3 deployments)
        assertTrue(vm.keyExistsJson(json, ".deployment.vault_funded.factory"), "Funded vault should have factory field");
        assertTrue(vm.keyExistsJson(json, ".deployment.vault_unfunded.factory"), "Unfunded vault should have factory field");

        // Verify factory is BaoDeployer address
        address fundedFactory = vm.parseJsonAddress(json, ".deployment.vault_funded.factory");
        address unfundedFactory = vm.parseJsonAddress(json, ".deployment.vault_unfunded.factory");

        // Factory should be the BaoDeployer (not deployment contract, which is just the executor)
        assertTrue(fundedFactory != address(0), "Funded vault factory should not be zero");
        assertTrue(unfundedFactory != address(0), "Unfunded vault factory should not be zero");
        assertEq(fundedFactory, unfundedFactory, "Both vaults should use same factory (BaoDeployer)");

        // Verify both vaults are deployed and have correct balance
        address fundedVault = vm.parseJsonAddress(json, ".deployment.vault_funded.address");
        address unfundedVault = vm.parseJsonAddress(json, ".deployment.vault_unfunded.address");

        assertEq(fundedVault.balance, 5 ether, "Funded vault should have 5 ETH");
        assertEq(unfundedVault.balance, 0, "Unfunded vault should have 0 ETH");
    }
}
