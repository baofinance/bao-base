// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";

import {HarborPauser_v1} from "@bao/HarborPauser_v1.sol";
import {IHarborFixedOwnable} from "@bao/interfaces/IHarborFixedOwnable.sol";
import {FactoryDeployer} from "@bao-script/deployment/FactoryDeployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";

// ═══════════════════════════════════════════════════════════════
// Factory deployment tests for HarborFixedOwnable contracts
// Uses HarborPauser_v1 as the concrete test subject since the
// deleted HarborFixedOwnableUpgradeable_v1 base no longer exists.
// ═══════════════════════════════════════════════════════════════

/// @notice Concrete FactoryDeployer for testing direct deploy of HarborFixedOwnable contracts.
contract TestableFixedOwnableDeployer is FactoryDeployer {
    function treasury() public pure override returns (address) {
        return 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;
    }

    function owner() public pure override returns (address) {
        return 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;
    }

    function _shouldPersistState() internal pure override returns (bool) {
        return false;
    }

    function setSaltPrefix(string memory prefix) external {
        _setSaltPrefix(prefix);
    }

    function deployProxyAndRecord(
        DeploymentTypes.State memory stateData,
        string memory proxyId,
        address implementation,
        string memory contractSource,
        string memory contractType,
        bytes memory initData
    ) external returns (address proxy) {
        return _deployProxyAndRecord(stateData, proxyId, implementation, contractSource, contractType, initData);
    }

    function getImplementation(address proxy) external view returns (address) {
        return _getImplementation(proxy);
    }

    function pendingOwnershipCount() external view returns (uint256) {
        return _pendingOwnershipCount();
    }

    function transferAllOwnerships() external {
        _transferAllOwnerships();
    }
}

