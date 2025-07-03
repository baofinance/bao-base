// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaoOwnableRoles} from "@bao/BaoOwnableRoles.sol";

import {console2} from "forge-std/console2.sol";

/// @title Mintable Burnable ERC20 token
/// @notice A simple mintable and burnable ERC20 token based on Openzeppelin
/// @author rootminus0x1
/// @dev Uses UUPS proxy, erc7201 storage
/// @custom:oz-upgrades
// slither-disable-next-line unimplemented-functions
// solhint-disable-next-line contract-name-capwords
contract PermittableERC20_v1 is
    Initializable,
    UUPSUpgradeable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    BaoOwnableRoles
{
    using SafeERC20 for IERC20;

    /// @notice initialise the UUPS proxy
    /// @param owner_ the address the owner is expected to be after a transferOwnership during deploy
    /// @param name_ The name of the ERC20 token
    /// @param symbol_ The symbol of the ERC20 token. This expected to reflect the collateral and pegged token symbols
    function initialize(address owner_, string memory name_, string memory symbol_) public initializer {
        console2.log("PermittableERC20_v1.Initialize");
        __PermittableERC20_init(owner_, name_, symbol_);
    }

    function __PermittableERC20_init(
        address owner_,
        string memory name_,
        string memory symbol_
    ) internal onlyInitializing {
        console2.log("__PermittableERC20_init");
        _initializeOwner(owner_);
        __UUPSUpgradeable_init();
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
    }

    /// @notice In UUPS proxies the constructor is used only to stop the implementation being initialized to any version
    /// https://forum.openzeppelin.com/t/what-does-disableinitializers-function-mean/28730
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice The check that allow this contract to be upgraded:
    /// In UUPS proxies the implementation is responsible for upgrading itself
    /// only owners can upgrade this contract.
    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    //TODO: @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(IERC20).interfaceId ||
            interfaceId == type(IERC20Metadata).interfaceId ||
            interfaceId == type(IERC20Permit).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
