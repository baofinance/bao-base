// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";
import {BaoDeployer} from "@bao-script/deployment/BaoDeployer.sol";
import {Ownable} from "@solady/auth/Ownable.sol";

interface IOwnableReader {
    function owner() external view returns (address);
}

contract DeploymentInfrastructureHarness {
    function ensureBaoDeployer() external returns (address) {
        return DeploymentInfrastructure.ensureBaoDeployer();
    }
}

contract DeploymentInfrastructureTest is BaoDeploymentTest {
    bytes32 internal constant OWNABLE_OWNER_SLOT = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffff74873927; // mirrors Ownable._OWNER_SLOT
    address internal predicted;
    DeploymentInfrastructureHarness internal harness;

    function setUp() public override {
        super.setUp();
        harness = new DeploymentInfrastructureHarness();
        predicted = DeploymentInfrastructure.predictBaoDeployerAddress();
        vm.label(predicted, "predictedBaoDeployer");
    }

    function test_RevertWhen_BaoDeployerCodeMismatch_() public {
        bytes memory wrongCode = hex"deadbeef";
        vm.etch(predicted, wrongCode);

        bytes32 expectedHash = keccak256(type(BaoDeployer).runtimeCode);
        bytes32 actualHash = keccak256(wrongCode);

        vm.expectRevert(
            abi.encodeWithSelector(DeploymentInfrastructure.BaoDeployerCodeMismatch.selector, expectedHash, actualHash)
        );
        harness.ensureBaoDeployer();
    }

    function test_RevertWhen_BaoDeployerOwnerMismatch_() public {
        assertGt(predicted.code.length, 0, "BaoDeployer code exists before owner mutation");
        address wrongOwner = address(0xBEEF);
        vm.store(predicted, OWNABLE_OWNER_SLOT, bytes32(uint256(uint160(wrongOwner))));
        bytes32 stored = vm.load(predicted, OWNABLE_OWNER_SLOT);
        assertEq(address(uint160(uint256(stored))), wrongOwner, "Owner slot updated in storage");
        address slotOwner = IOwnableReader(predicted).owner();
        assertEq(slotOwner, wrongOwner, "Owner getter reflects storage write");

        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentInfrastructure.BaoDeployerOwnerMismatch.selector,
                DeploymentInfrastructure.BAOMULTISIG,
                wrongOwner
            )
        );
        harness.ensureBaoDeployer();
    }

    function test_RevertWhen_BaoDeployerProbeFails_() public {
        assertGt(predicted.code.length, 0, "BaoDeployer code should exist before probe");
        bytes memory revertData = abi.encodeWithSignature("ownerProbeFailed()");
        vm.mockCallRevert(predicted, abi.encodeWithSelector(Ownable.owner.selector), revertData);

        vm.expectRevert(DeploymentInfrastructure.BaoDeployerProbeFailed.selector);
        harness.ensureBaoDeployer();
        vm.clearMockedCalls();
    }

    function test_CommitmentHashesInputs_() public pure {
        address operator = address(0x1234567890);
        uint256 value = 7 ether;
        bytes32 salt = keccak256("salt");
        bytes32 initCodeHash = keccak256("init");

        bytes32 expected = keccak256(abi.encode(operator, value, salt, initCodeHash));
        bytes32 actual = DeploymentInfrastructure.commitment(operator, value, salt, initCodeHash);

        assertEq(actual, expected, "Commitment hash matches keccak");
    }
}
