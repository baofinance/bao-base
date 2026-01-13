// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {DeploymentBase, WellKnownAddress} from "@bao-script/deployment/DeploymentBase.sol";

/// @notice Concrete implementation of DeploymentBase for testing.
contract TestableDeploymentBase is DeploymentBase {
    address private _treasuryAddr;
    address private _ownerAddr;

    constructor(address treasury_, address owner_) {
        _treasuryAddr = treasury_;
        _ownerAddr = owner_;
    }

    function treasury() public view override returns (address) {
        return _treasuryAddr;
    }

    function owner() public view override returns (address) {
        return _ownerAddr;
    }

    /// @notice Expose internal _setSaltPrefix for testing.
    function setSaltPrefix(string memory prefix) external {
        _setSaltPrefix(prefix);
    }
}

contract DeploymentBaseTest is Test {
    TestableDeploymentBase internal base;
    address internal testTreasury;
    address internal testOwner;

    function setUp() public {
        testTreasury = makeAddr("treasury");
        testOwner = makeAddr("owner");
        base = new TestableDeploymentBase(testTreasury, testOwner);
    }

    function test_initialSaltPrefixIsEmpty() public view {
        assertEq(base.saltPrefix(), "", "saltPrefix starts empty");
    }

    function test_setSaltPrefix() public {
        base.setSaltPrefix("test_v1");
        assertEq(base.saltPrefix(), "test_v1", "saltPrefix set correctly");
    }

    function test_setSaltPrefixCanBeOverwritten() public {
        base.setSaltPrefix("first");
        base.setSaltPrefix("second");
        assertEq(base.saltPrefix(), "second", "saltPrefix can be changed");
    }

    function test_treasury() public view {
        assertEq(base.treasury(), testTreasury, "treasury returns configured address");
    }

    function test_owner() public view {
        assertEq(base.owner(), testOwner, "owner returns configured address");
    }

    function test_baoFactoryDefaultAddress() public view {
        // The default BaoFactory address is a well-known CREATE2 address
        assertEq(base.baoFactory(), 0xD696E56b3A054734d4C6DCBD32E11a278b0EC458, "baoFactory returns default address");
    }

    function test_getWellKnownAddressesContainsExpectedEntries() public view {
        WellKnownAddress[] memory addrs = base.getWellKnownAddresses();

        assertEq(addrs.length, 3, "should have 3 well-known addresses");

        assertEq(addrs[0].addr, testTreasury, "first entry is treasury");
        assertEq(addrs[0].label, "treasury", "treasury label correct");

        assertEq(addrs[1].addr, testOwner, "second entry is owner");
        assertEq(addrs[1].label, "owner", "owner label correct");

        assertEq(addrs[2].addr, 0xD696E56b3A054734d4C6DCBD32E11a278b0EC458, "third entry is baoFactory");
        assertEq(addrs[2].label, "baoFactory", "baoFactory label correct");
    }
}
