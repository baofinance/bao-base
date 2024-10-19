// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ContextUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import { ERC165Upgradeable } from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Ownable } from "@solady/auth/Ownable.sol";

import { IOwnable } from "@bao/interfaces/IOwnable.sol";

/// @title Bao Ownable
/// @notice A thin layer over Solady's Ownable that constrains the use of one-step ownership transfers:
/// Only the deployer of the contract can perform a one-step ownership transfer and then
///   * only once and
///   * only if they have been set as owner on initialisation
/// This simplifies deploy scripts that must do owner type set-up but then can transfer to the real owner once done
/// it also adds IRC165 interface query support
/// @author rootminus0x1
/// @dev Uses erc7201 storage
abstract contract BaoOwnable is
    Ownable,
    ContextUpgradeable, // for _msgSender
    ERC165Upgradeable
{
    /*//////////////////////////////////////////////////////////////////////////
                               CONSTRUCTOR/INITIALIZER
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice initialise the UUPS proxy
    /// @param owner sets the owner, a privileged address, of the contract. Cannot be address(0)
    function _initializeOwner(address owner) internal virtual override(Ownable) {
        if (owner == address(0)) revert Ownable.NewOwnerIsZeroAddress();
        if (_msgSender() == owner) {
            // record the deployer to let them have a one-off ownership transfer from them
            BaoOwnableStorage storage $ = _getBaoOwnableStorage();
            $.deployer = _msgSender();
        }
        Ownable._initializeOwner(owner);
        // TODO: consult the OZ docs for what to do in this situation
        // __ERC165_init_unchained();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IOwnable).interfaceId || super.supportsInterface(interfaceId);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  PROTECTED FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice transfers the ownership to a 'newOwner' in a one-step procedure
    /// Can only be called once and then only by the deployer, who is also the (temporary) owner
    /// @param newOwner The address of the new owner. Cannot be address(0).
    function transferOwnership(address newOwner) public payable virtual override(Ownable) {
        BaoOwnableStorage storage $ = _getBaoOwnableStorage();
        // only the deployer gets to call this
        if (_msgSender() != $.deployer) {
            revert Unauthorized();
        }
        // prevent deployer ever calling this again
        $.deployer = address(0);
        Ownable.transferOwnership(newOwner);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  INTERNAL STORAGE
    //////////////////////////////////////////////////////////////////////////*/
    // Share-with-proxy Storage
    // ------------------------
    /// @custom:storage-location erc7201:bao.storage.BaoOwnable
    struct BaoOwnableStorage {
        /// @notice The address of the deployer, held temporarily
        address deployer;
    }

    /// @dev The storage location
    /// keccak256(abi.encode(uint256(keccak256("bao.storage.BaoOwnable")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant _BAOOWNABLE_STORAGE = 0x59cf29b27f24826ae9fd6bd13c85d379cab6c4e2021e5918ac72a561faa28100;

    /*//////////////////////////////////////////////////////////////////////////
                                  INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Retrieves a reference to the contract's storage structure
    /// @return $ A storage reference to the SBaoSynthStorage struct
    function _getBaoOwnableStorage() private pure returns (BaoOwnableStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _BAOOWNABLE_STORAGE
        }
    }

    /// @dev Override to return true to make `_initializeOwner` prevent double-initialization.
    /// This could happen, for example, in normal function call and not just in the initializer
    function _guardInitializeOwner() internal pure virtual override(Ownable) returns (bool guard) {
        guard = true;
    }
}
