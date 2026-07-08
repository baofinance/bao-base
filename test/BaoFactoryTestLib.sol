// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {BaoFactoryDeployment} from "@bao-factory/BaoFactoryDeployment.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";

/// @notice Test-side BaoFactory setup shared by `BaoTest` and composable deploy harnesses. Ensures the
///         singleton BaoFactory is deployed + functional, and registers the caller as a factory operator.
///         `ensureBaoFactory` is an `internal` library function, so it inlines into the caller and `address(this)`
///         is whoever calls it — a test contract, or a composed deploy harness that itself calls `factory.deploy`
///         and therefore must be an operator — each registering itself. Keeps the `vm`-free
///         `BaoFactoryDeployment` library free of the test's owner-prank authorization.
library BaoFactoryTestLib {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Deploy + upgrade the singleton BaoFactory if needed and register the caller (`address(this)`) as
    ///         a factory operator. Idempotent; returns the factory address.
    function ensureBaoFactory() internal returns (address factory) {
        if (!BaoFactoryDeployment.isBaoFactoryDeployed()) {
            BaoFactoryDeployment.deployBaoFactory();
        }
        factory = BaoFactoryDeployment.predictBaoFactoryAddress();
        vm.label(factory, "BaoFactory");
        if (!BaoFactoryDeployment.isBaoFactoryFunctional()) {
            vm.startPrank(IBaoFactory(factory).owner());
            BaoFactoryDeployment.upgradeBaoFactoryToV1();
            vm.stopPrank();
        }
        if (!IBaoFactory(factory).isCurrentOperator(address(this))) {
            vm.prank(IBaoFactory(factory).owner());
            IBaoFactory(factory).setOperator(address(this), 365 days);
        }
    }
}
