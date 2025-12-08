// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoFactory} from "@bao-script/deployment/BaoFactory.sol";

library DeploymentInfrastructure {
    address public constant BAOMULTISIG = 0xFC69e0a5823E2AfCBEb8a35d33588360F1496a00;

    address public constant _NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    /// @dev The bytecode of Nick's factory.
    bytes public constant _NICKS_FACTORY_BYTECODE =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    /// Salt for deploying BaoFactory via Nick's Factory
    /// This ensures BaoFactory has the same address on all chains
    bytes32 internal constant _BAO_DEPLOYER_SALT = keccak256("Bao.deterministic-deployer.harbor.v1");

    error BaoFactoryCodeMismatch(bytes32 expected, bytes32 actual);
    error BaoFactoryOwnerMismatch(address expected, address actual);
    error BaoFactoryProbeFailed();

    /// @notice Predict BaoFactory address for a given owner (CREATE2 via Nick's Factory)
    function predictBaoFactoryAddress() internal pure returns (address) {
        bytes memory creationCode = abi.encodePacked(type(BaoFactory).creationCode, abi.encode(BAOMULTISIG));
        bytes32 bytecodeHash = keccak256(creationCode);
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), _NICKS_FACTORY, _BAO_DEPLOYER_SALT, bytecodeHash));
        return address(uint160(uint256(hash)));
    }

    /// @notice external version for expectRevert tracking
    function ensureBaoFactory() external returns (address deployed) {
        deployed = _ensureBaoFactory();
    }

    /// @notice Deploy BaoFactory via Nick's Factory if it doesn't exist
    function _ensureBaoFactory() internal returns (address deployed) {
        // check nicks factory is there. It should be everywhere, even on a fresh anvil
        require(_NICKS_FACTORY.code.length > 0, "Nick's factory must be installed in this chain");

        // check the deployer is there
        deployed = predictBaoFactoryAddress();
        bytes32 expectedRuntimeHash = keccak256(type(BaoFactory).runtimeCode);
        bytes32 existingCodeHash;
        assembly {
            existingCodeHash := extcodehash(deployed)
        }
        // if it isn't there we deploy it - there isn't a scenario we shouldn't do that
        if (existingCodeHash == bytes32(0)) {
            address factory = _NICKS_FACTORY;
            bytes memory creationCode = abi.encodePacked(type(BaoFactory).creationCode, abi.encode(BAOMULTISIG));
            bytes32 salt = _BAO_DEPLOYER_SALT;

            /// @solidity memory-safe-assembly
            assembly {
                let codeLength := mload(creationCode)
                mstore(creationCode, salt)
                if iszero(call(gas(), factory, 0, creationCode, add(codeLength, 0x20), 0x00, 0x20)) {
                    returndatacopy(creationCode, 0x00, returndatasize())
                    revert(creationCode, returndatasize())
                }
                mstore(creationCode, codeLength)
                deployed := shr(96, mload(0x00))
            }
            require(deployed == predictBaoFactoryAddress(), "BaoFactory deployed to unexpected address");
            require(deployed.code.length > 0, "BaoFactory missing code");
            // We just deployed known code, skip hash check
        } else if (existingCodeHash != expectedRuntimeHash) {
            // Only check hash for pre-existing contracts
            revert BaoFactoryCodeMismatch(expectedRuntimeHash, existingCodeHash);
        }
        try BaoFactory(deployed).owner() returns (address currentOwner) {
            if (currentOwner != BAOMULTISIG) {
                revert BaoFactoryOwnerMismatch(BAOMULTISIG, currentOwner);
            }
        } catch {
            revert BaoFactoryProbeFailed();
        }
    }

    function commitment(
        address operator,
        uint256 value,
        bytes32 salt,
        bytes32 initCodeHash
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(operator, value, salt, initCodeHash));
    }
}
