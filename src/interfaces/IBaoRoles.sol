// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

/// @notice Simple single owner and multiroles authorization mixin.
/// @author rootminus0x1 a barefaced copy of Solady (https://github.com/vectorized/solady/blob/main/src/auth/OwnableRoles.sol)
/// Made into an interface and a implementation

interface IBaoRoles {
    /*//////////////////////////////////////////////////////////////////////////
                                       EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev The `user`'s roles is updated to `roles`.
    /// Each bit of `roles` represents whether the role is set.
    event RolesUpdated(address indexed user, uint256 indexed roles);

    /*//////////////////////////////////////////////////////////////////////////
                             PROTECTED UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Allows the owner to grant `user` `roles`.
    /// If the `user` already has a role, then it will be an no-op for the role.
    function grantRoles(address user, uint256 roles) external payable;

    /// @dev Allows the owner to remove `user` `roles`.
    /// If the `user` does not have a role, then it will be an no-op for the role.
    function revokeRoles(address user, uint256 roles) external payable;

    /// @dev Allow the caller to remove their own roles.
    /// If the caller does not have a role, then it will be an no-op for the role.
    function renounceRoles(uint256 roles) external payable;

    /*//////////////////////////////////////////////////////////////////////////
                               PUBLIC READ FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Returns the roles of `user`.
    function rolesOf(address user) external view returns (uint256 roles);

    /// @dev Returns whether `user` has any of `roles`.
    function hasAnyRole(address user, uint256 roles) external view returns (bool);

    /// @dev Returns whether `user` has all of `roles`.
    function hasAllRoles(address user, uint256 roles) external view returns (bool);
}
