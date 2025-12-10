// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoFactory, BaoFactoryLib} from "@bao-script/deployment/BaoFactory.sol";
import {BaoFactoryBytecode} from "@bao-script/deployment/BaoFactoryBytecode.sol";
import {LibClone} from "@solady/utils/LibClone.sol";

/// @title DeploymentInfrastructure
/// @notice Core BaoFactory deployment logic - shared by all deployment modes
/// @dev This library provides the low-level deployment mechanics.
///      Callers choose which bytecode/salt/owner to use based on their mode:
///      - Testing: current build bytecode (type(BaoFactory).creationCode)
///      - Production: captured production bytecode
///      - Variant: env var selects from captured variants
library DeploymentInfrastructure {
    /// @dev Nick's Factory address (same on all EVM chains)
    address internal constant _NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev The bytecode of Nick's factory (for deployment to fresh chains)
    bytes internal constant _NICKS_FACTORY_BYTECODE =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    error BaoFactoryProxyCodeMismatch(bytes32 expected, bytes32 actual);
    error BaoFactoryOwnerMismatch(address expected, address actual);
    error BaoFactoryProbeFailed();

    // =========================================================================
    // Address Prediction (pure functions, no deployment)
    // =========================================================================

    /// @notice Predict BaoFactory proxy address using captured production bytecode
    function predictBaoFactoryAddress() internal pure returns (address proxy) {
        (, proxy) = BaoFactoryLib.predictAddresses(
            BaoFactoryLib.PRODUCTION_SALT,
            BaoFactoryBytecode.PRODUCTION_CREATION_CODE_HASH
        );
    }

    /// @notice Predict BaoFactory proxy address using specific creation code hash and salt
    function predictBaoFactoryAddress(
        string memory factorySalt,
        bytes32 creationCodeHash
    ) internal pure returns (address proxy) {
        (, proxy) = BaoFactoryLib.predictAddresses(factorySalt, creationCodeHash);
    }

    /// @notice Predict BaoFactory implementation address using captured production bytecode
    function predictBaoFactoryImplementation() internal pure returns (address implementation) {
        implementation = BaoFactoryLib.predictImplementation(
            BaoFactoryLib.PRODUCTION_SALT,
            BaoFactoryBytecode.PRODUCTION_CREATION_CODE_HASH
        );
    }

    /// @notice Predict BaoFactory implementation address using specific creation code hash and salt
    function predictBaoFactoryImplementation(
        string memory factorySalt,
        bytes32 creationCodeHash
    ) internal pure returns (address implementation) {
        implementation = BaoFactoryLib.predictImplementation(factorySalt, creationCodeHash);
    }

    // =========================================================================
    // Deployment Functions (for different modes)
    // =========================================================================

    /// @notice Deploy BaoFactory using current build bytecode (for testing)
    /// @dev Uses type(BaoFactory).creationCode - bytecode changes with code changes
    function _ensureBaoFactoryCurrentBuild() internal returns (address proxy) {
        return
            _ensureBaoFactoryWithConfig(
                type(BaoFactory).creationCode,
                BaoFactoryLib.PRODUCTION_SALT,
                BaoFactoryLib.PRODUCTION_OWNER
            );
    }

    /// @notice Deploy BaoFactory using captured production bytecode
    /// @dev Uses BaoFactoryBytecode.PRODUCTION_CREATION_CODE - stable across builds
    function _ensureBaoFactoryProduction() internal returns (address proxy) {
        return
            _ensureBaoFactoryWithConfig(
                BaoFactoryBytecode.PRODUCTION_CREATION_CODE,
                BaoFactoryLib.PRODUCTION_SALT,
                BaoFactoryLib.PRODUCTION_OWNER
            );
    }

    /// @notice Deploy BaoFactory with explicit configuration
    /// @param creationCode The BaoFactory creation code
    /// @param factorySalt The salt string for Nick's Factory
    /// @param expectedOwner The expected owner address to verify
    function _ensureBaoFactoryWithConfig(
        bytes memory creationCode,
        string memory factorySalt,
        address expectedOwner
    ) internal returns (address proxy) {
        // Check Nick's Factory is available
        require(_NICKS_FACTORY.code.length > 0, "Nick's factory must be installed on this chain");

        bytes32 creationCodeHash = keccak256(creationCode);
        address implementation = BaoFactoryLib.predictImplementation(factorySalt, creationCodeHash);
        proxy = BaoFactoryLib.predictProxy(implementation);

        // If implementation doesn't exist, deploy it (which also deploys the proxy)
        if (implementation.code.length == 0) {
            bytes32 salt = keccak256(bytes(factorySalt));

            /// @solidity memory-safe-assembly
            assembly {
                let codeLength := mload(creationCode)
                mstore(creationCode, salt)
                if iszero(call(gas(), _NICKS_FACTORY, 0, creationCode, add(codeLength, 0x20), 0x00, 0x20)) {
                    returndatacopy(creationCode, 0x00, returndatasize())
                    revert(creationCode, returndatasize())
                }
                mstore(creationCode, codeLength)
            }

            require(implementation.code.length > 0, "BaoFactory implementation deployment failed");
            require(proxy.code.length > 0, "BaoFactory proxy deployment failed");
        }

        // Verify the proxy has expected runtime code (Solady ERC1967 proxy - 61 bytes)
        bytes32 expectedProxyCodeHash = LibClone.ERC1967_CODE_HASH;
        bytes32 actualProxyCodeHash;
        assembly {
            actualProxyCodeHash := extcodehash(proxy)
        }
        if (actualProxyCodeHash != expectedProxyCodeHash) {
            revert BaoFactoryProxyCodeMismatch(expectedProxyCodeHash, actualProxyCodeHash);
        }

        // Verify the factory is functioning and has correct owner
        try BaoFactory(proxy).owner() returns (address currentOwner) {
            if (currentOwner != expectedOwner) {
                revert BaoFactoryOwnerMismatch(expectedOwner, currentOwner);
            }
        } catch {
            revert BaoFactoryProbeFailed();
        }
    }
}
