// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC165} from "@bao/ERC165.sol";
import {BaoCheckOwnerV2} from "@bao/internal/BaoCheckOwnerV2.sol";

/**
 * @title Stem
 * @author rootminus0x1
 * @notice A minimal upgradeable contract with no functionality beyond upgradeability, and ownership.
 * The ownershio is controlled by the BaoCheckOwnerV2 contract, which is in the implementation not the proxy.
 * This means that reinstating a displaced contract will connect back with the previous owner, unless:
 * - its initializer is called with a different owner, or
 * - the replacement contract also has ownersip in the implementation.
 *
 * There are several scenarios where this is usefu:
 * 1) When the contract needs t be paused, i.e. all functionalit is disabled, for example in unusual
 *    circumstances, such as a hack or a bug.
 * 2) If the owner of the previous contract is compromised, but notr disabled, in some way, the Stem contract can take on any owner
 *    but note that the Stem contract cannot be installed unless by the existing owner.
 *
 * The deployer becomes the new owner (i.e. is returned from the owner() function) for a given time period,
 * after which the given owner is the new owner.
 */

contract Stem is UUPSUpgradeable, BaoCheckOwnerV2, ERC165 {
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
    ) BaoCheckOwnerV2(emergencyController, ownerTransferDelay) {}

    /*//////////////////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////////////////*/
    /**
     * @dev Emitted when the contract is stemmed
     * This event is emitted for all calls to the contract, including ether transfers.
     * The selector is the first 4 bytes of the call data, which can be used to identify
     * the function that was called. If no function was called, it will be zero.
     *
     * Note: This event is emitted before reverting, so it can be used for debugging.
     *
     * @param sender The address that called the contract
     * @param value The amount of ether sent with the call
     * @param data The call data
     * @param selector The first 4 bytes of the call data (function selector)
     */
    /// @dev All calls (including ether transfers) revert with a friendly error
    event StemmedContractCalled(address indexed sender, bytes4 indexed selector, bytes data);

    /*///////////////////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////////////////*/
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
    //     return interfaceId == type(IBaoOwnableV2).interfaceId || super.supportsInterface(interfaceId);
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
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @dev Fallback function to handle all calls to the contract
     * This function is called when no other function matches the call data.
     * It emits an event and reverts with a message indicating that the contract is stemmed.
     *
     * Note: This function is not payable, so it cannot receive ether directly.
     */

    fallback() external {
        bytes4 selector;
        if (msg.data.length >= 4) {
            selector = bytes4(msg.data[0:4]);
        }
        emit StemmedContractCalled(msg.sender, selector, msg.data); // Set value to 0
        revert Stemmed("Contract is stemmed and all functions are disabled");
    }
}
