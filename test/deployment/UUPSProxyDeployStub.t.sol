// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {UUPSProxyDeployStub} from "@bao-script/deployment/UUPSProxyDeployStub.sol";

contract UUPSProxyDeployStubHarness is UUPSProxyDeployStub {
    constructor(address owner_) UUPSProxyDeployStub(owner_) {}

    function assertAuthorize() external view {
        _authorizeUpgrade(address(0));
    }
}

contract UUPSProxyDeployStubSetup is Test {
    UUPSProxyDeployStubHarness internal stub;
    address internal owner;
    address internal newDeployer;
    address internal outsider;

    function setUp() public virtual {
        owner = makeAddr("owner");
        newDeployer = makeAddr("newDeployer");
        outsider = makeAddr("outsider");

        stub = new UUPSProxyDeployStubHarness(owner);
        vm.label(address(stub), "stub");
        vm.label(owner, "owner");
        vm.label(newDeployer, "newDeployer");
        vm.label(outsider, "outsider");
    }
}

contract UUPSProxyDeployStubTest is UUPSProxyDeployStubSetup {
    function test_ConstructorSetsDeployer_() public view {
        // Assumption: stub deployer defaults to the contract that deployed it.
        assertEq(stub.deployer(), address(this), "constructor sets deployer to test contract");
    }

    function test_OwnerCanSetDeployer_() public {
        // Assumption: only the owner rotates the deployer and the new value is persisted.
        vm.prank(owner);
        stub.setDeployer(newDeployer);
        assertEq(stub.deployer(), newDeployer, "owner rotated deployer");
    }

    function test_SetDeployerNonOwnerReverts_() public {
        // Assumption: non-owners cannot change the deployer.
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        stub.setDeployer(newDeployer);
    }

    function test_AuthorizeUpgradeRequiresDeployer_() public {
        // Assumption: only the active deployer can authorize upgrades.
        stub.assertAuthorize();

        vm.prank(owner);
        stub.setDeployer(newDeployer);

        vm.prank(newDeployer);
        stub.assertAuthorize();

        vm.prank(outsider);
        vm.expectRevert(bytes("not deployer"));
        stub.assertAuthorize();
    }

    function test_OwnershipHandoverIndefiniteWindow_() public {
        // Assumption: ownership handover requests never expire and complete when the owner confirms.
        address governance = makeAddr("governance");
        vm.label(governance, "governance");

        vm.prank(governance);
        stub.requestOwnershipHandover();

        uint256 expiry = stub.ownershipHandoverExpiresAt(governance);
        uint256 expectedExpiry = block.timestamp + stub.handoverTimeout();
        assertEq(expiry, expectedExpiry, "handover expiry matches 48 hour window");

        vm.prank(owner);
        stub.completeOwnershipHandover(governance);
        assertEq(stub.owner(), governance, "ownership transferred");
    }
}
