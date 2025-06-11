// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

interface IBurnableFrom {
    /*//////////////////////////////////////////////////////////////////////////
                             PROTECTED UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Burns an `amount` of a token held by `from`
    /// @param from The address of the owner of the tokens being burned.
    /// @param amount The amount of tokens burned. At least this amount must be held `from`.
    function burnFrom(address from, uint256 amount) external;
}
