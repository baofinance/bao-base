// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {LibClone} from "@solady/utils/LibClone.sol";

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {IHarborFixedOwnable} from "@bao/interfaces/IHarborFixedOwnable.sol";
import {HarborPauser_v1} from "@bao/HarborPauser_v1.sol";

/**
 * @title MockFunctionalContract
 * @dev A mock UUPS-upgradeable contract for testing pause/unpause via HarborPauser
 * Uses simple owner pattern for testing
 */
contract MockFunctionalContract is UUPSUpgradeable {
    error Unauthorized();

    uint256 private _value;
    address private immutable _OWNER;

    event ValueSet(uint256 oldValue, uint256 newValue);

    constructor(address owner_) {
        _OWNER = owner_;
    }

    function initialize(uint256 initialValue) external {
        _value = initialValue;
    }

    function owner() public view returns (address) {
        return _OWNER;
    }

    modifier onlyOwner() {
        if (msg.sender != _OWNER) revert Unauthorized();
        _;
    }

    function value() external view returns (uint256) {
        return _value;
    }

    function setValue(uint256 newValue) external onlyOwner {
        uint256 oldValue = _value;
        _value = newValue;
        emit ValueSet(oldValue, newValue);
    }

    function doSomething() external pure returns (string memory) {
        return "functional";
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}

/**
 * @title HarborPauserTest
 * @notice Tests for HarborPauser_v1 deployed via BaoFactory
 * @dev Tests the pause/unpause pattern:
 *      1. Deploy functional contract
 *      2. Deploy HarborPauser via BaoFactory at known address
 *      3. Pause by upgrading proxy to HarborPauser
 *      4. Verify all calls revert
 *      5. Unpause by upgrading back to functional implementation
 *      6. Verify functionality restored
 */
contract HarborPauserTest is BaoTest {
    IBaoFactory public factory;

    address public user;

    function setUp() public {
        factory = IBaoFactory(_ensureBaoFactory());
        user = makeAddr("user");
    }

    /// @notice Deploy HarborPauser via BaoFactory at a deterministic address
    function _deployHarborPauserViaFactory(bytes32 salt) internal returns (address pauser) {
        bytes memory creationCode = type(HarborPauser_v1).creationCode;
        pauser = factory.deploy(creationCode, salt);
    }

    /// @notice Deploy MockFunctionalContract via BaoFactory
    function _deployFunctionalViaFactory(bytes32 salt, address owner_) internal returns (address functional) {
        bytes memory creationCode = abi.encodePacked(type(MockFunctionalContract).creationCode, abi.encode(owner_));
        functional = factory.deploy(creationCode, salt);
    }

    /// @notice Deploy a minimal ERC1967 proxy pointing to an implementation
    function _deployProxy(address implementation, bytes memory initData) internal returns (address proxy) {
        proxy = LibClone.deployERC1967(implementation);
        if (initData.length > 0) {
            (bool success, ) = proxy.call(initData);
            require(success, "Init failed");
        }
    }

    /// @notice Test basic HarborPauser deployment via BaoFactory
    function test_deployHarborPauserViaBaoFactory() public {
        address pauser = _deployHarborPauserViaFactory(keccak256("pauser.test"));

        // Verify pauser is deployed
        assertTrue(pauser.code.length > 0, "Pauser should be deployed");

        // Verify owner is BAOMULTISIG (hardcoded in HarborPauser)
        assertEq(HarborPauser_v1(pauser).owner(), HARBOR_MULTISIG, "Owner should be BAOMULTISIG");

        // Verify ERC165 support
        assertTrue(IERC165(pauser).supportsInterface(type(IERC165).interfaceId), "Should support IERC165");
        assertTrue(
            IERC165(pauser).supportsInterface(type(IHarborFixedOwnable).interfaceId),
            "Should support IHarborFixedOwnable"
        );
    }

    /// @notice Test that HarborPauser owner is hardcoded to BAOMULTISIG, not factory
    function test_pauserOwnerIsHardcodedNotFactory() public {
        address pauser = _deployHarborPauserViaFactory(keccak256("pauser.owner-test"));

        // Owner should be BAOMULTISIG, NOT the factory
        assertEq(HarborPauser_v1(pauser).owner(), HARBOR_MULTISIG);
        assertTrue(HarborPauser_v1(pauser).owner() != address(factory));
    }

    /// @notice Test that HarborPauser reverts all function calls
    function test_pauserRevertsAllCalls() public {
        address pauser = _deployHarborPauserViaFactory(keccak256("pauser.revert"));

        // Any arbitrary call should revert with Paused error
        vm.expectRevert(
            abi.encodeWithSelector(HarborPauser_v1.Paused.selector, "Contract is paused and all functions are disabled")
        );
        MockFunctionalContract(pauser).value();
    }

    /// @notice Test pause and unpause workflow via proxy upgrade
    function test_pauseAndUnpauseViaProxyUpgrade() public {
        // Step 1: Deploy functional implementation via BaoFactory (owned by HARBOR_MULTISIG)
        address functional = _deployFunctionalViaFactory(keccak256("functional.impl"), HARBOR_MULTISIG);
        assertEq(MockFunctionalContract(functional).owner(), HARBOR_MULTISIG);

        // Step 2: Deploy proxy pointing to functional implementation
        bytes memory initData = abi.encodeCall(MockFunctionalContract.initialize, (42));
        address proxy = _deployProxy(functional, initData);
        assertEq(MockFunctionalContract(proxy).value(), 42, "Initial value should be set");
        assertEq(MockFunctionalContract(proxy).doSomething(), "functional", "Should be functional");

        // Verify owner can operate
        vm.prank(HARBOR_MULTISIG);
        MockFunctionalContract(proxy).setValue(100);
        assertEq(MockFunctionalContract(proxy).value(), 100, "Value should be updated");

        // Step 3: Deploy HarborPauser via BaoFactory (owned by BAOMULTISIG)
        address pauser = _deployHarborPauserViaFactory(keccak256("pauser.impl"));
        assertEq(HarborPauser_v1(pauser).owner(), HARBOR_MULTISIG, "Pauser should be owned by BAOMULTISIG");

        // Step 4: PAUSE - Upgrade proxy to HarborPauser
        vm.prank(HARBOR_MULTISIG);
        UUPSUpgradeable(proxy).upgradeToAndCall(pauser, "");

        // Verify proxy now points to pauser and reverts all calls
        vm.expectRevert(
            abi.encodeWithSelector(HarborPauser_v1.Paused.selector, "Contract is paused and all functions are disabled")
        );
        MockFunctionalContract(proxy).value();

        vm.expectRevert(
            abi.encodeWithSelector(HarborPauser_v1.Paused.selector, "Contract is paused and all functions are disabled")
        );
        MockFunctionalContract(proxy).doSomething();

        vm.expectRevert(
            abi.encodeWithSelector(HarborPauser_v1.Paused.selector, "Contract is paused and all functions are disabled")
        );
        vm.prank(HARBOR_MULTISIG);
        MockFunctionalContract(proxy).setValue(200);

        // But owner() still works (it's defined on HarborPauser)
        assertEq(HarborPauser_v1(proxy).owner(), HARBOR_MULTISIG, "Owner should still be accessible");

        // Step 5: UNPAUSE - Upgrade proxy back to functional
        vm.prank(HARBOR_MULTISIG);
        UUPSUpgradeable(proxy).upgradeToAndCall(functional, "");

        // Step 6: Verify functionality is restored
        // Note: value is preserved in proxy storage across upgrades
        assertEq(MockFunctionalContract(proxy).value(), 100, "Value should be preserved from before pause");
        assertEq(MockFunctionalContract(proxy).doSomething(), "functional", "Should be functional again");

        // Owner can operate again
        vm.prank(HARBOR_MULTISIG);
        MockFunctionalContract(proxy).setValue(300);
        assertEq(MockFunctionalContract(proxy).value(), 300, "Value should be updated after unpause");
    }

    /// @notice Test that only owner (BAOMULTISIG) can unpause
    function test_onlyOwnerCanUnpause() public {
        // Deploy and pause
        address functional = _deployFunctionalViaFactory(keccak256("functional.auth"), HARBOR_MULTISIG);
        address proxy = _deployProxy(functional, abi.encodeCall(MockFunctionalContract.initialize, (42)));
        address pauser = _deployHarborPauserViaFactory(keccak256("pauser.auth"));

        vm.prank(HARBOR_MULTISIG);
        UUPSUpgradeable(proxy).upgradeToAndCall(pauser, "");

        // Non-owner cannot unpause
        vm.prank(user);
        vm.expectRevert(IHarborFixedOwnable.Unauthorized.selector);
        UUPSUpgradeable(proxy).upgradeToAndCall(functional, "");

        // Owner (BAOMULTISIG) can unpause
        vm.prank(HARBOR_MULTISIG);
        UUPSUpgradeable(proxy).upgradeToAndCall(functional, "");

        // Verify functional
        assertEq(MockFunctionalContract(proxy).doSomething(), "functional");
    }

    /// @notice Test deterministic address - same salt yields same predicted address
    function test_deterministicAddress() public {
        bytes32 salt = keccak256("pauser.deterministic");

        // Predict address before deployment
        address predicted = factory.predictAddress(salt);

        // Deploy
        address pauser = _deployHarborPauserViaFactory(salt);

        // Should match prediction
        assertEq(pauser, predicted, "Deployed address should match prediction");
    }
}
