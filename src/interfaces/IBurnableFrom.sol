// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IBurnableFrom {
    /*//////////////////////////////////////////////////////////////
                        PUBLIC UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Burn some token from someone.
    /// @param from The address of owner to burn.
    /// @param amount The amount of token to burn.
    function burnFrom(address from, uint256 amount) external;
}
