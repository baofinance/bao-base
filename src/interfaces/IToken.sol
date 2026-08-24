// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title IToken
/// @notice The errors a contract can revert with when it uses the `Token` library.
/// @dev A library contributes no ABI of its own, so an error declared only inside `Token` is invisible on the
///      interface of every contract that reverts with it. Callers then have nothing to decode against unless each
///      interface redeclares it, which is how the same error comes to have several homes and drift between them.
///
///      Declaring them here gives one home that a consumer can inherit: an interface whose implementation uses
///      `Token` inherits `IToken`, and the errors appear on that contract's ABI without being copied into it.
///
///      `Token` keeps its own declarations rather than referencing these. It is inlined into contracts that are
///      already deployed and audited, so its source has to stay byte-for-byte reproducible — the errors here are
///      deliberately identical in name and arguments, which makes their selectors identical too, so the two forms
///      are interchangeable to any caller. New code should reach them through this interface.
interface IToken {
    /// @dev Thrown when a zero amount is supplied, or `type(uint256).max` is supplied and the balance is zero.
    error ZeroInputBalance(address token);

    /// @dev Thrown when an address that must be set is the zero address.
    error ZeroAddress();

    /// @dev Thrown when an address that must hold code does not.
    error NotContractAddress(address addr);

    /// @dev Thrown when an address does not answer the ERC-20 calls expected of it.
    error NotERC20Token(address token);
}
