// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IMintable {
    /*//////////////////////////////////////////////////////////////////////////
                              PUBLIC UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Mint some token to someone.
    /// @param to The address of recipient.
    /// @param amount The amount of token to mint.
    function mint(address to, uint256 amount) external;
}
