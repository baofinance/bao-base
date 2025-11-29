// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {DeploymentJsonTesting} from "@bao-script/deployment/DeploymentJsonTesting.sol";
import {Deployment, IUUPSUpgradeableProxy} from "@bao-script/deployment/Deployment.sol";
import {BaoDeployer} from "@bao-script/deployment/BaoDeployer.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {FundedVault, FundedVaultUUPS, NonPayableVault, NonPayableVaultUUPS} from "@bao-test/mocks/deployment/FundedVault.sol";

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
contract MockDeploymentFields is DeploymentJsonTesting {
    function deployMockERC20(string memory key, string memory name, string memory symbol) public returns (address) {
        MockERC20 token = new MockERC20(name, symbol, 18);
        registerContract(key, address(token), "MockERC20", "test/mocks/tokens/MockERC20.sol", address(this));
        return get(key);
    }

    function deploySimpleProxy(string memory key, uint256 value, address admin) public returns (address) {
        SimpleImplementation impl = new SimpleImplementation();

        bytes memory initData = abi.encodeCall(SimpleImplementation.initialize, (value, admin));
        address proxy = this.deployProxy(
            key,
            address(impl),
            initData,
            "SimpleImplementation",
            "test/SimpleImplementation.sol",
            address(this)
        );
        return proxy;
    }

    function deployTestLibrary(string memory key) public returns (address) {
        bytes memory libBytecode = type(TestLib).creationCode;
        deployLibrary(key, libBytecode, "TestLib", "test/TestLib.sol", address(this));
        return get(key);
    }

    function deployFundedVault(string memory key, uint256 value) public returns (address) {
        bytes memory fundedCode = type(FundedVault).creationCode;
        return
            this.predictableDeployContract{value: value}(
                value,
                key,
                fundedCode,
                "FundedVault",
                "test/mocks/deployment/FundedVault.sol",
                address(this)
            );
    }

    function deployFundedVaultProxy(string memory key, address owner, uint256 value) public returns (address) {
        FundedVaultUUPS impl = new FundedVaultUUPS(owner);
        bytes memory initData = abi.encodeCall(FundedVaultUUPS.initialize, ());
        return
            this.deployProxy{value: value}(
                value,
                key,
                address(impl),
                initData,
                "FundedVaultUUPS",
                "test/mocks/deployment/FundedVault.sol",
                address(this)
            );
    }

    function deployNonPayableVaultProxy(
        string memory key,
        address owner,
        uint256 value,
        uint256 initializerValue
    ) public returns (address) {
        NonPayableVaultUUPS impl = new NonPayableVaultUUPS(owner);
        bytes memory initData = abi.encodeCall(NonPayableVaultUUPS.initialize, (initializerValue));
        return
            this.deployProxy{value: value}(
                value,
                key,
                address(impl),
                initData,
                "NonPayableVaultUUPS",
                "test/mocks/deployment/FundedVault.sol",
                address(this)
            );
    }
}

/**
 * @title DeploymentFieldsTest
 * @notice Tests that factory and deployer fields are correctly set for different entry types
 */
