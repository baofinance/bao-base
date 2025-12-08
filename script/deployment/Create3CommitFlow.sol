// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";

import {BaoFactory} from "@bao-script/deployment/BaoFactory.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";

/// @title Create3CommitFlow
/// @notice Shared CREATE3 commit/reveal helper used by deployment harnesses and unit tests
/// @dev Centralizes salt derivation, commitment hashing, and BaoFactory interaction
library Create3CommitFlow {
    error Create3CommitFlow_InvalidOperator();
    error Create3CommitFlow_SystemSaltMissing();
    error Create3CommitFlow_KeyRequired();
    error Create3CommitFlow_InitCodeMissing();

    /// @notice Mode used to control msg.value forwarded during reveal
    enum RevealMode {
        MatchValue,
        ForceZeroValue
    }

    /// @notice Parameters needed to perform the commit/reveal
    struct Request {
        address operator;
        string systemSaltString;
        string key;
        bytes initCode;
        uint256 value;
    }

    /// @notice Commit a CREATE3 deployment and return derived values
    /// @dev Commits via BaoFactory and exposes the salt/factory for callers that only need the commit leg
    function commitOnly(
        Request memory req
    ) internal returns (bytes32 salt, bytes32 commitment, address factory, BaoFactory deployer) {
        _validateRequest(req);
        salt = _deriveContractSalt(req.systemSaltString, req.key);
        factory = DeploymentInfrastructure.predictBaoFactoryAddress();
        deployer = BaoFactory(factory);
        bytes32 initCodeHash = keccak256(req.initCode);
        commitment = DeploymentInfrastructure.commitment(req.operator, req.value, salt, initCodeHash);
        deployer.commit(commitment);
    }

    /// @notice Commit and reveal a CREATE3 deployment
    /// @dev RevealMode.ForceZeroValue allows tests to simulate underfunded reveals
    function commitAndReveal(
        Request memory req,
        RevealMode mode
    ) internal returns (address deployed, bytes32 salt, address factory) {
        BaoFactory deployer;
        (salt, , factory, deployer) = commitOnly(req);
        uint256 revealValue = mode == RevealMode.MatchValue ? req.value : 0;
        deployed = deployer.reveal{value: revealValue}(req.initCode, salt, req.value);
    }

    function _validateRequest(Request memory req) private pure {
        if (req.operator == address(0)) revert Create3CommitFlow_InvalidOperator();
        if (bytes(req.systemSaltString).length == 0) revert Create3CommitFlow_SystemSaltMissing();
        if (bytes(req.key).length == 0) revert Create3CommitFlow_KeyRequired();
        if (req.initCode.length == 0) revert Create3CommitFlow_InitCodeMissing();
    }

    function _deriveContractSalt(string memory systemSaltString, string memory key) private pure returns (bytes32) {
        return EfficientHashLib.hash(abi.encodePacked(systemSaltString, "/", key, "/contract"));
    }
}
