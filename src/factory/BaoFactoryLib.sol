// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/***************************************************************
 *  THIS CODE IS UNDER DEVELOPMENT - DO NOT USE IN PRODUCTION  *
 ***************************************************************/

import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";

/// @title BaoFactoryLib
/// @notice Library for predicting BaoFactory addresses
/// @dev Used by deployment infrastructure to compute deterministic addresses
///
/// Salt format follows namespace storage pattern: "Bao.BaoFactory{Name}.v1"
/// - Production: "Bao.BaoFactory.v1"
/// - Testing:    "Bao.BaoFactoryTesting.v1"
/// - etc.
library BaoFactoryLib {
    /// @notice Nick's Factory address (same on all EVM chains)
    address internal constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice Production BaoFactory salt
    string internal constant PRODUCTION_SALT = "Bao.BaoFactory.v1";

    /// @notice Production BaoFactory owner (Harbor multisig)
    address internal constant PRODUCTION_OWNER = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;

    /// @notice Predict BaoFactory implementation address (CREATE2 via Nick's Factory)
    /// @param factorySalt Salt string (e.g., "Bao.BaoFactory.v1")
    /// @param creationCodeHash keccak256 of BaoFactory creation code
    /// @return implementation The predicted implementation address
    function predictImplementation(
        string memory factorySalt,
        bytes32 creationCodeHash
    ) internal pure returns (address implementation) {
        bytes32 hash = EfficientHashLib.hash(
            abi.encodePacked(bytes1(0xff), NICKS_FACTORY, EfficientHashLib.hash(bytes(factorySalt)), creationCodeHash)
        );
        implementation = address(uint160(uint256(hash)));
    }

    /// @notice Predict BaoFactory proxy address from implementation address
    /// @dev Uses RLP-encoded CREATE formula: keccak256(rlp([sender, nonce]))[12:]
    ///      Implementation deploys proxy as first CREATE (nonce=1)
    /// @param implementation The implementation address that will deploy the proxy
    /// @return proxy The predicted proxy address
    function predictProxy(address implementation) internal pure returns (address proxy) {
        // RLP encoding for [address, 1]: 0xd6 0x94 <20-byte-address> 0x01
        bytes32 hash = EfficientHashLib.hash(
            abi.encodePacked(bytes1(0xd6), bytes1(0x94), implementation, bytes1(0x01))
        );
        proxy = address(uint160(uint256(hash)));
    }

    /// @notice Predict both implementation and proxy addresses
    /// @param factorySalt Salt string (e.g., "Bao.BaoFactory.v1")
    /// @param implCreationCodeHash keccak256 of BaoFactory creation code
    /// @return implementation The predicted implementation address
    /// @return proxy The predicted proxy address
    function predictAddresses(
        string memory factorySalt,
        bytes32 implCreationCodeHash
    ) internal pure returns (address implementation, address proxy) {
        implementation = predictImplementation(factorySalt, implCreationCodeHash);
        proxy = predictProxy(implementation);
    }
}
