// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {HarborUpgradeable_v1} from "@bao/HarborUpgradeable_v1.sol";
import {IHarborFixedOwnable} from "@bao/interfaces/IHarborFixedOwnable.sol";

/// @notice Second implementation for upgrade testing.
contract HarborUpgradeable_v1b is HarborUpgradeable_v1 {
    uint256 public version;

    function setVersion(uint256 v) external {
        version = v;
    }
}

contract HarborUpgradeableTest is BaoTest {
    HarborUpgradeable_v1 internal impl;
    HarborUpgradeable_v1 internal proxy;

    function setUp() public {
        impl = new HarborUpgradeable_v1();
        proxy = HarborUpgradeable_v1(
            address(new ERC1967Proxy(address(impl), ""))
        );
    }

    // ========== Ownership ==========

    function test_owner_isHarborMultisig() public view {
        assertEq(proxy.owner(), HARBOR_MULTISIG);
    }

    function test_owner_implAlsoReturnsMultisig() public view {
        assertEq(impl.owner(), HARBOR_MULTISIG);
    }

    // ========== IERC5313 ==========

    function test_supportsInterface_IERC5313() public view {
        assertTrue(proxy.supportsInterface(type(IERC5313).interfaceId));
    }

    function test_supportsInterface_IERC165() public view {
        assertTrue(proxy.supportsInterface(type(IERC165).interfaceId));
    }

    function test_supportsInterface_IHarborFixedOwnable() public view {
        assertTrue(proxy.supportsInterface(type(IHarborFixedOwnable).interfaceId));
    }

    function test_supportsInterface_randomId_false() public view {
        assertFalse(proxy.supportsInterface(0xdeadbeef));
    }

    // ========== Upgrade Authorization ==========

    function test_upgrade_onlyOwner() public {
        HarborUpgradeable_v1b newImpl = new HarborUpgradeable_v1b();

        vm.prank(HARBOR_MULTISIG);
        proxy.upgradeToAndCall(address(newImpl), "");

        // Verify upgrade worked
        HarborUpgradeable_v1b upgraded = HarborUpgradeable_v1b(address(proxy));
        upgraded.setVersion(42);
        assertEq(upgraded.version(), 42);
    }

    function test_upgrade_reverts_notOwner() public {
        HarborUpgradeable_v1b newImpl = new HarborUpgradeable_v1b();

        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert(IHarborFixedOwnable.Unauthorized.selector);
        proxy.upgradeToAndCall(address(newImpl), "");
    }

}
