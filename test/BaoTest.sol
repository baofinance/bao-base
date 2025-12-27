// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaoFactoryDeployment} from "@bao-factory/BaoFactoryDeployment.sol";
import {BaoFactoryBytecode} from "@bao-factory/BaoFactoryBytecode.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";

/// @title BaoTest
/// @notice Shared test utilities for Harbor Foundry suites
/// @dev Provides pytest-style approximate assertions with absolute and optional relative tolerances
abstract contract BaoTest is Test {
    constructor() {
        vm.label(BaoFactoryBytecode.NICKS_FACTORY, "NicksFactory");
    }

    /// @notice Harbor multisig address - hardcoded for deterministic deployment
    address internal constant HARBOR_MULTISIG = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;

    // Matches forge's assertApproxEqRel scaling: 1e18 == 100% relative tolerance.
    uint256 private constant RELATIVE_TOLERANCE_SCALE = 1e18;

    function assertApprox(uint256 actual, uint256 expected, uint256 absTolerance) internal pure {
        _assertApprox(actual, expected, absTolerance, 0, "");
    }

    function assertApprox(uint256 actual, uint256 expected, uint256 absTolerance, string memory message) internal pure {
        _assertApprox(actual, expected, absTolerance, 0, message);
    }

    function assertApprox(uint256 actual, uint256 expected, uint256 absTolerance, uint256 relTolerance) internal pure {
        _assertApprox(actual, expected, absTolerance, relTolerance, "");
    }

    function assertApprox(
        uint256 actual,
        uint256 expected,
        uint256 absTolerance,
        uint256 relTolerance,
        string memory message
    ) internal pure {
        _assertApprox(actual, expected, absTolerance, relTolerance, message);
    }

    function _assertApprox(
        uint256 actual,
        uint256 expected,
        uint256 absTolerance,
        uint256 relTolerance,
        string memory message
    ) private pure {
        uint256 effectiveTolerance = absTolerance;

        if (relTolerance > 0) {
            uint256 maxMagnitude = actual > expected ? actual : expected;
            if (maxMagnitude > 0) {
                uint256 relBound = Math.mulDiv(
                    maxMagnitude,
                    relTolerance,
                    RELATIVE_TOLERANCE_SCALE,
                    Math.Rounding.Ceil
                );
                if (relBound > effectiveTolerance) {
                    effectiveTolerance = relBound;
                }
            }
        }

        if (bytes(message).length == 0) {
            assertApproxEqAbs(actual, expected, effectiveTolerance);
        } else {
            assertApproxEqAbs(actual, expected, effectiveTolerance, message);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                              BAOFACTORY SETUP
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Ensure BaoFactory is deployed and functional at its fixed address
    /// @dev Sets up Nick's Factory if needed, deploys BaoFactory proxy, upgrades to v1
    /// @return factory The functional BaoFactory instance
    function _ensureBaoFactory() internal returns (IBaoFactory factory) {
        // Deploy BaoFactory proxy if not present
        if (!BaoFactoryDeployment.isBaoFactoryDeployed()) {
            BaoFactoryDeployment.deployBaoFactory();
        }

        address factoryAddr = BaoFactoryDeployment.predictBaoFactoryAddress();
        vm.label(factoryAddr, "BaoFactory");

        // Upgrade to v1 if not already functional
        if (!BaoFactoryDeployment.isBaoFactoryFunctional()) {
            vm.startPrank(IBaoFactory(factoryAddr).owner());
            BaoFactoryDeployment.upgradeBaoFactoryToV1();
            vm.stopPrank();
        }

        factory = IBaoFactory(factoryAddr);

        // Set this test as operator if not already
        if (!factory.isCurrentOperator(address(this))) {
            vm.prank(factory.owner());
            factory.setOperator(address(this), 365 days);
        }
    }
}
