// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {IDeploymentDataWritable} from "@bao-script/deployment/interfaces/IDeploymentDataWritable.sol";
import {Create3CommitFlow} from "@bao-script/deployment/Create3CommitFlow.sol";

/**
 * @title DeploymentTestingEnablers
 * @notice Testing-only layer that re-exposes setters and specialty helpers
 * @dev Extends Deployment so production harnesses can avoid the expanded surface
 */
abstract contract DeploymentTestingEnablers is Deployment, IDeploymentDataWritable {
    // ============ Scalar Setters ============

    function setAddress(string memory key, address value) public virtual override {
        _setAddress(key, value);
    }

    function setString(string memory key, string memory value) public virtual override {
        _setString(key, value);
    }

    function setUint(string memory key, uint256 value) public virtual override {
        _setUint(key, value);
    }

    function setInt(string memory key, int256 value) public virtual override {
        _setInt(key, value);
    }

    function setBool(string memory key, bool value) public virtual override {
        _setBool(key, value);
    }

    // ============ Array Setters ============

    function setAddressArray(string memory key, address[] memory values) public virtual override {
        _setAddressArray(key, values);
    }

    function setStringArray(string memory key, string[] memory values) public virtual override {
        _setStringArray(key, values);
    }

    function setUintArray(string memory key, uint256[] memory values) public virtual override {
        _setUintArray(key, values);
    }

    function setIntArray(string memory key, int256[] memory values) public virtual override {
        _setIntArray(key, values);
    }

    function _simulatePredictableDeployWithoutFundingInternal(
        uint256 value,
        string memory key,
        bytes memory initCode
    ) internal returns (address addr) {
        _requireActiveRun();
        if (bytes(key).length == 0) {
            revert KeyRequired();
        }
        if (_has(key)) {
            revert(); // Preserve legacy behavior for tests expecting bare revert
        }

        Create3CommitFlow.Request memory request = Create3CommitFlow.Request({
            operator: address(this),
            systemSaltString: _getString(SYSTEM_SALT_STRING),
            key: key,
            initCode: initCode,
            value: value
        });

        (addr, , ) = Create3CommitFlow.commitAndReveal(request, Create3CommitFlow.RevealMode.ForceZeroValue);
    }
}
