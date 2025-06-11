// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title Bao Mintable role
/// @notice Access control for burning
/// @author rootminus0x1

interface IBurnableRole {
    /// @notice returns the role for contracts that can burn this contract
    // solhint-disable-next-line func-name-mixedcase
    function BURNER_ROLE() external view returns (uint256);
}
