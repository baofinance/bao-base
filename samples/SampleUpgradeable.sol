// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";

import {Ownable} from "@solady/auth/Ownable.sol";

contract SampleUpgradeable is Initializable, Ownable, UUPSUpgradeable {
    //------------------------------------------------------------------------------------
    // Storage
    //------------------------------------------------------------------------------------

    // use lib/bao-base/run storage-hash "bao.storage.SampleUpgradeable"
    bytes32 private constant _SAMPLE_UPGRADEABLE = 0x2a0a4f18e92346647b28b178305e236e1a4a051a6459d8e156d492b387236500;

    // the storage layout with the @custom:storage storage location directive
    /// @custom:storage-location erc7201:_SAMPLE_UPGRADEABLE
    struct SampleUpgradeableStorage {
        // put your state storage here, just like you would in a normal contract, e.g.
        uint256 myValue;
    }

    // use this to access the state storage
    // e.g.
    //  SampleUpgradeableStorage $ = _getSampleUpgradeableStorage();
    //  $.myValue = 123;
    function _getSampleUpgradeableStorage() internal pure returns (SampleUpgradeableStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            $.slot := _SAMPLE_UPGRADEABLE
        }
    }

    // ------------------------------------------------------------------------------------
    // initialisation
    // ------------------------------------------------------------------------------------

    function initialize(address owner) external initializer {
        _initializeOwner(owner);
        __UUPSUpgradeable_init();
    }

    /// @notice In UUPS proxies the constructor is used only to stop the implementation being initialized to any version
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    //------------------------------------------------------------------------------------
    // UUPS Upgrade
    //------------------------------------------------------------------------------------

    /// @notice The check that allow this contract to be upgraded:
    /// In UUPS proxies the implementation is responsible for upgrading itself
    /// only owners can upgrade this contract.
    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks
}
