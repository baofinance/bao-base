// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title UUPSProxyDeployStub
/// @notice Bare-bones UUPS bootstrap contract. The deploying harness becomes the immutable owner.
/// @dev The contract provides only the upgrade surface plus an `owner()` getter. Ownership cannot
///      be transferred or reconfigured.
contract UUPSProxyDeployStub {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error NotOwner();
    error ZeroAddress();
    error UpgradeCallFailed();

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894A13BA1A3210667C828492DB98DCA3E2076CC3735A920A3CA505D382BBC;

    address private immutable _OWNER;

    constructor() {
        address sender = msg.sender;
        if (sender == address(0)) revert ZeroAddress();
        _OWNER = sender;
    }

    // ---------------------------------------------------------------------
    // Ownership view
    // ---------------------------------------------------------------------

    function owner() external view returns (address) {
        return _OWNER;
    }

    // ---------------------------------------------------------------------
    // UUPS surface
    // ---------------------------------------------------------------------

    function upgradeTo(address newImplementation) external {
        _requireOwner();
        _upgradeToAndCall(newImplementation, bytes(""), false);
    }

    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable {
        _requireOwner();
        _upgradeToAndCall(newImplementation, data, true);
    }

    function proxiableUUID() external pure returns (bytes32) {
        return _IMPLEMENTATION_SLOT;
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _requireOwner() internal view {
        if (msg.sender != _OWNER) revert NotOwner();
    }

    function _upgradeToAndCall(address newImplementation, bytes memory data, bool forceCall) private {
        if (newImplementation == address(0)) revert ZeroAddress();
        _setImplementation(newImplementation);

        if (data.length > 0 || forceCall) {
            (bool success, bytes memory returndata) = newImplementation.delegatecall(data);
            if (!success) {
                if (returndata.length == 0) revert UpgradeCallFailed();
                assembly {
                    revert(add(returndata, 32), mload(returndata))
                }
            }
        }
    }

    function _setImplementation(address newImplementation) private {
        bytes32 slot = _IMPLEMENTATION_SLOT;
        assembly {
            sstore(slot, newImplementation)
        }
    }
}
