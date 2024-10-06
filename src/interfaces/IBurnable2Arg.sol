// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IBurnable2Arg {
    /*//////////////////////////////////////////////////////////////
                        PUBLIC UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Burn some token from someone.
    /// @param from The address of holder to burn.
    /// @param amount The amount of token to burn.
    function burn(address from, uint256 amount) external;
}
