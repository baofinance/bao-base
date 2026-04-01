// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {HarborUpgradeable_v1} from "./HarborUpgradeable_v1.sol";

/**
 * @title HarborPauser
 * @author rootminus0x1
 * @notice A minimal upgradeable contract with no functionality beyond upgradeability and ownership.
 * @dev Inherits HarborUpgradeable_v1 and adds a fallback that reverts all calls.
 *
 * Use cases:
 * 1) Emergency pause: All functionality is disabled when the proxy points to this implementation.
 *    Upgrade the proxy to this contract to "pause" and upgrade back to restore functionality.
 *
 * 2) Compromised owner recovery: If the owner of a previous contract is compromised but not disabled,
 *    the HarborPauser can be owned by the DAO multisig. Note: the HarborPauser cannot be installed
 *    unless the existing owner authorizes the upgrade.
 *
 * Key properties:
 * - Inherits HarborUpgradeable_v1: UUPS + HarborFixedOwnable + IERC5313
 * - No constructor parameters - deterministic bytecode for CREATE2/CREATE3
 * - Can be deployed via BaoFactory at a deterministic address
 */
// solhint-disable-next-line contract-name-capwords
contract HarborPauser_v1 is HarborUpgradeable_v1 {
    /*//////////////////////////////////////////////////////////////////////////
                                    ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev All calls (including ether transfers) revert with this error
    error Paused(string message);

    /*//////////////////////////////////////////////////////////////////////////
                                  FALLBACK
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Fallback function - all calls revert with Paused error
    /// @dev This includes ether transfers and any function calls
    // solhint-disable-next-line payable-fallback
    fallback() external {
        revert Paused("Contract is paused and all functions are disabled");
    }
}