contract HarborFixedOwnableFactoryDeployTest is BaoTest {
    TestableFixedOwnableDeployer internal deployer;

    function setUp() public {
        _ensureBaoFactory();

        deployer = new TestableFixedOwnableDeployer();
        deployer.setSaltPrefix("fixed_ownable_test");

        address factory = deployer.baoFactory();
        if (!IBaoFactory(factory).isCurrentOperator(address(deployer))) {
            vm.prank(IBaoFactory(factory).owner());
            IBaoFactory(factory).setOperator(address(deployer), 365 days);
        }
    }

    function _freshState() internal pure returns (DeploymentTypes.State memory state) {
        state.network = "test";
        state.saltPrefix = "fixed_ownable_test";
    }

    // ========== Deploy HarborPauser_v1 via factory (direct, no stub) ==========

    function test_deployViaFactory_emptyInit() public {
        HarborPauser_v1 impl = new HarborPauser_v1();
        DeploymentTypes.State memory state = _freshState();
        state.baoFactory = deployer.baoFactory();

        address proxy = deployer.deployProxyAndRecord(
            state,
            "pauser",
            address(impl),
            "@bao/HarborPauser_v1.sol",
            "HarborPauser_v1",
            "" // no init data — HarborFixedOwnable has no initializer
        );

        assertGt(proxy.code.length, 0, "proxy has code");
        assertEq(deployer.getImplementation(proxy), address(impl), "implementation set");
    }

    function test_deployViaFactory_ownerIsMultisig() public {
        HarborPauser_v1 impl = new HarborPauser_v1();
        DeploymentTypes.State memory state = _freshState();
        state.baoFactory = deployer.baoFactory();

        address proxy = deployer.deployProxyAndRecord(
            state,
            "owner_check",
            address(impl),
            "@bao/HarborPauser_v1.sol",
            "HarborPauser_v1",
            ""
        );

        assertEq(HarborPauser_v1(proxy).owner(), HARBOR_MULTISIG, "owner is multisig");
        assertTrue(HarborPauser_v1(proxy).owner() != address(deployer), "owner is not deployer");
    }

    function test_deployViaFactory_pauserRevertsAllCalls() public {
        HarborPauser_v1 impl = new HarborPauser_v1();
        DeploymentTypes.State memory state = _freshState();
        state.baoFactory = deployer.baoFactory();

        address proxy = deployer.deployProxyAndRecord(
            state,
            "pauser_revert",
            address(impl),
            "@bao/HarborPauser_v1.sol",
            "HarborPauser_v1",
            ""
        );

        vm.expectRevert(
            abi.encodeWithSelector(HarborPauser_v1.Paused.selector, "Contract is paused and all functions are disabled")
        );
        (bool ok, ) = proxy.call(abi.encodeWithSignature("someFunction()"));
        // expectRevert consumes the revert, so ok would be true from expectRevert perspective
        ok; // silence unused warning
    }

    function test_deployViaFactory_upgradeByMultisig() public {
        HarborPauser_v1 impl1 = new HarborPauser_v1();
        HarborPauser_v1 impl2 = new HarborPauser_v1();
        DeploymentTypes.State memory state = _freshState();
        state.baoFactory = deployer.baoFactory();

        address proxy = deployer.deployProxyAndRecord(
            state,
            "upgrade_test",
            address(impl1),
            "@bao/HarborPauser_v1.sol",
            "HarborPauser_v1",
            ""
        );

        // Multisig can upgrade
        vm.prank(HARBOR_MULTISIG);
        HarborPauser_v1(proxy).upgradeToAndCall(address(impl2), "");
        assertEq(deployer.getImplementation(proxy), address(impl2), "impl upgraded");
    }

    function test_deployViaFactory_upgradeReverts_notOwner() public {
        HarborPauser_v1 impl = new HarborPauser_v1();
        HarborPauser_v1 impl2 = new HarborPauser_v1();
        DeploymentTypes.State memory state = _freshState();
        state.baoFactory = deployer.baoFactory();

        address proxy = deployer.deployProxyAndRecord(
            state,
            "auth_test",
            address(impl),
            "@bao/HarborPauser_v1.sol",
            "HarborPauser_v1",
            ""
        );

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(IHarborFixedOwnable.Unauthorized.selector);
        HarborPauser_v1(proxy).upgradeToAndCall(address(impl2), "");
    }

    function test_deployViaFactory_transferOwnershipSkipped() public {
        HarborPauser_v1 impl = new HarborPauser_v1();
        DeploymentTypes.State memory state = _freshState();
        state.baoFactory = deployer.baoFactory();

        deployer.deployProxyAndRecord(
            state,
            "skip_transfer",
            address(impl),
            "@bao/HarborPauser_v1.sol",
            "HarborPauser_v1",
            ""
        );

        assertEq(deployer.pendingOwnershipCount(), 1, "pending count");

        // Already owned by multisig = deployer.owner(), so transfer is skipped
        deployer.transferAllOwnerships();
        assertEq(deployer.pendingOwnershipCount(), 0, "cleared after transfer");
    }

    function test_supportsInterface() public {
        HarborPauser_v1 impl = new HarborPauser_v1();
        DeploymentTypes.State memory state = _freshState();
        state.baoFactory = deployer.baoFactory();

        address proxy = deployer.deployProxyAndRecord(
            state,
            "interface_test",
            address(impl),
            "@bao/HarborPauser_v1.sol",
            "HarborPauser_v1",
            ""
        );

        // owner() works through pauser (not caught by fallback)
        assertEq(HarborPauser_v1(proxy).owner(), HARBOR_MULTISIG);

        // supportsInterface works through pauser
        assertTrue(IERC165(proxy).supportsInterface(type(IERC5313).interfaceId));
        assertTrue(IERC165(proxy).supportsInterface(type(IERC165).interfaceId));
        assertTrue(IERC165(proxy).supportsInterface(type(IHarborFixedOwnable).interfaceId));
        assertFalse(IERC165(proxy).supportsInterface(0xdeadbeef));
    }
}
