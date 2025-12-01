// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {DeploymentJsonTesting} from "@bao-script/deployment/DeploymentJsonTesting.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

contract SimpleBaoOwnable is IBaoOwnable {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function transferOwnership(address newOwner) external override {
        require(msg.sender == owner, "only owner");
        owner = newOwner;
    }
}

contract DeployableLibrary {
    function ping() external pure returns (bytes32) {
        return keccak256("deployable");
    }
}

contract FailingLibrary {
    constructor() {
        revert("failing library");
    }
}

contract DeploymentCoreHarness is DeploymentJsonTesting {
    function startSession(string memory network, string memory salt) external {
        start(network, salt, "");
    }

    function setConfiguredOwner(address owner_) external {
        _setAddress(OWNER, owner_);
    }

    function transferProxyOwnership(address proxy) external {
        _transferProxyOwnership(proxy);
    }

    function ensureBaoDeployerExternal() external {
        ensureBaoDeployer();
    }

    function hasKey(string memory key) external view returns (bool) {
        return _has(key);
    }

    function readStoredAddress(string memory key) external view returns (address) {
        return _get(key);
    }

    function readAddressField(string memory key) external view returns (address) {
        return _getAddress(key);
    }

    function readStringValue(string memory key) external view returns (string memory) {
        return _getString(key);
    }

    function setUintValue(string memory key, uint256 value) external {
        _setUint(key, value);
    }

    function readUintValue(string memory key) external view returns (uint256) {
        return _getUint(key);
    }

    function setIntValue(string memory key, int256 value) external {
        _setInt(key, value);
    }

    function readIntValue(string memory key) external view returns (int256) {
        return _getInt(key);
    }

    function setBoolValue(string memory key, bool value) external {
        _setBool(key, value);
    }

    function readBoolValue(string memory key) external view returns (bool) {
        return _getBool(key);
    }

    function setAddressArrayValue(string memory key, address[] memory value) external {
        _setAddressArray(key, value);
    }

    function readAddressArrayValue(string memory key) external view returns (address[] memory) {
        return _getAddressArray(key);
    }

    function setStringArrayValue(string memory key, string[] memory value) external {
        _setStringArray(key, value);
    }

    function readStringArrayValue(string memory key) external view returns (string[] memory) {
        return _getStringArray(key);
    }

    function setUintArrayValue(string memory key, uint256[] memory value) external {
        _setUintArray(key, value);
    }

    function readUintArrayValue(string memory key) external view returns (uint256[] memory) {
        return _getUintArray(key);
    }

    function setIntArrayValue(string memory key, int256[] memory value) external {
        _setIntArray(key, value);
    }

    function readIntArrayValue(string memory key) external view returns (int256[] memory) {
        return _getIntArray(key);
    }

    function registerUintKey(string memory key) external {
        addUintKey(key);
    }

    function registerIntKey(string memory key) external {
        addIntKey(key);
    }

    function registerBoolKey(string memory key) external {
        addBoolKey(key);
    }

    function registerAddressArrayKey(string memory key) external {
        addAddressArrayKey(key);
    }

    function registerStringArrayKey(string memory key) external {
        addStringArrayKey(key);
    }

    function registerUintArrayKey(string memory key) external {
        addUintArrayKey(key);
    }

    function registerIntArrayKey(string memory key) external {
        addIntArrayKey(key);
    }

    function registerTopLevelKey(string memory key) external {
        addKey(key);
    }

    function registerAddressKey(string memory key) external {
        addAddressKey(key);
    }
}

