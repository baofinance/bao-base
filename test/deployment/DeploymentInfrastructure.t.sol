// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";
import {BaoFactory} from "@bao-script/deployment/BaoFactory.sol";
import {Ownable} from "@solady/auth/Ownable.sol";

interface IOwnableReader {
    function owner() external view returns (address);
}

contract DeploymentInfrastructureExternal {
    function ensureBaoFactory() external returns (address) {
        return DeploymentInfrastructure._ensureBaoFactory();
    }
}

contract DeploymentInfrastructureTest is BaoDeploymentTest {
    bytes32 internal constant OWNABLE_OWNER_SLOT = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffff74873927; // mirrors Ownable._OWNER_SLOT
    address internal predicted;
    DeploymentInfrastructureExternal internal harness;

    function setUp() public override {
        super.setUp();
        harness = new DeploymentInfrastructureExternal();
        predicted = DeploymentInfrastructure.predictBaoFactoryAddress();
        vm.label(predicted, "predictedBaoFactory");
    }

    function test_RevertWhen_BaoFactoryCodeMismatch_() public {
        bytes memory wrongCode = hex"deadbeef";
        vm.etch(predicted, wrongCode);

        bytes32 expectedHash = keccak256(type(BaoFactory).runtimeCode);
        bytes32 actualHash = keccak256(wrongCode);

        vm.expectRevert(
            abi.encodeWithSelector(DeploymentInfrastructure.BaoFactoryCodeMismatch.selector, expectedHash, actualHash)
        );
        harness.ensureBaoFactory();
    }

    function test_RevertWhen_BaoFactoryOwnerMismatch_() public {
        harness.ensureBaoFactory();
        assertGt(predicted.code.length, 0, "BaoFactory code exists before owner mutation");
        address wrongOwner = address(0xBEEF);
        vm.store(predicted, OWNABLE_OWNER_SLOT, bytes32(uint256(uint160(wrongOwner))));
        bytes32 stored = vm.load(predicted, OWNABLE_OWNER_SLOT);
        assertEq(address(uint160(uint256(stored))), wrongOwner, "Owner slot updated in storage");
        address slotOwner = IOwnableReader(predicted).owner();
        assertEq(slotOwner, wrongOwner, "Owner getter reflects storage write");

        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentInfrastructure.BaoFactoryOwnerMismatch.selector,
                DeploymentInfrastructure.BAOMULTISIG,
                wrongOwner
            )
        );
        harness.ensureBaoFactory();
    }

    function test_RevertWhen_BaoFactoryProbeFails_() public {
        harness.ensureBaoFactory();
        assertGt(predicted.code.length, 0, "BaoFactory code should exist before probe");
        bytes memory revertData = abi.encodeWithSignature("ownerProbeFailed()");
        vm.mockCallRevert(predicted, abi.encodeWithSelector(Ownable.owner.selector), revertData);

        vm.expectRevert(DeploymentInfrastructure.BaoFactoryProbeFailed.selector);
        harness.ensureBaoFactory();
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
