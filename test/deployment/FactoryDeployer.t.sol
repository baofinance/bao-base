// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {FactoryDeployer, WellKnownAddress} from "@bao-script/deployment/FactoryDeployer.sol";

/// @notice Concrete implementation of FactoryDeployer for testing.
contract TestableFactoryDeployer is FactoryDeployer {
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

contract FactoryDeployerTest is Test {
    TestableFactoryDeployer internal deployer;
    address internal testTreasury;
    address internal testOwner;

    function setUp() public {
        testTreasury = makeAddr("treasury");
        testOwner = makeAddr("owner");
        deployer = new TestableFactoryDeployer(testTreasury, testOwner);
    }

    function test_initialSaltPrefixIsEmpty() public view {
        assertEq(deployer.saltPrefix(), "", "saltPrefix starts empty");
    }

    function test_setSaltPrefix() public {
        deployer.setSaltPrefix("test_v1");
        assertEq(deployer.saltPrefix(), "test_v1", "saltPrefix set correctly");
    }

    function test_setSaltPrefixCanBeOverwritten() public {
        deployer.setSaltPrefix("first");
        deployer.setSaltPrefix("second");
        assertEq(deployer.saltPrefix(), "second", "saltPrefix can be changed");
    }

    function test_treasury() public view {
        assertEq(deployer.treasury(), testTreasury, "treasury returns configured address");
    }

    function test_owner() public view {
        assertEq(deployer.owner(), testOwner, "owner returns configured address");
    }

    function test_baoFactoryDefaultAddress() public view {
        // The default BaoFactory address is a well-known CREATE2 address
        assertEq(
            deployer.baoFactory(),
            0xD696E56b3A054734d4C6DCBD32E11a278b0EC458,
            "baoFactory returns default address"
        );
    }

    function test_getWellKnownAddressesContainsExpectedEntries() public view {
        WellKnownAddress[] memory addrs = deployer.getWellKnownAddresses();

        assertEq(addrs.length, 3, "should have 3 well-known addresses");

        assertEq(addrs[0].addr, testTreasury, "first entry is treasury");
        assertEq(addrs[0].label, "treasury", "treasury label correct");

        assertEq(addrs[1].addr, testOwner, "second entry is owner");
        assertEq(addrs[1].label, "owner", "owner label correct");

        assertEq(addrs[2].addr, 0xD696E56b3A054734d4C6DCBD32E11a278b0EC458, "third entry is baoFactory");
        assertEq(addrs[2].label, "baoFactory", "baoFactory label correct");
    }
}
