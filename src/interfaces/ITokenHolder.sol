// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

interface ITokenHolder {
    /*//////////////////////////////////////////////////////////////////////////
                                       EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice emits when a token has been swept, via the sweep function
    /// @param token the token being swept
    /// @param amount amount of given token swept
    /// @param to address the tokens have been transferred to
    event Swept(address token, uint256 amount, address to);

    /*//////////////////////////////////////////////////////////////////////////
                              PUBLIC UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice transfers tokens owned by this contract to `receiver`
    /// @param token the token being swept
    /// @param amount amount of given token swept
    /// @param receiver address the tokens have been transferred to
    function sweep(address token, uint256 amount, address receiver) external;
}