contract DeploymentFieldsTest is BaoDeploymentTest {
    MockDeploymentFields public deployment;
    address public admin;
    string constant TEST_NETWORK = "test-network";
    string constant TEST_SALT = "fields-test-salt";
    string constant FILE_PREFIX = "DeploymentFieldsTest-";

    function setUp() public override {
        super.setUp();
        deployment = new MockDeploymentFields();
        admin = address(this);
        _resetDeploymentLogs(TEST_SALT, TEST_NETWORK, "{}");
        deployment.start(TEST_NETWORK, TEST_SALT, "");
    }

    function test_ProxyHasFactoryAndDeployer() public {
        deployment.setFilename("test_ProxyHasFactoryAndDeployer");
        // Deploy a proxy
        deployment.deploySimpleProxy("proxy1", 100, admin);
        deployment.finish();

        // Use toJson() for verification without saving file
        string memory json = deployment.toJson();

        // Verify proxy has both factory and deployer
        address factory = vm.parseJsonAddress(json, ".deployment.proxy1.factory");
        address deployer = vm.parseJsonAddress(json, ".deployment.proxy1.deployer");

        // Get implementation address directly from proxy and verify it matches stored key
        address proxyAddr = deployment.get("proxy1");
        address implementation = IUUPSUpgradeableProxy(proxyAddr).implementation();

        // Get the implementation key from proxy metadata
        address storedImpl = deployment.get("contracts.proxy1.implementation");

        // Factory should be the CREATE3 deployer, deployer should be the harness executor
        assertEq(factory, DeploymentInfrastructure.predictBaoDeployerAddress(), "Proxy factory should be BaoDeployer");
        assertEq(deployer, address(deployment), "Proxy deployer should be deployment contract");
        assertTrue(factory != address(0), "Factory should not be zero");
        assertTrue(deployer != address(0), "Deployer should not be zero");
        assertEq(implementation, storedImpl, "Implementation from proxy should match stored implementation");
        assertTrue(implementation != address(0), "Implementation should not be zero");
    }

    function test_ImplementationHasDeployerNoFactory() public {
        // Deploy implementation (via proxy deployment which creates implementation entry)
        deployment.deploySimpleProxy("proxy1", 100, admin);
        deployment.finish();

        // Use toJson() for verification
        string memory json = deployment.toJson();

        // Get the implementation key - it should be registered as proxy1__SimpleImplementation
        string memory proxyKey = "contracts.proxy1";
        string memory implKey = "contracts.proxy1.implementation";

        // Verify implementation entry exists in JSON and has deployer but no factory
        // Implementations are created via new, not CREATE3, so they don't have factory field

        assertFalse(vm.keyExistsJson(json, string.concat(proxyKey, ".factory")), "proxy should not have factory field");
        assertFalse(
            vm.keyExistsJson(json, string.concat(proxyKey, ".deployer")),
            "proxy should not have deployer field"
        );
        assertTrue(
            vm.keyExistsJson(json, string.concat(implKey, ".deployer")),
            "Implementation should have deployer field"
        );

        address deployer = vm.parseJsonAddress(json, string.concat(".deployment.", implKey, ".deployer"));
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

    function test_FactoryAndDeployerUseDistinctRoles() public {
        // Deploy a proxy and verify factory != deployer
        deployment.deploySimpleProxy("proxy1", 100, admin);
        deployment.finish();

        // Use toJson() for verification without saving file
        string memory json = deployment.toJson();

        address factory = vm.parseJsonAddress(json, ".deployment.proxy1.factory");
        address deployer = vm.parseJsonAddress(json, ".deployment.proxy1.deployer");

        // Factory should be CREATE3 deployer while deployer remains the harness
        assertEq(factory, DeploymentInfrastructure.predictBaoDeployerAddress(), "Factory should be BaoDeployer");
        assertEq(deployer, address(deployment), "Deployer should remain the deployment harness");
        assertNotEq(factory, deployer, "Factory and deployer should be distinct roles");
    }

    function test_MultipleProxiesHaveSameFactoryAndDeployer() public {
        // Deploy multiple proxies
        deployment.deploySimpleProxy("proxy1", 100, admin);
        deployment.deploySimpleProxy("proxy2", 200, admin);
        deployment.deploySimpleProxy("proxy3", 300, admin);

        deployment.finish();

        // Autosave writes to fields-test-salt.json - read from there
        string memory json = deployment.toJson();

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
        assertEq(factory1, DeploymentInfrastructure.predictBaoDeployerAddress(), "Factory should be BaoDeployer");
        assertEq(deployer1, address(deployment), "Deployer should be deployment contract");
    }

    // TODO: do this with proxy deployment too
    function test_FundedVaultDeployments_WithAndWithoutValue() public {
        // Deploy funded vault with value
        bytes memory fundedCode = type(FundedVault).creationCode;

        vm.deal(address(deployment), 10 ether);
        deployment.predictableDeployContract{value: 5 ether}(
            5 ether,
            "vault_funded",
            fundedCode,
            "FundedVault",
            "test/mocks/deployment/FundedVault.sol",
            address(this)
        );

        // TODO: test that a non-payable contract can be deployed with value?
        // Deploy unfunded vault (same contract type, zero value)
        deployment.predictableDeployContract(
            "vault_unfunded",
            fundedCode,
            "FundedVault",
            "test/mocks/deployment/FundedVault.sol",
            address(this)
        );

        deployment.finish();

        // Read JSON output
        string memory json = deployment.toJson();

        // Verify both vaults have factory field (CREATE3 deployments)
        assertTrue(
            vm.keyExistsJson(json, ".deployment.vault_funded.factory"),
            "Funded vault should have factory field"
        );
        assertTrue(
            vm.keyExistsJson(json, ".deployment.vault_unfunded.factory"),
            "Unfunded vault should have factory field"
        );

        // Verify factory is BaoDeployer address
        address fundedFactory = vm.parseJsonAddress(json, ".deployment.vault_funded.factory");
        address unfundedFactory = vm.parseJsonAddress(json, ".deployment.vault_unfunded.factory");

        // Factory should be the BaoDeployer (not deployment contract, which is just the executor)
        assertTrue(fundedFactory != address(0), "Funded vault factory should not be zero");
        assertTrue(unfundedFactory != address(0), "Unfunded vault factory should not be zero");
        assertEq(fundedFactory, unfundedFactory, "Both vaults should use same factory (BaoDeployer)");
        assertEq(fundedFactory, DeploymentInfrastructure.predictBaoDeployerAddress(), "Factory should be BaoDeployer");

        // Verify both vaults are deployed and have correct balance
        address fundedVault = vm.parseJsonAddress(json, ".deployment.vault_funded.address");
        address unfundedVault = vm.parseJsonAddress(json, ".deployment.vault_unfunded.address");

        assertEq(fundedVault.balance, 5 ether, "Funded vault should have 5 ETH");
        assertEq(unfundedVault.balance, 0, "Unfunded vault should have 0 ETH");
    }

    function test_FundedVaultProxyDeployments_WithAndWithoutValue() public {
        vm.deal(address(deployment), 10 ether);

        address fundedProxy = deployment.deployFundedVaultProxy("vault_proxy_funded", admin, 5 ether);
        address unfundedProxy = deployment.deployFundedVaultProxy("vault_proxy_unfunded", admin, 0);

        deployment.finish();

        string memory json = deployment.toJson();

        address factoryFunded = vm.parseJsonAddress(json, ".deployment.vault_proxy_funded.factory");
        address factoryUnfunded = vm.parseJsonAddress(json, ".deployment.vault_proxy_unfunded.factory");
        address deployerFunded = vm.parseJsonAddress(json, ".deployment.vault_proxy_funded.deployer");
        address deployerUnfunded = vm.parseJsonAddress(json, ".deployment.vault_proxy_unfunded.deployer");

        address expectedFactory = DeploymentInfrastructure.predictBaoDeployerAddress();
        assertEq(factoryFunded, expectedFactory, "Proxy factory should be BaoDeployer");
        assertEq(factoryUnfunded, expectedFactory, "Proxy factory should be BaoDeployer");
        assertEq(deployerFunded, address(deployment), "Proxy deployer should be deployment contract");
        assertEq(deployerUnfunded, address(deployment), "Proxy deployer should be deployment contract");

        address recordedFunded = vm.parseJsonAddress(json, ".deployment.vault_proxy_funded.address");
        address recordedUnfunded = vm.parseJsonAddress(json, ".deployment.vault_proxy_unfunded.address");

        assertEq(recordedFunded, fundedProxy, "Recorded funded proxy address mismatch");
        assertEq(recordedUnfunded, unfundedProxy, "Recorded unfunded proxy address mismatch");

        assertEq(recordedFunded.balance, 5 ether, "Funded proxy should hold 5 ETH");
        assertEq(recordedUnfunded.balance, 0, "Unfunded proxy should hold 0 ETH");

        assertEq(FundedVaultUUPS(recordedFunded).initialBalance(), 5 ether, "Initializer should record funded balance");
        assertEq(FundedVaultUUPS(recordedUnfunded).initialBalance(), 0, "Initializer should record zero balance");
    }

    function test_RevertWhen_FundingNonPayableContract() public {
        vm.deal(address(deployment), 1 ether);

        bytes memory nonPayableCode = abi.encodePacked(type(NonPayableVault).creationCode, abi.encode(uint256(123)));

        vm.expectRevert();
        deployment.predictableDeployContract(
            1 ether,
            "vault_nonpayable",
            nonPayableCode,
            "NonPayableVault",
            "test/mocks/deployment/FundedVault.sol",
            address(this)
        );
    }

    function test_RevertWhen_UnderfundingPredictableDeploy() public {
        bytes memory fundedCode = type(FundedVault).creationCode;

        vm.deal(address(deployment), 0);

        vm.expectRevert(abi.encodeWithSelector(BaoDeployer.ValueMismatch.selector, 1 ether, 0));
        deployment.simulatePredictableDeployWithoutFunding(
            1 ether,
            "vault_underfunded",
            fundedCode,
            "FundedVault",
            "test/mocks/deployment/FundedVault.sol"
        );
    }

    function test_RevertWhen_FundingNonPayableProxy() public {
        vm.deal(address(deployment), 1 ether);

        vm.expectRevert();
        deployment.deployNonPayableVaultProxy("vault_nonpayable_proxy", admin, 1 ether, uint256(123));
    }

    function test_RevertWhen_UnderfundingProxyDeployment() public {
        FundedVaultUUPS impl = new FundedVaultUUPS(admin);
        bytes memory initData = abi.encodeCall(FundedVaultUUPS.initialize, ());

        vm.expectRevert(abi.encodeWithSelector(Deployment.ValueMismatch.selector, 5 ether, 0));
        deployment.deployProxy{value: 0}(
            5 ether,
            "vault_proxy_underfunded",
            address(impl),
            initData,
            "FundedVaultUUPS",
            "test/mocks/deployment/FundedVault.sol",
            address(this)
        );
    }
}
