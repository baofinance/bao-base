// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {FactoryDeployer} from "@bao-script/deployment/FactoryDeployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {UUPSProxyDeployStub} from "@bao-script/deployment/UUPSProxyDeployStub.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";

// Import needed for proxy deployment
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Simple UUPS-upgradeable contract for testing deployments.
contract MockUpgradeable is Initializable, UUPSUpgradeable, BaoOwnable {
    uint256 public value;

    function initialize(uint256 value_, address deployerOwner, address pendingOwner) external initializer {
        value = value_;
        _initializeOwner(deployerOwner, pendingOwner);
    }

    function _authorizeUpgrade(address) internal view override onlyOwner {}
}

/// @notice Test harness exposing FactoryDeployer internals.
contract TestableFactoryDeployer is FactoryDeployer {
    address private _treasuryAddr;
    address private _ownerAddr;
    address private _factoryAddr;

    constructor(address treasury_, address owner_, address factory_) {
        _treasuryAddr = treasury_;
        _ownerAddr = owner_;
        _factoryAddr = factory_;
    }

    function treasury() public view override returns (address) {
        return _treasuryAddr;
    }

    function owner() public view override returns (address) {
        return _ownerAddr;
    }

    function baoFactory() public view override returns (address) {
        return _factoryAddr;
    }

    // Expose internal functions for testing

    function setSaltPrefix(string memory prefix) external {
        _setSaltPrefix(prefix);
    }

    function getOrDeployStub() external returns (UUPSProxyDeployStub) {
        return _getOrDeployStub();
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

    function saltString1(string memory part1) external view returns (string memory) {
        return _saltString(part1);
    }

    function saltString2(string memory part1, string memory part2) external view returns (string memory) {
        return _saltString(part1, part2);
    }

    function saltString3(
        string memory part1,
        string memory part2,
        string memory part3
    ) external view returns (string memory) {
        return _saltString(part1, part2, part3);
    }

    function predictAddress1(string memory part1) external view returns (address) {
        return _predictAddress(part1);
    }

    function predictAddress2(string memory part1, string memory part2) external view returns (address) {
        return _predictAddress(part1, part2);
    }

    function predictAddress3(
        string memory part1,
        string memory part2,
        string memory part3
    ) external view returns (address) {
        return _predictAddress(part1, part2, part3);
    }

    function deployProxyAndRecordExposed(
        DeploymentTypes.State memory stateData,
        string memory proxyId,
        address implementation,
        string memory contractSource,
        string memory contractType,
        bytes memory initData
    ) external returns (address proxy) {
        return _deployProxyAndRecord(stateData, proxyId, implementation, contractSource, contractType, initData);
    }
}

contract FactoryDeployerTest is BaoTest {
    TestableFactoryDeployer internal deployer;
    address internal testTreasury;
    address internal testOwner;
    address internal baoFactoryAddr;

    function setUp() public {
        testTreasury = makeAddr("treasury");
        testOwner = makeAddr("owner");
        baoFactoryAddr = _ensureBaoFactory();
        deployer = new TestableFactoryDeployer(testTreasury, testOwner, baoFactoryAddr);
        deployer.setSaltPrefix("test_v1");
    }

    // ========== SALT STRING TESTS ==========

    function test_saltString_onePart() public view {
        string memory result = deployer.saltString1("pegged");
        assertEq(result, "test_v1::pegged", "single-part salt");
    }

    function test_saltString_twoParts() public view {
        string memory result = deployer.saltString2("ETH", "fxUSD");
        assertEq(result, "test_v1::ETH::fxUSD", "two-part salt");
    }

    function test_saltString_threeParts() public view {
        string memory result = deployer.saltString3("ETH", "fxUSD", "minter");
        assertEq(result, "test_v1::ETH::fxUSD::minter", "three-part salt");
    }

    function test_saltString_emptyPrefixStillWorks() public {
        deployer.setSaltPrefix("");
        string memory result = deployer.saltString1("test");
        assertEq(result, "::test", "empty prefix produces leading ::");
    }

    // ========== ADDRESS PREDICTION TESTS ==========

    function test_predictAddress_deterministic() public view {
        address addr1 = deployer.predictAddress1("token");
        address addr2 = deployer.predictAddress1("token");
        assertEq(addr1, addr2, "same key produces same address");
    }

    function test_predictAddress_differentKeysProduceDifferentAddresses() public view {
        address addr1 = deployer.predictAddress1("token1");
        address addr2 = deployer.predictAddress1("token2");
        assertTrue(addr1 != addr2, "different keys produce different addresses");
    }

    function test_predictAddress_matchesBaoFactoryPrediction() public view {
        string memory salt = "test_v1::myContract";
        bytes32 saltHash = keccak256(abi.encodePacked(salt));
        address expected = IBaoFactory(baoFactoryAddr).predictAddress(saltHash);
        address actual = deployer.predictAddress1("myContract");
        assertEq(actual, expected, "matches BaoFactory prediction");
    }

    // ========== ADDRESS LABEL TESTS ==========

    function test_addressLabel_returnsLabelForKnownAddress() public view {
        string memory label = deployer.addressLabel(testTreasury);
        assertEq(label, "treasury", "treasury address gets label");
    }

    function test_addressLabel_returnsHexForUnknownAddress() public {
        address unknown = makeAddr("unknown");
        string memory label = deployer.addressLabel(unknown);
        // Should be hex string starting with 0x
        bytes memory labelBytes = bytes(label);
        assertEq(labelBytes[0], "0", "starts with 0");
        assertEq(labelBytes[1], "x", "has x after 0");
    }

    // ========== STUB DEPLOYMENT TESTS ==========

    function test_getOrDeployStub_deploysOnFirstCall() public {
        UUPSProxyDeployStub stub = deployer.getOrDeployStub();
        assertTrue(address(stub) != address(0), "stub deployed");
        assertEq(stub.owner(), address(deployer), "deployer owns stub");
    }

    function test_getOrDeployStub_returnsSameOnSubsequentCalls() public {
        UUPSProxyDeployStub stub1 = deployer.getOrDeployStub();
        UUPSProxyDeployStub stub2 = deployer.getOrDeployStub();
        assertEq(address(stub1), address(stub2), "same stub returned");
    }

    // ========== OWNERSHIP TRANSFER TRACKING TESTS ==========

    function test_registerForOwnershipTransfer_incrementsCount() public {
        assertEq(deployer.pendingOwnershipCount(), 0, "starts at zero");

        deployer.registerForOwnershipTransfer(makeAddr("contract1"), "salt1");
        assertEq(deployer.pendingOwnershipCount(), 1, "one registered");

        deployer.registerForOwnershipTransfer(makeAddr("contract2"), "salt2");
        assertEq(deployer.pendingOwnershipCount(), 2, "two registered");
    }

    function test_transferAllOwnerships_callsTransferOwnershipOnEach() public {
        // Deploy a real ownable contract
        MockUpgradeable impl = new MockUpgradeable();

        // Create proxy via BaoFactory directly for this test
        bytes32 salt = keccak256("test_ownership");
        UUPSProxyDeployStub stub = deployer.getOrDeployStub();

        vm.prank(IBaoFactory(baoFactoryAddr).owner());
        IBaoFactory(baoFactoryAddr).setOperator(address(this), 365 days);

        address proxy = IBaoFactory(baoFactoryAddr).deploy(
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(address(stub), "")),
            salt
        );

        // Initialize with deployer as current owner, testOwner as pending
        vm.prank(address(deployer));
        UUPSProxyDeployStub(proxy).upgradeToAndCall(
            address(impl),
            abi.encodeCall(MockUpgradeable.initialize, (42, address(deployer), testOwner))
        );

        // Register for ownership transfer
        deployer.registerForOwnershipTransfer(proxy, "test::contract");

        // Transfer should complete the two-step ownership transfer
        deployer.transferAllOwnerships();

        // Verify ownership transferred
        assertEq(MockUpgradeable(proxy).owner(), testOwner, "ownership transferred");
        assertEq(deployer.pendingOwnershipCount(), 0, "pending list cleared");
    }
}
