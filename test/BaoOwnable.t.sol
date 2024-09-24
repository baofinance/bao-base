// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { BaoOwnable, Ownable } from "src/BaoOwnable.sol";

contract MockBaoOwnable is BaoOwnable, Initializable {
    function initialize(address owner) external initializer {
        _initializeOwner(owner);
        //__UUPSUpgradeable_init();
        //__ERC165_init();
    }

    function onlyOwnerFunction() public onlyOwner {}

    /*
    /// @notice In UUPS proxies the constructor is used only to stop the implementation being initialized to any version
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
*/
}

contract TestOwnable is Test {
    MockBaoOwnable ownable;

    function setUp() public {
        ownable = new MockBaoOwnable();
    }

    function testUninitialised() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        ownable.onlyOwnerFunction();
    }

    function testBadInitialise() public {
        vm.expectRevert(Ownable.NewOwnerIsZeroAddress.selector);
        ownable.initialize(address(0));
    }

    function testInitialised() public {
        Vm.Wallet memory owner = vm.createWallet("owner");
        vm.expectRevert(Ownable.Unauthorized.selector);
        ownable.onlyOwnerFunction();

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(owner.addr);
        ownable.onlyOwnerFunction();

        assertEq(ownable.owner(), address(0), "owner unset until initialisation");

        ownable.initialize(owner.addr);
        assertEq(ownable.owner(), owner.addr, "owner set on initialisation");
        vm.prank(owner.addr);
        ownable.onlyOwnerFunction();

        Vm.Wallet memory owner2 = vm.createWallet("owner2");
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        ownable.initialize(owner2.addr);
    }
}
