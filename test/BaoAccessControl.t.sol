// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {BaoOwnableRoles} from "@bao/BaoOwnableRoles.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";

import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";

contract MockBaoAccessControl is BaoOwnableRoles, UUPSUpgradeable {
    uint256 public constant ANOTHER_ROLE = _ROLE_0;
    uint256 public constant ANOTHER_ROLE_ADMIN_ROLE = _ROLE_1;
    uint256 public constant ANOTHER_ROLE2 = _ROLE_2;

    function initialize(address owner) external initializer {
        _initializeOwner(owner);
        __UUPSUpgradeable_init();
    }

    /// @notice In UUPS proxies the constructor is used only to stop the implementation being initialized to any version
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice The check that allow this contract to be upgraded:
    /// only DEFAULT_ADMIN_ROLE grantees, of which there can only be one, can upgrade this contract.
    function _authorizeUpgrade(address) internal virtual override onlyOwner {}
    /*
    function onlyDefault() public {}

    function onlyRole() public {}

    function grantForMulti() public {}
*/
}

contract TestBaoAccessControlSetUp is Test {
    address accessControl;
    address owner;
    address accessControlImpl;

    function setUp() public virtual {
        setUp_impl();
        setUp_owner();
        setUp_proxy();
    }

    function setUp_owner() public virtual {
        owner = vm.createWallet("owner").addr;
    }

    function setUp_impl() internal {
        accessControlImpl = address(new MockBaoAccessControl());
    }

    function setUp_proxy() internal virtual {
        accessControl = UnsafeUpgrades.deployUUPSProxy(
            accessControlImpl,
            abi.encodeCall(MockBaoAccessControl.initialize, (owner))
        );
    }
}

contract TestBaoAccessControlInit is TestBaoAccessControlSetUp {
    function setUp() public override {}

    function test_setUp() public {
        super.setUp();
    }

    // TODO: change all contract tests to test initialisation using this pattern
    function test_initEvents1() public {
        vm.expectEmit();
        emit Initializable.Initialized(type(uint64).max); // from the logic contract constructor
        setUp_impl();
    }

    function test_initEvents2() public {
        setUp_owner();
        setUp_impl();
        vm.expectEmit();
        emit IERC1967.Upgraded(accessControlImpl);
        vm.expectEmit();
        emit Initializable.Initialized(1); // from the proxy delegate call
        setUp_proxy();
    }
}

contract TestBaoAccessControl is TestBaoAccessControlSetUp {
    uint256 anotherRole;
    uint256 anotherRole2;
    uint256 anotherRoleAdminRole;

    function setUp() public override {
        super.setUp();
        anotherRole = MockBaoAccessControl(accessControl).ANOTHER_ROLE();
        anotherRoleAdminRole = MockBaoAccessControl(accessControl).ANOTHER_ROLE_ADMIN_ROLE();
        anotherRole2 = MockBaoAccessControl(accessControl).ANOTHER_ROLE2();
    }

    // TODO: test all the comments in the source file

    function test_init() public {
        assertEq(IBaoOwnable(accessControl).owner(), address(this));
        IBaoOwnable(accessControl).transferOwnership(owner);
        assertEq(IBaoOwnable(accessControl).owner(), owner);
    }

    function test_grantRevoke() public {
        IBaoOwnable(accessControl).transferOwnership(owner);
        // TODO: test revoking a role that isn't held

        // note that anyone can attempt to grant a role
        // can you grant yourself a role - no
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoRoles(accessControl).grantRoles(address(this), anotherRoleAdminRole);

        // but the default admin can
        assertFalse(IBaoRoles(accessControl).hasAnyRole(address(this), anotherRoleAdminRole));
        assertFalse(IBaoRoles(accessControl).hasAllRoles(address(this), anotherRoleAdminRole));
        vm.expectEmit();
        emit IBaoRoles.RolesUpdated(address(this), anotherRoleAdminRole);
        vm.prank(owner);
        IBaoRoles(accessControl).grantRoles(address(this), anotherRoleAdminRole);
        assertTrue(IBaoRoles(accessControl).hasAnyRole(address(this), anotherRoleAdminRole));
        assertTrue(IBaoRoles(accessControl).hasAllRoles(address(this), anotherRoleAdminRole));

        // if we do it twice?
        vm.prank(owner);
        IBaoRoles(accessControl).grantRoles(address(this), anotherRoleAdminRole);
        assertTrue(IBaoRoles(accessControl).hasAnyRole(address(this), anotherRoleAdminRole));
        assertTrue(IBaoRoles(accessControl).hasAllRoles(address(this), anotherRoleAdminRole));

        // TODO: test multiple roles held by one address
        // TODO: revoke roles held
        // TODO: inc role admins
    }

    //////////////////////
    // test security

    function test_transferAdmin() public {
        // TODO: test for renounce role, non-zero, etc
        // TODO: test for a cancel by another startTransfer
    }

    function test_renounceAdmin() public {}
}
