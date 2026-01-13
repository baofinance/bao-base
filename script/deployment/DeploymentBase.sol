// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice Well-known address entry for address-to-label mapping.
struct WellKnownAddress {
    address addr;
    string label;
}

/// @notice Abstract base for deployment configuration.
/// @dev Provides common deployment infrastructure that can be extended by protocol-specific configs.
/// @dev Protocol configs inherit this and override with their specific addresses.
abstract contract DeploymentBase {
    string private _saltPrefixValue;

    constructor() {}

    /// @notice Set the salt prefix - must be called before any deployment.
    /// @dev Called by scripts before startBroadcast().
    function _setSaltPrefix(string memory saltPrefixString) internal {
        _saltPrefixValue = saltPrefixString;
    }

    /// @notice Get the current salt prefix for deployment namespacing.
    function saltPrefix() public view virtual returns (string memory) {
        return _saltPrefixValue;
    }

    /// @notice Get the treasury address for the protocol.
    /// @dev Override in protocol-specific configs.
    function treasury() public view virtual returns (address);

    /// @notice Get the owner address for deployed contracts.
    /// @dev Override in protocol-specific configs.
    function owner() public view virtual returns (address);

    /// @notice Get the BaoFactory address for CREATE3 deployments.
    /// @dev Override if using a different factory address.
    function baoFactory() public view virtual returns (address) {
        // BaoFactory CREATE2/CREATE3 predicted address (same on all EVM chains)
        return 0xD696E56b3A054734d4C6DCBD32E11a278b0EC458;
    }

    /// @notice Return protocol-level well-known addresses.
    /// @dev Override in protocol configs to add protocol-specific addresses.
    function getWellKnownAddresses() public view virtual returns (WellKnownAddress[] memory addrs) {
        addrs = new WellKnownAddress[](3);
        addrs[0] = WellKnownAddress({addr: treasury(), label: "treasury"});
        addrs[1] = WellKnownAddress({addr: owner(), label: "owner"});
        addrs[2] = WellKnownAddress({addr: baoFactory(), label: "baoFactory"});
    }
}
