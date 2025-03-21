// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { OwnableRoles } from "@solady/auth/OwnableRoles.sol";

contract SampleOwnableRoles is OwnableRoles, Initializable {
    // TODO: make these pure virtual functions
    uint256 public constant ANOTHER_ROLE = _ROLE_0;
    uint256 public constant ANOTHER_ROLE_ADMIN_ROLE = _ROLE_1;
    uint256 public constant ANOTHER_ROLE2 = _ROLE_2;

    function initialize(address owner) external initializer {
        _initializeOwner(owner);
        //__UUPSUpgradeable_init();
        //__ERC165_init();
    }

    /*
    /// @notice In UUPS proxies the constructor is used only to stop the implementation being initialized to any version
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice The check that allow this contract to be upgraded:
    /// only DEFAULT_ADMIN_ROLE grantees, of which there can only be one, can upgrade this contract.
    function _authorizeUpgrade(address) internal virtual override onlyRole(DEFAULT_ADMIN_ROLE) {}
    */
    /*
    function onlyDefault() public {}

    function onlyRole() public {}

    function grantForMulti() public {}
*/
}

contract TestOwnableRoles is Test {
    // nothing to test for here as this class only overrides solady's ownable class but needs this contract to
    // override correctly
    function setUp() public {}
}
