// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";
import {BaoFactoryLib} from "@bao-script/deployment/BaoFactory.sol";
import {BaoFactoryBytecode} from "@bao-script/deployment/BaoFactoryBytecode.sol";
import {LibClone} from "@solady/utils/LibClone.sol";

/// @dev Interface for external calls to library functions
contract DeploymentInfrastructureExternal {
    function ensureBaoFactory() external returns (address) {
        return DeploymentInfrastructure._ensureBaoFactoryProduction();
    }

    function predictBaoFactoryAddress() external pure returns (address) {
        return DeploymentInfrastructure.predictBaoFactoryAddress();
    }

    function predictBaoFactoryImplementation() external pure returns (address) {
        return DeploymentInfrastructure.predictBaoFactoryImplementation();
    }
}

/// @title DeploymentInfrastructureTest
/// @notice Tests for DeploymentInfrastructure library
contract DeploymentInfrastructureTest is BaoDeploymentTest {
    address internal predictedProxy;
    address internal predictedImpl;
    DeploymentInfrastructureExternal internal harness;

    function setUp() public override {
        super.setUp();
        harness = new DeploymentInfrastructureExternal();
        predictedProxy = harness.predictBaoFactoryAddress();
        predictedImpl = harness.predictBaoFactoryImplementation();
        vm.label(predictedProxy, "predictedBaoFactoryProxy");
        vm.label(predictedImpl, "predictedBaoFactoryImpl");
    }

    function test_PredictBaoFactoryAddress_ReturnsProxy() public view {
        // predictBaoFactoryAddress should return the proxy address, not implementation
        // Use captured production bytecode hash for stable addresses under coverage
        bytes32 creationCodeHash = BaoFactoryBytecode.PRODUCTION_CREATION_CODE_HASH;
        string memory salt = BaoFactoryLib.PRODUCTION_SALT;
        address impl = BaoFactoryLib.predictImplementation(salt, creationCodeHash);
        address proxy = BaoFactoryLib.predictProxy(impl);

        assertEq(predictedProxy, proxy, "predictBaoFactoryAddress should return proxy");
        assertEq(predictedImpl, impl, "predictBaoFactoryImplementation should return implementation");
        assertTrue(predictedProxy != predictedImpl, "proxy and implementation should be different");
    }

    function test_EnsureBaoFactory_DeploysAndReturnsProxy() public {
        assertEq(predictedImpl.code.length, 0, "implementation should not exist initially");
        assertEq(predictedProxy.code.length, 0, "proxy should not exist initially");

        address returned = harness.ensureBaoFactory();

        assertEq(returned, predictedProxy, "should return proxy address");
        assertGt(predictedImpl.code.length, 0, "implementation should be deployed");
        assertGt(predictedProxy.code.length, 0, "proxy should be deployed");
    }

    function test_EnsureBaoFactory_ProxyHasCorrectCode() public {
        harness.ensureBaoFactory();

        // Solady ERC1967 proxy has a known 61-byte runtime code
        bytes32 expectedHash = LibClone.ERC1967_CODE_HASH;
        bytes32 actualHash;
        assembly {
            actualHash := extcodehash(sload(predictedProxy.slot))
        }

        assertEq(actualHash, expectedHash, "proxy should have Solady ERC1967 runtime code");
    }

    function test_RevertWhen_BaoFactoryProxyCodeMismatch() public {
        // First deploy normally
        harness.ensureBaoFactory();

        // Then corrupt the proxy code
        bytes memory wrongCode = hex"deadbeef";
        vm.etch(predictedProxy, wrongCode);

        bytes32 expectedHash = LibClone.ERC1967_CODE_HASH;
        bytes32 actualHash = keccak256(wrongCode);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentInfrastructure.BaoFactoryProxyCodeMismatch.selector,
                expectedHash,
                actualHash
            )
        );
        harness.ensureBaoFactory();
    }

    function test_RevertWhen_BaoFactoryProbeFails() public {
        harness.ensureBaoFactory();
        assertGt(predictedProxy.code.length, 0, "proxy should exist before probe test");

        // Mock the owner() call to revert
        // owner is a public constant, which generates a getter function
        bytes4 ownerSelector = bytes4(keccak256("owner()"));
        bytes memory revertData = abi.encodeWithSignature("ownerProbeFailed()");
        vm.mockCallRevert(predictedProxy, abi.encodeWithSelector(ownerSelector), revertData);

        vm.expectRevert(DeploymentInfrastructure.BaoFactoryProbeFailed.selector);
        harness.ensureBaoFactory();

        vm.clearMockedCalls();
    }

    function test_RevertWhen_BaoFactoryOwnerMismatch() public {
        harness.ensureBaoFactory();
        assertGt(predictedProxy.code.length, 0, "proxy should exist before owner mismatch test");

        // Mock the owner() call to return wrong address
        // owner is a public constant, which generates a getter function
        bytes4 ownerSelector = bytes4(keccak256("owner()"));
        address wrongOwner = address(0xBEEF);
        address expectedOwner = BaoFactoryLib.PRODUCTION_OWNER;
        vm.mockCall(predictedProxy, abi.encodeWithSelector(ownerSelector), abi.encode(wrongOwner));

        vm.expectRevert(
            abi.encodeWithSelector(DeploymentInfrastructure.BaoFactoryOwnerMismatch.selector, expectedOwner, wrongOwner)
        );
        harness.ensureBaoFactory();

        vm.clearMockedCalls();
    }

    function test_EnsureBaoFactory_Idempotent() public {
        // First deployment
        address first = harness.ensureBaoFactory();
        assertEq(first, predictedProxy);

        // Second call should return same address without error
        address second = harness.ensureBaoFactory();
        assertEq(second, first, "should return same address on repeat calls");
    }

    function test_BaoFactoryLib_PredictImplementation() public pure {
        bytes32 mockCodeHash = keccak256("mock.creation.code");
        string memory salt = BaoFactoryLib.PRODUCTION_SALT;
        address impl = BaoFactoryLib.predictImplementation(salt, mockCodeHash);

        // Verify CREATE2 formula
        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), BaoFactoryLib.NICKS_FACTORY, keccak256(bytes(salt)), mockCodeHash)
        );
        address expected = address(uint160(uint256(hash)));
        assertEq(impl, expected, "predictImplementation should use CREATE2 formula");
    }

    function test_BaoFactoryLib_PredictProxy() public pure {
        address mockImpl = address(0x1234567890AbcdEF1234567890aBcdef12345678);
        address proxy = BaoFactoryLib.predictProxy(mockImpl);

        // Verify RLP encoding for CREATE with nonce=1
        // RLP([address, 1]): 0xd6 0x94 <20-byte address> 0x01
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), mockImpl, bytes1(0x01)));
        address expected = address(uint160(uint256(hash)));
        assertEq(proxy, expected, "predictProxy should use RLP-encoded CREATE formula");
    }

    function test_BaoFactoryLib_PredictAddresses() public pure {
        bytes32 mockCodeHash = keccak256("mock.creation.code");
        string memory salt = BaoFactoryLib.PRODUCTION_SALT;
        (address impl, address proxy) = BaoFactoryLib.predictAddresses(salt, mockCodeHash);

        assertEq(impl, BaoFactoryLib.predictImplementation(salt, mockCodeHash));
        assertEq(proxy, BaoFactoryLib.predictProxy(impl));
    }
}
