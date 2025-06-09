// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title Bao Mintable role
/// @notice Access control for minting
/// @author rootminus0x1

interface IMintableRole {
    /// @notice returns the role for contracts tht can mint this contract
    // solhint-disable-next-line func-name-mixedcase
    function MINTER_ROLE() external view returns (uint256);
}
