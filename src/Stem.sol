// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/***************************************************************
 *  THIS CODE IS UNDER DEVELOPMENT - DO NOT USE IN PRODUCTION  *
 ***************************************************************/
import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC165} from "@bao/ERC165.sol";
import {BaoCheckOwner_v2} from "@bao/internal/BaoCheckOwner_v2.sol";

/**
 * @title Stem
 * @author rootminus0x1
 * @notice A minimal upgradeable contract with no functionality beyond upgradeability, and ownership.
 * The ownershio is controlled by the BaoCheckOwner_v2 contract, which is in the implementation not the proxy.
 * This means that reinstating a displaced contract will connect back with the previous owner, unless:
 * - its initializer is called with a different owner, or
 * - the replacement contract also has ownersip in the implementation.
 *
 * There are several scenarios where this is usefu:
 * 1) When the contract needs t be paused, i.e. all functionality is disabled, for example in unusual
 *    circumstances, such as a hack or a bug.
 * 2) If the owner of the previous contract is compromised, but not disabled, in some way, the Stem contract
 *    can be owned by any new safe owner, but note that the Stem contract cannot be installed unless by the
 *    existing owner.
 *
 * The deployer becomes the new owner (i.e. is returned from the owner() function) for a given time period,
 * after which the given owner is the new owner.
 */
// solhint-disable-next-line contract-name-camelcase
contract Stem is UUPSUpgradeable, BaoCheckOwner_v2, ERC165, IERC5313 {
    /*//////////////////////////////////////////////////////////////////////////
                                  CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/
    /**
     * @dev Disables initializers for the implementation contract
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address emergencyController,
        uint256 ownerTransferDelay
    ) BaoCheckOwner_v2(emergencyController, ownerTransferDelay) {}

    /*///////////////////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////////////////*/
    /// @dev All calls (including ether transfers) revert with a friendly error
    error Stemmed(string message);

    /*//////////////////////////////////////////////////////////////////////////
                                  PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    // @inheritdoc IBaoOwnable
    function owner() public view virtual returns (address owner_) {
        owner_ = _owner();
    }

    // /// @inheritdoc IERC165
    // function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165) returns (bool) {
    //     // base class doesn't support any interfaces
    //     return interfaceId == type(IBaoOwnable_v2).interfaceId || super.supportsInterface(interfaceId);
    // }

    /*//////////////////////////////////////////////////////////////////////////
                                  INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/
    /**
     * @dev Authorizes the upgrade of this contract to a new implementation
     * @param newImplementation Address of the new implementation
     * Only the owner can upgrade this contract, which is crucial for both usage scenarios:
     * - In initial deployment: The deployer upgrades to the real implementation
     * - In emergency: The trusted owner upgrades to a fixed implementation when ready
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    /**
     * @dev Fallback function to handle all calls to the contract
     * This function is called when no other function matches the call data.
     * It simply reverts with a message indicating that the contract is stemmed.
     */
    // solhint-disable-next-line payable-fallback
    fallback() external {
        revert Stemmed("Contract is stemmed and all functions are disabled");
    }
}
