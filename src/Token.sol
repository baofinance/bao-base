// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// TODO: check OZ address class

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/*
function totalSupply() external view returns (uint256);
function balanceOf(address account) external view returns (uint256);
function transfer(address to, uint256 value) external returns (bool);
function allowance(address owner, address spender) external view returns (uint256);
function approve(address spender, uint256 value) external returns (bool);
function transferFrom(address from, address to, uint256 value) external returns (bool);
*/

// import {DateUtils} from "DateUtils/DateUtils.sol";

// Attribution: string basics stolen from OpenZeppelin

library Token {
    /// @dev thrown when zero collateral is passed in or -1 is passed in and the balance is zero
    error ZeroInputBalance(address token);

    error ZeroAddress();
    error NotContractAddress(address addr);
    error NotERC20Token(address token);

    function allOf(address account, address token, uint256 tokenIn) internal view returns (uint256 actualIn) {
        if (tokenIn == type(uint256).max) {
            actualIn = IERC20(token).balanceOf(account);
        } else {
            actualIn = tokenIn;
        }
        // slither-disable-next-line incorrect-equality
        if (actualIn == 0) {
            revert ZeroInputBalance(token);
        }
    }

    function ensureNonZeroAddress(address that) internal pure {
        if (that == address(0)) revert ZeroAddress();
    }

    function ensureContract(address addr) internal view {
        ensureNonZeroAddress(addr);
        // from https://www.rareskills.io/post/solidity-code-length
        if (addr.code.length == 0) revert NotContractAddress(addr);
    }

    /// @notice Sanity checks the given address for some ERC20 compliance. This does not guaranteed the contract is a valid ERC20 token
    /// @dev Checks if the contract implements some of the basic ERC20 functions by calling them.
    /// @dev It doesn't check for the full ERC20 interface, because that cannot be done reliably on chain since for example:
    ///      * The contract may implement the interface but not respond to the functions correctly
    ///      * Checking mutating functions such as 'approve' is practically impossible to do reliably on chain because a revert can happen for many reasons,
    ///        making it look like the function does not exist when it actually does.
    ///      * Checking for calls, even non-mutating ones, such as 'allowance', as it is takes parameters that we can't be sure won't cause reverts
    ///      but rather ensures that the contract responds, without reverting, to some of the functions.
    // slither-disable-next-line dead-code
    function sanityCheckERC20Token(address addr) internal view {
        ensureContract(addr);
        if (
            // check all the readonly functions that IERC20 supports
            !_hasNonMutatingFunction(addr, abi.encodeWithSelector(IERC20Metadata.name.selector)) ||
            !_hasNonMutatingFunction(addr, abi.encodeWithSelector(IERC20Metadata.symbol.selector)) ||
            !_hasNonMutatingFunction(addr, abi.encodeWithSelector(IERC20Metadata.decimals.selector)) ||
            !_hasNonMutatingFunction(addr, abi.encodeWithSelector(IERC20.totalSupply.selector)) ||
            !_hasNonMutatingFunction(addr, abi.encodeWithSelector(IERC20.balanceOf.selector, address(this)))
        ) {
            revert NotERC20Token(addr);
        }
    }

    // slither-disable-next-line dead-code
    function _hasNonMutatingFunction(address contract_, bytes memory data) internal view returns (bool) {
        // slither-disable-next-line low-level-calls
        (bool success, ) = contract_.staticcall(data);
        return success;
    }

    function hasNonMutatingParameterlessFunction(
        address contract_,
        string memory funcName
    ) external view returns (bool) {
        bytes4 selector = bytes4(keccak256(bytes(string.concat(funcName, "()"))));
        return _hasNonMutatingFunction(contract_, abi.encodeWithSelector(selector));
    }

    /**
     * @notice Checks if a contract contains a function corresponding to a given function selector and then calls it.
     * @dev First performs a low-level `call` to check if the target contract responds to the given selector. If it exists, performs a second `call` to invoke it.
     * @param target The address of the contract to check and call.
     * @param selector The 4-byte function selector (first 4 bytes of the Keccak-256 hash of the function signature).
     * @param calldataParams The encoded calldata to pass when calling the function (excluding the selector).
     * @return success Boolean indicating whether the function call succeeded.
     * @return returnData The data returned from the function call.
     */

    // slither-disable-next-line dead-code
    function callFunction(
        address target,
        bytes4 selector,
        bytes memory calldataParams
    ) internal returns (bool success, bytes memory returnData) {
        // Construct the complete calldata (function selector + function arguments)
        bytes memory callData = abi.encodePacked(selector, calldataParams);
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // Perform the low-level call to the target contract
            let result := call(
                gas(), // Provide all available gas
                target, // Address of the target contract
                0, // No ether value sent
                add(callData, 0x20), // Pointer to calldata (offset by 32 bytes due to ABI encoding)
                mload(callData), // Size of the calldata
                0x00, // No need to preallocate memory for return data
                0x00 // Return data size unknown, will be handled later
            )

            // Set the success variable
            success := result

            // Handle return data
            let returnDataSize := returndatasize()
            returnData := mload(0x40) // Allocate memory for return data
            mstore(0x40, add(returnData, add(returnDataSize, 0x20))) // Adjust free memory pointer
            mstore(returnData, returnDataSize) // Store the size of return data
            returndatacopy(add(returnData, 0x20), 0, returnDataSize) // Copy the return data
        }
    }
}
