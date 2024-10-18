// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ContextUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import { ERC165Upgradeable } from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Ownable } from "@solady/auth/Ownable.sol";

import { IOwnable } from "@bao/interfaces/IOwnable.sol";

/// @title Bao Ownable
/// @notice A thin layer over Solady's Ownable that constrains the use of one-step ownership transfers
/// it also adds IRC165 interface query support
/// @author rootminus0x1
/// @dev Uses erc7201 storage
abstract contract BaoOwnable is
    Ownable,
    ContextUpgradeable, // for _msgSender
    ERC165Upgradeable
{
    // Share-with-proxy Storage
    // ------------------------
    /// @custom:storage-location erc7201:bao.storage.BaoOwnable
    struct BaoOwnableStorage {
        /// @notice The address of the deployer, held temporarily
        address deployer;
    }

    // keccak256(abi.encode(uint256(keccak256("bao.storage.BaoOwnable")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant _BAOOWNABLE_STORAGE = 0x59cf29b27f24826ae9fd6bd13c85d379cab6c4e2021e5918ac72a561faa28100;

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

    /// @notice initialise the UUPS proxy
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

    function transferOwnership(address newOwner) public payable virtual override(Ownable) {
        BaoOwnableStorage storage $ = _getBaoOwnableStorage();
        if (_msgSender() != $.deployer) {
            revert Unauthorized();
        }
        Ownable.transferOwnership(newOwner);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IOwnable).interfaceId || super.supportsInterface(interfaceId);
    }
}
