// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {DeploymentJsonTesting} from "@bao-script/deployment/DeploymentJsonTesting.sol";
import {DeploymentBase} from "@bao-script/deployment/DeploymentBase.sol";
import {DeploymentTesting} from "@bao-script/deployment/DeploymentTesting.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {BaoFactory} from "@bao-factory/BaoFactory.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";
import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {FundedVault, FundedVaultUUPS, NonPayableVault, NonPayableVaultUUPS} from "@bao-test/mocks/deployment/FundedVault.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Simple UUPS proxy implementation using BaoOwnable for transfer-after-deploy pattern
/// BaoOwnable sets owner=msg.sender and pendingOwner=finalOwner during init
/// finish() calls transferOwnership(pendingOwner) to complete the transfer
contract SimpleImplementation is Initializable, UUPSUpgradeable, BaoOwnable {
    uint256 public value;

    function initialize(uint256 _value, address _finalOwner) external initializer {
        _initializeOwner(_finalOwner);
        value = _value;
    }

    function _authorizeUpgrade(address) internal view override onlyOwner {}
}

library TestLib {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        return a + b;
    }
}

// Test harness with helper methods
// Uses production bytecode for BaoFactory so addresses are stable under coverage instrumentation
contract MockDeploymentFields is DeploymentJsonTesting {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    constructor() {
        // Register all possible contract keys used in tests (with contracts. prefix for JSON output)
        addProxy("contracts.oracle1");
        addContract("contracts.token1");
        addProxy("contracts.vault_proxy_funded");
        addPredictableContract("contracts.vault_funded"); // Predictable contract with funding
        addAddressKey("contracts.vault_funded.factory"); // CREATE3 contracts have factory field
        addProxy("contracts.vault_proxy_unfunded");
        addPredictableContract("contracts.vault_unfunded"); // Predictable contract without funding
        addAddressKey("contracts.vault_unfunded.factory"); // CREATE3 contracts have factory field
        addProxy("contracts.proxy1");
        addProxy("contracts.proxy2");
        addProxy("contracts.proxy3");
        addContract("contracts.lib1");
        addContract("contracts.external1");
    }

    /// @dev Use production bytecode for stable addresses (works with coverage instrumentation)
    function _ensureBaoFactory() internal override(DeploymentBase, DeploymentTesting) returns (address baoFactory) {
        baoFactory = DeploymentInfrastructure._ensureBaoFactoryProduction();
        // Always reset operator to this harness
        if (!BaoFactory(baoFactory).isCurrentOperator(address(this))) {
            VM.prank(BaoFactory(baoFactory).owner());
            BaoFactory(baoFactory).setOperator(address(this), 365 days);
        }
    }

    function deployMockERC20(string memory key, string memory name, string memory symbol) public returns (address) {
        MockERC20 token = new MockERC20(name, symbol, 18);
        registerContract(key, address(token), "MockERC20", type(MockERC20).creationCode, address(this));
        return _get(key);
    }

    function deploySimpleProxy(string memory key, uint256 value) public {
        SimpleImplementation impl = new SimpleImplementation();
        // Pass global OWNER as finalOwner - BaoOwnable sets pendingOwner to this
        // owner will be msg.sender (deployment harness), finish() transfers to pendingOwner
        address finalOwner = _getAddress(OWNER);
        bytes memory initData = abi.encodeCall(SimpleImplementation.initialize, (value, finalOwner));
        this.deployProxy(
            key,
            address(impl),
            initData,
            "SimpleImplementation",
            type(SimpleImplementation).creationCode,
            address(this)
        );
    }

    function deployTestLibrary(string memory key) public returns (address) {
        bytes memory libBytecode = type(TestLib).creationCode;
        deployLibrary(key, libBytecode, "TestLib", address(this));
        return _get(key);
    }

    function deployFundedVault(string memory key, uint256 value) public {
        bytes memory fundedCode = type(FundedVault).creationCode;
        this.predictableDeployContract{value: value}(value, key, fundedCode, "FundedVault", fundedCode, address(this));
    }

    function deployFundedVaultProxy(string memory key, uint256 value) public {
        // Use global OWNER for consistency with deployment system - finish() will record this as the owner
        address finalOwner = _getAddress(OWNER);
        FundedVaultUUPS impl = new FundedVaultUUPS(finalOwner);
        bytes memory initData = abi.encodeCall(FundedVaultUUPS.initialize, ());
        // BaoOwnable_v2 uses timeout-based ownership transfer, not explicit transferOwnership
        this.registerImplementation(
            key,
            address(impl),
            "FundedVaultUUPS",
            type(FundedVaultUUPS).creationCode,
            "transferred-on-timeout"
        );
        this.deployProxy{value: value}(
            value,
            key,
            address(impl),
            initData,
            "FundedVaultUUPS",
            type(FundedVaultUUPS).creationCode,
            address(this)
        );
    }

    function deployNonPayableVaultProxy(
        string memory key,
        address owner,
        uint256 value,
        uint256 initializerValue
    ) public {
        NonPayableVaultUUPS impl = new NonPayableVaultUUPS(owner);
        bytes memory initData = abi.encodeCall(NonPayableVaultUUPS.initialize, (initializerValue));
        this.deployProxy{value: value}(
            value,
            key,
            address(impl),
            initData,
            "NonPayableVaultUUPS",
            type(NonPayableVaultUUPS).creationCode,
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
    string constant TEST_SALT = "DeploymentFieldsTest";
    string constant FILE_PREFIX = "DeploymentFieldsTest-";

    function setUp() public override {
        super.setUp();
        deployment = new MockDeploymentFields();
        admin = address(this);
    }

    function _startDeployment(string memory network) internal {
        _initDeploymentTest(TEST_SALT, network);
        deployment.start(network, TEST_SALT, "");
    }

    function test_ProxyHasFactoryAndDeployer() public {
        _startDeployment("test_ProxyHasFactoryAndDeployer");

        // Deploy a proxy
        deployment.deploySimpleProxy("contracts.proxy1", 100);
        deployment.finish();

        // Use toJson() for verification without saving file
        string memory json = deployment.toJson();

        // Verify proxy has both factory and deployer
        address factory = vm.parseJsonAddress(json, ".contracts.proxy1.factory");
        address deployer = vm.parseJsonAddress(json, ".contracts.proxy1.deployer");

        // Get the stored implementation address from deployment data
        address storedImpl = deployment.get("contracts.proxy1.implementation");

        // Factory should be the CREATE3 deployer, deployer should be the harness executor
        assertEq(factory, DeploymentInfrastructure.predictBaoFactoryAddress(), "Proxy factory should be BaoFactory");
        assertEq(deployer, address(deployment), "Proxy deployer should be deployment contract");
        assertTrue(factory != address(0), "Factory should not be zero");
        assertTrue(deployer != address(0), "Deployer should not be zero");
        assertTrue(storedImpl != address(0), "Implementation should not be zero");
    }

    function test_ImplementationHasDeployerNoFactory() public {
        _startDeployment("test_ImplementationHasDeployerNoFactory");

        // Deploy implementation (via proxy deployment which creates implementation entry)
        deployment.deploySimpleProxy("contracts.proxy1", 100);
        deployment.finish();

        // Use toJson() for verification
        string memory json = deployment.toJson();

        string memory implKey = "contracts.proxy1.implementation";

        // Verify implementation entry exists in JSON and has deployer but no factory
        // Implementations are created via new, not CREATE3, so they don't have factory field

        assertFalse(
            vm.keyExistsJson(json, string.concat(".", implKey, ".factory")),
            "Implementation should not have factory field"
        );
        assertTrue(
            vm.keyExistsJson(json, string.concat(".", implKey, ".deployer")),
            "Implementation should have deployer field"
        );

        address deployer = vm.parseJsonAddress(json, string.concat(".", implKey, ".deployer"));
        assertEq(deployer, address(deployment), "Implementation deployer should be deployment contract");
    }

    function test_RegularContractHasDeployerNoFactory() public {
        _startDeployment("test_RegularContractHasDeployerNoFactory");

        // Deploy regular contract
        deployment.deployMockERC20("contracts.token1", "Token1", "TK1");
        deployment.finish();

        // Use toJson() for verification without saving file
        string memory json = deployment.toJson();

        // Regular contract should have deployer but no factory
        bool hasFactory = vm.keyExistsJson(json, ".contracts.token1.factory");
        address deployer = vm.parseJsonAddress(json, ".contracts.token1.deployer");

        assertFalse(hasFactory, "Regular contract should not have factory field");
        assertEq(deployer, address(deployment), "Regular contract deployer should be deployment contract");
    }

    function test_ExistingContractHasNoDeployerNoFactory() public {
        _startDeployment("test_ExistingContractHasNoDeployerNoFactory");

        // Register existing contract
        address existing = address(0x1234567890123456789012345678901234567890);
        deployment.useExisting("contracts.external1", existing);
        deployment.finish();

        // Use toJson() for verification without saving file
        string memory json = deployment.toJson();

        // Existing contract should have neither factory nor deployer
        bool hasFactory = vm.keyExistsJson(json, ".contracts.external1.factory");
        bool hasDeployer = vm.keyExistsJson(json, ".contracts.external1.deployer");

        assertFalse(hasFactory, "Existing contract should not have factory field");
        assertFalse(hasDeployer, "Existing contract should not have deployer field");
    }

    function test_LibraryHasDeployerNoFactory() public {
        _startDeployment("test_LibraryHasDeployerNoFactory");

        // Deploy library
        deployment.deployTestLibrary("contracts.lib1");
        deployment.finish();

        // Use toJson() for verification without saving file
        string memory json = deployment.toJson();

        // Library should have deployer but no factory
        bool hasFactory = vm.keyExistsJson(json, ".contracts.lib1.factory");
        address deployer = vm.parseJsonAddress(json, ".contracts.lib1.deployer");

        assertFalse(hasFactory, "Library should not have factory field");
        assertEq(deployer, address(deployment), "Library deployer should be deployment contract");
    }

    function test_FactoryAndDeployerUseDistinctRoles() public {
        _startDeployment("test_FactoryAndDeployerUseDistinctRoles");

        // Deploy a proxy and verify factory != deployer
        deployment.deploySimpleProxy("contracts.proxy1", 100);
        deployment.finish();

        // Use toJson() for verification without saving file
        string memory json = deployment.toJson();

        address factory = vm.parseJsonAddress(json, ".contracts.proxy1.factory");
        address deployer = vm.parseJsonAddress(json, ".contracts.proxy1.deployer");

        // Factory should be CREATE3 deployer while deployer remains the harness
        assertEq(factory, DeploymentInfrastructure.predictBaoFactoryAddress(), "Factory should be BaoFactory");
        assertEq(deployer, address(deployment), "Deployer should remain the deployment harness");
        assertNotEq(factory, deployer, "Factory and deployer should be distinct roles");
    }

    function test_MultipleProxiesHaveSameFactoryAndDeployer() public {
        _startDeployment("test_MultipleProxiesHaveSameFactoryAndDeployer");

        // Deploy multiple proxies
        deployment.deploySimpleProxy("contracts.proxy1", 100);
        deployment.deploySimpleProxy("contracts.proxy2", 200);
        deployment.deploySimpleProxy("contracts.proxy3", 300);

        deployment.finish();

        // Autosave writes to fields-test-salt.json - read from there
        string memory json = deployment.toJson();

        // All should have same factory and deployer
        address factory1 = vm.parseJsonAddress(json, ".contracts.proxy1.factory");
        address deployer1 = vm.parseJsonAddress(json, ".contracts.proxy1.deployer");
        address factory2 = vm.parseJsonAddress(json, ".contracts.proxy2.factory");
        address deployer2 = vm.parseJsonAddress(json, ".contracts.proxy2.deployer");
        address factory3 = vm.parseJsonAddress(json, ".contracts.proxy3.factory");
        address deployer3 = vm.parseJsonAddress(json, ".contracts.proxy3.deployer");

        assertEq(factory1, factory2, "All proxies should have same factory");
        assertEq(factory2, factory3, "All proxies should have same factory");
        assertEq(deployer1, deployer2, "All proxies should have same deployer");
        assertEq(deployer2, deployer3, "All proxies should have same deployer");
        assertEq(factory1, DeploymentInfrastructure.predictBaoFactoryAddress(), "Factory should be BaoFactory");
        assertEq(deployer1, address(deployment), "Deployer should be deployment contract");
    }

    // TODO: do this with proxy deployment too
    function test_FundedVaultDeployments_WithAndWithoutValue() public {
        _startDeployment("test_FundedVaultDeployments_WithAndWithoutValue");

        // Deploy funded vault with value
        bytes memory fundedCode = type(FundedVault).creationCode;

        vm.deal(address(deployment), 10 ether);
        deployment.predictableDeployContract{value: 5 ether}(
            5 ether,
            "contracts.vault_funded",
            fundedCode,
            "FundedVault",
            fundedCode,
            address(this)
        );

        // TODO: test that a non-payable contract can be deployed with value?
        // Deploy unfunded vault (same contract type, zero value)
        deployment.predictableDeployContract(
            "contracts.vault_unfunded",
            fundedCode,
            "FundedVault",
            fundedCode,
            address(this)
        );

        deployment.finish();

        // Read JSON output
        string memory json = deployment.toJson();

        // Verify both vaults have factory field (CREATE3 deployments)
        assertTrue(vm.keyExistsJson(json, ".contracts.vault_funded.factory"), "Funded vault should have factory field");
        assertTrue(
            vm.keyExistsJson(json, ".contracts.vault_unfunded.factory"),
            "Unfunded vault should have factory field"
        );

        // Verify factory is BaoFactory address
        address fundedFactory = vm.parseJsonAddress(json, ".contracts.vault_funded.factory");
        address unfundedFactory = vm.parseJsonAddress(json, ".contracts.vault_unfunded.factory");

        // Factory should be the BaoFactory (not deployment contract, which is just the executor)
        assertTrue(fundedFactory != address(0), "Funded vault factory should not be zero");
        assertTrue(unfundedFactory != address(0), "Unfunded vault factory should not be zero");
        assertEq(fundedFactory, unfundedFactory, "Both vaults should use same factory (BaoFactory)");
        assertEq(fundedFactory, DeploymentInfrastructure.predictBaoFactoryAddress(), "Factory should be BaoFactory");

        // Verify both vaults are deployed and have correct balance
        address fundedVault = deployment.get("contracts.vault_funded");
        address unfundedVault = deployment.get("contracts.vault_unfunded");

        assertEq(fundedVault.balance, 5 ether, "Funded vault should have 5 ETH");
        assertEq(unfundedVault.balance, 0, "Unfunded vault should have 0 ETH");

        // Verify value field in JSON for funded contracts
        assertTrue(vm.keyExistsJson(json, ".contracts.vault_funded.value"), "Funded vault should have value field");
        uint256 fundedValue = vm.parseJsonUint(json, ".contracts.vault_funded.value");
        assertEq(fundedValue, 5 ether, "Funded vault value should be 5 ETH");

        // Unfunded vault should not have value field (or have zero value)
        if (vm.keyExistsJson(json, ".contracts.vault_unfunded.value")) {
            uint256 unfundedValue = vm.parseJsonUint(json, ".contracts.vault_unfunded.value");
            assertEq(unfundedValue, 0, "Unfunded vault value should be 0");
        }
    }

    function test_FundedVaultProxyDeployments_WithAndWithoutValue() public {
        _startDeployment("test_FundedVaultProxyDeployments_WithAndWithoutValue");

        vm.deal(address(deployment), 10 ether);

        deployment.deployFundedVaultProxy("contracts.vault_proxy_funded", 5 ether);
        deployment.deployFundedVaultProxy("contracts.vault_proxy_unfunded", 0);

        deployment.finish();

        string memory json = deployment.toJson();

        address factoryFunded = vm.parseJsonAddress(json, ".contracts.vault_proxy_funded.factory");
        address factoryUnfunded = vm.parseJsonAddress(json, ".contracts.vault_proxy_unfunded.factory");
        address deployerFunded = vm.parseJsonAddress(json, ".contracts.vault_proxy_funded.deployer");
        address deployerUnfunded = vm.parseJsonAddress(json, ".contracts.vault_proxy_unfunded.deployer");

        address expectedFactory = DeploymentInfrastructure.predictBaoFactoryAddress();
        assertEq(factoryFunded, expectedFactory, "Proxy factory should be BaoFactory");
        assertEq(factoryUnfunded, expectedFactory, "Proxy factory should be BaoFactory");
        assertEq(deployerFunded, address(deployment), "Proxy deployer should be deployment contract");
        assertEq(deployerUnfunded, address(deployment), "Proxy deployer should be deployment contract");

        address recordedFunded = vm.parseJsonAddress(json, ".contracts.vault_proxy_funded.address");
        address recordedUnfunded = vm.parseJsonAddress(json, ".contracts.vault_proxy_unfunded.address");

        assertEq(
            recordedFunded,
            deployment.get("contracts.vault_proxy_funded"),
            "Recorded funded proxy address mismatch"
        );
        assertEq(
            recordedUnfunded,
            deployment.get("contracts.vault_proxy_unfunded"),
            "Recorded unfunded proxy address mismatch"
        );

        assertEq(recordedFunded.balance, 5 ether, "Funded proxy should hold 5 ETH");
        assertEq(recordedUnfunded.balance, 0, "Unfunded proxy should hold 0 ETH");

        assertEq(FundedVaultUUPS(recordedFunded).initialBalance(), 5 ether, "Initializer should record funded balance");
        assertEq(FundedVaultUUPS(recordedUnfunded).initialBalance(), 0, "Initializer should record zero balance");

        // Verify owner field is set to global OWNER (not deployer) for timeout proxies after finish()
        address ownerFunded = vm.parseJsonAddress(json, ".contracts.vault_proxy_funded.owner");
        address ownerUnfunded = vm.parseJsonAddress(json, ".contracts.vault_proxy_unfunded.owner");
        assertEq(ownerFunded, DEFAULT_TEST_OWNER, "Funded proxy owner should be global OWNER after finish");
        assertEq(ownerUnfunded, DEFAULT_TEST_OWNER, "Unfunded proxy owner should be global OWNER after finish");
    }

    function test_RevertWhen_FundingNonPayableContract() public {
        _startDeployment("test_RevertWhen_FundingNonPayableContract");

        vm.deal(address(deployment), 1 ether);

        bytes memory nonPayableCode = abi.encodePacked(type(NonPayableVault).creationCode, abi.encode(uint256(123)));

        vm.expectRevert();
        deployment.predictableDeployContract{value: 1 ether}(
            1 ether,
            "contracts.vault_nonpayable",
            nonPayableCode,
            "NonPayableVault",
            nonPayableCode,
            address(this)
        );
    }

    function test_RevertWhen_UnderfundingPredictableDeploy() public {
        _startDeployment("test_RevertWhen_UnderfundingPredictableDeploy");

        bytes memory fundedCode = type(FundedVault).creationCode;

        vm.deal(address(deployment), 0);

        vm.expectRevert(abi.encodeWithSelector(IBaoFactory.ValueMismatch.selector, 1 ether, 0));
        deployment.simulatePredictableDeployWithoutFunding(
            1 ether,
            "vault_underfunded",
            fundedCode,
            "FundedVault",
            "test/mocks/deployment/FundedVault.sol"
        );
    }

    function test_RevertWhen_PredictableDeployKeyMissing() public {
        _startDeployment("test_RevertWhen_PredictableDeployKeyMissing");

        bytes memory fundedCode = type(FundedVault).creationCode;

        vm.expectRevert(DeploymentBase.KeyRequired.selector);
        deployment.simulatePredictableDeployWithoutFunding(
            0,
            "",
            fundedCode,
            "FundedVault",
            "test/mocks/deployment/FundedVault.sol"
        );
    }

    function test_RevertWhen_PredictableDeployKeyAlreadyUsed() public {
        _startDeployment("test_RevertWhen_PredictableDeployKeyAlreadyUsed");

        deployment.setAddress("contracts.vault_unfunded.address", address(0xABCD));

        bytes memory fundedCode = type(FundedVault).creationCode;

        vm.expectRevert();
        deployment.simulatePredictableDeployWithoutFunding(
            0,
            "contracts.vault_unfunded",
            fundedCode,
            "FundedVault",
            "test/mocks/deployment/FundedVault.sol"
        );
    }

    function test_RevertWhen_FundingNonPayableProxy() public {
        _startDeployment("test_RevertWhen_FundingNonPayableProxy");

        vm.deal(address(deployment), 1 ether);

        vm.expectRevert();
        deployment.deployNonPayableVaultProxy("contracts.vault_nonpayable_proxy", admin, 1 ether, uint256(123));
    }

    function test_RevertWhen_UnderfundingProxyDeployment() public {
        _startDeployment("test_RevertWhen_UnderfundingProxyDeployment");

        FundedVaultUUPS impl = new FundedVaultUUPS(admin);
        bytes memory initData = abi.encodeCall(FundedVaultUUPS.initialize, ());

        vm.expectRevert(abi.encodeWithSelector(DeploymentBase.ValueMismatch.selector, 5 ether, 0));
        deployment.deployProxy{value: 0}(
            5 ether,
            "vault_proxy_underfunded",
            address(impl),
            initData,
            "FundedVaultUUPS",
            type(FundedVaultUUPS).creationCode,
            address(this)
        );
    }
}
