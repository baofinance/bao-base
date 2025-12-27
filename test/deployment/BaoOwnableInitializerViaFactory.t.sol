// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Test} from "forge-std/Test.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";
import {UUPSProxyDeployStub} from "@bao-script/deployment/UUPSProxyDeployStub.sol";
import {IUUPSUpgradeableProxy} from "@bao-script/deployment/DeploymentBase.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract OwnableInitViaFactoryV1 is Initializable, UUPSUpgradeable, BaoOwnable {
    uint256 public value;

    function initialize(uint256 value_, address deployerOwner, address pendingOwner) external initializer {
        value = value_;
        _initializeOwner(deployerOwner, pendingOwner);
    }

    function _authorizeUpgrade(address) internal view override onlyOwner {}
}

contract OwnableLegacyInitViaFactoryV1 is Initializable, UUPSUpgradeable, BaoOwnable {
    uint256 public value;

    function initialize(uint256 value_, address pendingOwner) external initializer {
        value = value_;
        _initializeOwner(pendingOwner);
    }

    function _authorizeUpgrade(address) internal view override onlyOwner {}
}

contract UUPSProxyFactoryCaller {
    function deployStub() external returns (UUPSProxyDeployStub stub) {
        stub = new UUPSProxyDeployStub();
    }

    function deployProxy(address stub) external returns (address proxy) {
        proxy = address(new ERC1967Proxy(stub, ""));
    }

    function upgradeToAndCall(address proxy, address implementation, bytes calldata data) external {
        IUUPSUpgradeableProxy(proxy).upgradeToAndCall(implementation, data);
    }
}

contract BaoOwnableInitializerViaFactoryTest is Test {
    function test_explicitInitializerSetsOwnerNotCaller() public {
        address deployerOwner = makeAddr("deployerOwner");
        address pendingOwner = makeAddr("pendingOwner");

        UUPSProxyFactoryCaller factory = new UUPSProxyFactoryCaller();

        // The factory becomes the immutable owner of the stub.
        UUPSProxyDeployStub stub = factory.deployStub();
        address proxy = factory.deployProxy(address(stub));

        OwnableInitViaFactoryV1 impl = new OwnableInitViaFactoryV1();
        bytes memory initData = abi.encodeCall(OwnableInitViaFactoryV1.initialize, (123, deployerOwner, pendingOwner));

        // The initializer runs with msg.sender == factory, but ownership is explicitly set.
        factory.upgradeToAndCall(proxy, address(impl), initData);

        assertEq(IBaoOwnable(proxy).owner(), deployerOwner);

        // Caller (factory) is not owner.
        vm.prank(address(factory));
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(proxy).transferOwnership(pendingOwner);

        // Owner can complete the one-shot ownership transfer.
        vm.prank(deployerOwner);
        IBaoOwnable(proxy).transferOwnership(pendingOwner);
        assertEq(IBaoOwnable(proxy).owner(), pendingOwner);
    }

    function test_legacyInitializerStillUsesCallerAsOwner() public {
        address pendingOwner = makeAddr("pendingOwner");

        UUPSProxyFactoryCaller factory = new UUPSProxyFactoryCaller();
        UUPSProxyDeployStub stub = factory.deployStub();
        address proxy = factory.deployProxy(address(stub));

        OwnableLegacyInitViaFactoryV1 impl = new OwnableLegacyInitViaFactoryV1();
        bytes memory initData = abi.encodeCall(OwnableLegacyInitViaFactoryV1.initialize, (123, pendingOwner));

        // Legacy initializer uses msg.sender (factory) as the initial owner.
        factory.upgradeToAndCall(proxy, address(impl), initData);
        assertEq(IBaoOwnable(proxy).owner(), address(factory));
    }
}
