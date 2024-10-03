// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IBurnable {
    /*//////////////////////////////////////////////////////////////
                        PUBLIC UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Burn some token held by the caller.
    /// @param amount The amount of token to burn.
    function burn(uint256 amount) external;
}
