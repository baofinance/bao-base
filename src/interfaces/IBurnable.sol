// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IBurnable {
    /*//////////////////////////////////////////////////////////////////////////
                             PRTECTED UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Burn some token held by the caller.
    /// @param amount The amount of tokens burned. At least this amount must be held by the caller.
    function burn(uint256 amount) external;
}
