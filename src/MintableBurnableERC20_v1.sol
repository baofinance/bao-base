// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ERC20BurnableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaoOwnableRoles} from "@bao/BaoOwnableRoles.sol";

import {IMintableRole} from "src/interfaces/IMintableRole.sol";
import {IBurnableRole} from "src/interfaces/IBurnableRole.sol";
import {IMintable} from "@bao/interfaces/IMintable.sol";
import {IBurnable} from "@bao/interfaces/IBurnable.sol";
import {IBurnableFrom} from "@bao/interfaces/IBurnableFrom.sol";

/// @title Mintable Burnable ERC20 token
/// @notice A simple mintable and burnable ERC20 token based on Openzeppelin
/// @author rootminus0x1
/// @dev Uses UUPS proxy, erc7201 storage
/// @custom:oz-upgrades
// slither-disable-next-line unimplemented-functions
// solhint-disable-next-line contract-name-capwords
contract MintableBurnableERC20_v1 is
    Initializable,
    UUPSUpgradeable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    ERC20BurnableUpgradeable,
    BaoOwnableRoles,
    IMintableRole,
    IBurnableRole,
    IMintable,
    IBurnable,
    IBurnableFrom
{
    using SafeERC20 for IERC20;
    uint256 public constant MINTER_ROLE = _ROLE_0;
    uint256 public constant BURNER_ROLE = _ROLE_1;

    /// @notice initialise the UUPS proxy
    /// @param owner_ the address the owner is expected to be after a transferOwnership during deploy
    /// @param name_ The name of the ERC20 token
    /// @param symbol_ The symbol of the ERC20 token. This expected to reflect the collateral and pegged token symbols
    function initialize(address owner_, string memory name_, string memory symbol_) public initializer {
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
            interfaceId == type(IMintableRole).interfaceId ||
            interfaceId == type(IBurnableRole).interfaceId ||
            interfaceId == type(IERC20).interfaceId ||
            interfaceId == type(IERC20Metadata).interfaceId ||
            interfaceId == type(IERC20Permit).interfaceId ||
            interfaceId == type(IMintable).interfaceId ||
            interfaceId == type(IBurnable).interfaceId ||
            interfaceId == type(IBurnableFrom).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IMintable
    function mint(address to, uint256 amount) public override onlyRoles(MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @inheritdoc IBurnable
    function burn(uint256 amount) public override(IBurnable, ERC20BurnableUpgradeable) onlyRoles(BURNER_ROLE) {
        super.burn(amount);
    }

    /// @inheritdoc IBurnableFrom
    function burnFrom(
        address from,
        uint256 amount
    ) public override(IBurnableFrom, ERC20BurnableUpgradeable) onlyRoles(BURNER_ROLE) {
        super.burnFrom(from, amount);
    }
}
