// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {BaoFactory} from "@bao-script/deployment/BaoFactory.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";
import {Create3CommitFlow} from "@bao-script/deployment/Create3CommitFlow.sol";

import {Vm} from "forge-std/Vm.sol";

/**
 * @title DeploymentTesting
 * @notice test-specific deployment
 * @dev Extends base Deployment with:
 *      - access to the underlying data structure for testing
 *      - auto-configuration of BaoFactory operator for testing (via tx.origin prank)
 *      - automatic stub deployment
 */
abstract contract DeploymentTesting is Deployment {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function _ensureBaoFactory() internal virtual override returns (address baoFactory) {
        // Prank tx.origin so new BaoFactory gets operator = address(this)
        VM.startPrank(address(this), address(this));
        baoFactory = super._ensureBaoFactory();
        VM.stopPrank();

        // Always reset operator to this harness (handles resume/continue scenarios with different harness instances)
        if (BaoFactory(baoFactory).operator() != address(this)) {
            VM.prank(DeploymentInfrastructure.BAOMULTISIG);
            BaoFactory(baoFactory).setOperator(address(this));
        }
    }

    /// @notice Start broadcasting transactions
    /// @dev Called by Deployment before blockchain operations
    function _startBroadcast() internal view override returns (address deployer) {
        deployer = address(this);
    }

    /// @notice Stop broadcasting transactions
    /// @dev Called by Deployment after blockchain operations
    function _stopBroadcast() internal override {}

    // ============ Scalar Setters ============

    function set(string memory key, address value) public virtual {
        _set(key, value);
    }

    function setAddress(string memory key, address value) public virtual {
        _setAddress(key, value);
    }

    function setString(string memory key, string memory value) public virtual {
        _setString(key, value);
    }

    function setUint(string memory key, uint256 value) public virtual {
        _setUint(key, value);
    }

    function setInt(string memory key, int256 value) public virtual {
        _setInt(key, value);
    }

    function setBool(string memory key, bool value) public virtual {
        _setBool(key, value);
    }

    // ============ Array Setters ============

    function setAddressArray(string memory key, address[] memory values) public virtual {
        _setAddressArray(key, values);
    }

    function setStringArray(string memory key, string[] memory values) public virtual {
        _setStringArray(key, values);
    }

    function setUintArray(string memory key, uint256[] memory values) public virtual {
        _setUintArray(key, values);
    }

    function setIntArray(string memory key, int256[] memory values) public virtual {
        _setIntArray(key, values);
    }

    /// @notice Simulate predictable deploy without providing the required value (for testing underfunding scenarios)
    /// @dev This commits but calls reveal with value=0, triggering ValueMismatch error
    ///      contractType and contractPath parameters kept for API compatibility but unused
    /// @param value The value required for deployment
    /// @param key The contract key
    /// @param initCode The contract creation bytecode
    /// @return addr The predicted address (will revert before returning)
    function simulatePredictableDeployWithoutFunding(
        uint256 value,
        string memory key,
        bytes memory initCode,
        string memory /* contractType */,
        string memory /* contractPath */
    ) external virtual returns (address addr) {
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