contract DeploymentCoreTest is BaoDeploymentTest {
    DeploymentCoreHarness public deployment;

    function setUp() public override {
        super.setUp();
        deployment = new DeploymentCoreHarness();
    }

    function test_TransferProxyOwnershipSkipsWhenNotHarnessOwner_() public {
        _initSession("saltB");
        deployment.setConfiguredOwner(address(0xBAD));
        SimpleBaoOwnable proxy = new SimpleBaoOwnable(address(0x1111));
        deployment.transferProxyOwnership(address(proxy));
        assertEq(proxy.owner(), address(0x1111), "Proxy ownership unchanged when harness not owner");
    }

    function test_TransferProxyOwnershipUpdatesWhenHarnessOwnsProxy_() public {
        _initSession("saltC");
        address finalOwner = address(0xBEEF);
        deployment.setConfiguredOwner(finalOwner);
        SimpleBaoOwnable proxy = new SimpleBaoOwnable(address(deployment));
        deployment.transferProxyOwnership(address(proxy));
        assertEq(proxy.owner(), finalOwner, "Proxy ownership transferred to configured owner");
    }

    function test_RegisterContractRecordsMetadata_() public {
        _initSession("saltD");
        deployment.addContract("contracts.alpha");
        address deployerAddress = address(0xD1);
        deployment.registerContract("contracts.alpha", address(0xCAFE), "Alpha", "src/Alpha.sol", deployerAddress);
        assertEq(deployment.readStoredAddress("contracts.alpha"), address(0xCAFE), "Contract address stored for alpha");
        assertEq(
            deployment.readStringValue("contracts.alpha.category"),
            "contract",
            "Contract category annotated for alpha"
        );
        assertEq(
            deployment.readAddressField("contracts.alpha.deployer"),
            deployerAddress,
            "Contract deployer recorded for alpha"
        );
    }

    function test_DeployLibrarySuccessRecordsMetadata_() public {
        _initSession("saltE");
        deployment.addContract("contracts.safeLibrary");
        bytes memory bytecode = type(DeployableLibrary).creationCode;
        deployment.deployLibrary(
            "contracts.safeLibrary",
            bytecode,
            "SimpleBaoOwnable",
            "test/SimpleBaoOwnable.sol",
            address(this)
        );
        assertTrue(
            deployment.readStoredAddress("contracts.safeLibrary") != address(0),
            "Library address stored for safe"
        );
        assertEq(
            deployment.readStringValue("contracts.safeLibrary.category"),
            "library",
            "Library category set for safe"
        );
    }

    function test_RevertWhen_DeployLibraryFails_() public {
        _initSession("saltF");
        deployment.addContract("contracts.failLibrary");
        vm.expectRevert(abi.encodeWithSelector(Deployment.LibraryDeploymentFailed.selector, "contracts.failLibrary"));
        deployment.deployLibrary(
            "contracts.failLibrary",
            type(FailingLibrary).creationCode,
            "Broken",
            "test/Broken.sol",
            address(this)
        );
    }

    function test_InternalScalarAccessorsRoundTrip_() public {
        _initSession("saltG");
        deployment.addContract("contracts.metrics");
        deployment.registerUintKey("contracts.metrics.count");
        deployment.registerIntKey("contracts.metrics.delta");
        deployment.registerBoolKey("contracts.metrics.enabled");
        deployment.setUintValue("contracts.metrics.count", 42);
        deployment.setIntValue("contracts.metrics.delta", -5);
        deployment.setBoolValue("contracts.metrics.enabled", true);
        assertEq(deployment.readUintValue("contracts.metrics.count"), 42, "Uint getter returns stored value");
        assertEq(deployment.readIntValue("contracts.metrics.delta"), -5, "Int getter returns stored value");
        assertTrue(deployment.readBoolValue("contracts.metrics.enabled"), "Bool getter returns stored value");
    }

    function test_InternalArrayAccessorsRoundTrip_() public {
        _initSession("saltH");
        deployment.addContract("contracts.lists");
        deployment.registerAddressArrayKey("contracts.lists.addresses");
        deployment.registerStringArrayKey("contracts.lists.names");
        deployment.registerUintArrayKey("contracts.lists.amounts");
        deployment.registerIntArrayKey("contracts.lists.deltas");
        address[] memory addresses = new address[](2);
        addresses[0] = address(0xAA);
        addresses[1] = address(0xBB);
        string[] memory names = new string[](2);
        names[0] = "foo";
        names[1] = "bar";
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1;
        amounts[1] = 2;
        int256[] memory deltas = new int256[](2);
        deltas[0] = -1;
        deltas[1] = 3;
        deployment.setAddressArrayValue("contracts.lists.addresses", addresses);
        deployment.setStringArrayValue("contracts.lists.names", names);
        deployment.setUintArrayValue("contracts.lists.amounts", amounts);
        deployment.setIntArrayValue("contracts.lists.deltas", deltas);
        address[] memory storedAddresses = deployment.readAddressArrayValue("contracts.lists.addresses");
        string[] memory storedNames = deployment.readStringArrayValue("contracts.lists.names");
        uint256[] memory storedAmounts = deployment.readUintArrayValue("contracts.lists.amounts");
        int256[] memory storedDeltas = deployment.readIntArrayValue("contracts.lists.deltas");
        assertEq(storedAddresses[1], address(0xBB), "Address array preserves second element");
        assertEq(storedNames[0], "foo", "String array preserves first element");
        assertEq(storedAmounts[1], 2, "Uint array preserves values");
        assertEq(storedDeltas[0], -1, "Int array preserves negatives");
    }

    function test_PredictProxyAddressRequiresKey_() public {
        _initSession("saltI");
        vm.expectRevert(Deployment.KeyRequired.selector);
        deployment.predictProxyAddress("");
    }

    function test_UpgradeProxyValueRequiresKey_() public {
        _initSession("saltJ");
        vm.expectRevert(Deployment.KeyRequired.selector);
        deployment.upgradeProxy{value: 0}(0, "", address(0), bytes(""), "Mock", "test/Mock.sol", address(this));
    }

    function _initSession(string memory salt) internal {
        _resetDeploymentLogs(salt, "");
        _prepareTestNetwork(salt, string.concat("net-", salt));
        deployment.startSession(string.concat("net-", salt), salt);
    }
}

contract DeploymentEnsureBaoDeployerTest is BaoDeploymentTest {
    DeploymentCoreHarness public deployment;

    function setUp() public override {
        // Install Nick's factory but skip DeploymentInfrastructure.ensureBaoDeployer to simulate missing deployer
        if (DeploymentInfrastructure._NICKS_FACTORY.code.length == 0) {
            vm.etch(DeploymentInfrastructure._NICKS_FACTORY, DeploymentInfrastructure._NICKS_FACTORY_BYTECODE);
        }
        vm.label(DeploymentInfrastructure._NICKS_FACTORY, "Nick's factory");
        _baoMultisig = DeploymentInfrastructure.BAOMULTISIG;
        vm.label(_baoMultisig, "_baoMultisig");
        deployment = new DeploymentCoreHarness();
    }

    function test_EnsureBaoDeployerWithoutSession_() public {
        deployment.registerTopLevelKey("BaoDeployer");
        deployment.ensureBaoDeployerExternal();
        assertFalse(deployment.hasKey("BaoDeployer"), "BaoDeployer stays unset off-session");
    }

    function test_EnsureBaoDeployerRequiresSchemaDuringSession_() public {
        _initSessionEnsure("saltEnsure");
        deployment.registerTopLevelKey("BaoDeployer");
        vm.expectRevert(abi.encodeWithSignature("KeyNotRegistered(string)", "BaoDeployer.address"));
        deployment.ensureBaoDeployerExternal();
    }

    function _initSessionEnsure(string memory salt) internal {
        _resetDeploymentLogs(salt, "");
        _prepareTestNetwork(salt, string.concat("net-", salt));
        deployment.startSession(string.concat("net-", salt), salt);
    }
}
