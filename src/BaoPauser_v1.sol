// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {BaoFixedOwnable} from "@bao/BaoFixedOwnable.sol";

/**
 * @title BaoPauser
 * @author rootminus0x1
 * @notice A minimal upgradeable contract with no functionality beyond upgradeability and ownership.
 * @dev Uses BaoFixedOwnable with hardcoded owner (Harbor multisig), no constructor args.
 *
 * The ownership is fixed to the Harbor multisig with no delay.
 *
 * Use cases:
 * 1) Emergency pause: All functionality is disabled when the proxy points to this implementation.
 *    Upgrade the proxy to this contract to "pause" and upgrade back to restore functionality.
 *
 * 2) Compromised owner recovery: If the owner of a previous contract is compromised but not disabled,
 *    the BaoPauser can be owned by the DAO multisig. Note: the BaoPauser cannot be installed
 *    unless the existing owner authorizes the upgrade.
 *
 * Note: Deployment protection (previously a use case for Stem_v1) is now handled via
 * pendingOwner pattern in BaoOwnable - not needed here.
 *
 * Key properties:
 * - Uses BaoFixedOwnable with (address(0), HARBOR_MULTISIG, 0) - immediate ownership to DAO
 * - No constructor parameters - deterministic bytecode for CREATE2/CREATE3
 * - Can be deployed via BaoFactory at a deterministic address
 */
// solhint-disable-next-line contract-name-capwords
contract BaoPauser_v1 is UUPSUpgradeable, BaoFixedOwnable, IERC5313 {
    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Harbor multisig address - hardcoded for deterministic deployment
    address private constant _OWNER = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;

    /*//////////////////////////////////////////////////////////////////////////
                                    ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev All calls (including ether transfers) revert with this error
    error Paused(string message);

    /*//////////////////////////////////////////////////////////////////////////
                                  CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Deploy the pauser with fixed ownership to Harbor multisig
    /// @dev No parameters - deterministic bytecode for CREATE3 deployment
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() BaoFixedOwnable(address(0), _OWNER, 0) {}

    /*//////////////////////////////////////////////////////////////////////////
                                  PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IERC5313
    function owner() public view virtual override(BaoFixedOwnable, IERC5313) returns (address owner_) {
        owner_ = BaoFixedOwnable.owner();
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC5313).interfaceId || super.supportsInterface(interfaceId);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Authorize upgrades - only owner can upgrade
    /// @param newImplementation Address of the new implementation
    /// @dev This is the only way to "unpause" - upgrade to a functional implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

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
