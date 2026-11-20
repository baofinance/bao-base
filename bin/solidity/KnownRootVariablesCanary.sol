// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

/// @notice A canary: two root variables, which bin/validate builds with every project it checks.
/// @dev validate lists each contract's root variables from the storage layouts in its build-info, and forge leaves
/// out a layout that would be empty. So a build in which forge wrote no layouts would make every contract look free
/// of root variables. `storage-successor --list-root-storage --known-root-variables` names this contract, refuses a
/// build that lists no root variables for it, and leaves its own out of the listing.
contract KnownRootVariablesCanary {
    uint256 internal first;
    address internal second;
}
