// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";

import {DeploymentBase} from "@bao-script/deployment/DeploymentBase.sol";
import {BaoFactory} from "@bao-factory/BaoFactory.sol";
import {BaoFactoryDeployment} from "@bao-factory/BaoFactoryDeployment.sol";

import {Vm} from "forge-std/Vm.sol";

/**
 * @title DeploymentTesting
 * @notice Mixin for test-specific deployment
 * @dev Extends DeploymentBase with:
 *      - access to the underlying data structure for testing
 *      - auto-configuration of BaoFactory operator for testing (via tx.origin prank)
 *      - automatic stub deployment
 *      - uses current build bytecode (not captured) for BaoFactory
 *
 *      This is a mixin - use it with DeploymentJson for JSON-based tests:
 *      contract MyTest is DeploymentJson, DeploymentTesting { ... }
 */
abstract contract DeploymentTesting is DeploymentBase {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function _ensureBaoFactory() internal virtual override returns (address baoFactory) {
        // Use current build bytecode (not captured) so tests work with code changes
        baoFactory = BaoFactoryDeployment.ensureBaoFactoryCurrentBuild();

        // Always reset operator to this harness (handles resume/continue scenarios with different harness instances)
        // Owner is a compile-time constant in BaoFactory
        if (!BaoFactory(baoFactory).isCurrentOperator(address(this))) {
            VM.prank(BaoFactory(baoFactory).owner());
            BaoFactory(baoFactory).setOperator(address(this), 365 days);
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
    /// @dev Calls deploy with msg.value=0 but value parameter != 0, triggering ValueMismatch error
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

        // Compute salt from system salt + key
        string memory systemSaltString = _getString(SYSTEM_SALT_STRING);
        bytes memory saltBytes = abi.encodePacked(systemSaltString, "/", key);
        bytes32 salt = EfficientHashLib.hash(saltBytes);

        // Deploy via CREATE3 with value mismatch (msg.value=0, expected=value)
        address factory = BaoFactoryDeployment.predictBaoFactoryAddress();
        BaoFactory baoFactory = BaoFactory(factory);
        addr = baoFactory.deploy(value, initCode, salt); // Will revert: ValueMismatch(value, 0)
    }
}
