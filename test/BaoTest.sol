// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaoFactoryDeployment} from "@bao-factory/BaoFactoryDeployment.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {UUPSProxyDeployStub} from "@bao-script/deployment/UUPSProxyDeployStub.sol";

/// @title BaoTest
/// @notice Shared test utilities for Harbor Foundry suites
/// @dev Provides pytest-style approximate assertions with absolute and optional relative tolerances
abstract contract BaoTest is Test {
    address internal constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    /// @notice Harbor multisig address - hardcoded for deterministic deployment
    address internal constant HARBOR_MULTISIG = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;

    constructor() {
        vm.label(NICKS_FACTORY, "NicksFactory");
        vm.label(HARBOR_MULTISIG, "HarborMultisig");
    }

    // Matches forge's assertApproxEqRel scaling: 1e18 == 100% relative tolerance.
    uint256 private constant RELATIVE_TOLERANCE_SCALE = 1e18;

    function isApprox(uint256 actual, uint256 expected, uint256 absTolerance) internal pure returns (bool) {
        return isApprox(actual, expected, absTolerance, 0);
    }

    function isApprox(
        uint256 actual,
        uint256 expected,
        uint256 absTolerance,
        uint256 relTolerance
    ) internal pure returns (bool) {
        uint256 effectiveTolerance = _effectiveTolerance(actual, expected, absTolerance, relTolerance);

        if (actual > expected) {
            return (actual - expected) <= effectiveTolerance;
        }
        return (expected - actual) <= effectiveTolerance;
    }

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
        uint256 effectiveTolerance = _effectiveTolerance(actual, expected, absTolerance, relTolerance);

        if (bytes(message).length == 0) {
            assertApproxEqAbs(actual, expected, effectiveTolerance);
        } else {
            assertApproxEqAbs(actual, expected, effectiveTolerance, message);
        }
    }

    function _effectiveTolerance(
        uint256 actual,
        uint256 expected,
        uint256 absTolerance,
        uint256 relTolerance
    ) private pure returns (uint256 effectiveTolerance) {
        effectiveTolerance = absTolerance;

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
    }

    /// @notice Asserts a set of parts conserves a whole, leaving only bounded rounding dust.
    /// @dev One-sided and directional, unlike the symmetric `assertApprox` window: the sum of
    ///      `parts` must never exceed `whole` (no value is created), and the shortfall
    ///      `whole - Σparts` must not exceed `maxDustWei` (no value is lost beyond the stated
    ///      rounding bound). A conserving system rounds strictly in the whole's favour, so an
    ///      overshoot is always a failure, never tolerated as dust. `maxDustWei` is the caller's
    ///      analytically-derived bound (typically 1 wei per truncating division that feeds a part).
    /// @param parts The components that should sum to (just under) `whole`.
    /// @param whole The conserved total the parts are drawn from.
    /// @param maxDustWei The maximum permitted shortfall `whole - Σparts`, derived from the
    ///        number of truncating divisions in the computation of the parts.
    /// @param memo A label prefixed to the failure message identifying the conservation being checked.
    function assertConserved(
        uint256[] memory parts,
        uint256 whole,
        uint256 maxDustWei,
        string memory memo
    ) internal pure {
        uint256 sum = 0;
        for (uint256 i = 0; i < parts.length; i++) {
            sum += parts[i];
        }
        assertLe(sum, whole, string.concat(memo, ": parts exceed whole (value created)"));
        assertLe(whole - sum, maxDustWei, string.concat(memo, ": shortfall exceeds dust bound (value lost)"));
    }

    /*//////////////////////////////////////////////////////////////////////////
                              BAOFACTORY SETUP
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Shared stub for UUPS proxy deployment - deployed once and reused
    UUPSProxyDeployStub internal _proxyStub;

    /// @notice Ensure BaoFactory is deployed and functional at its fixed address
    /// @dev Sets up Nick's Factory if needed, deploys BaoFactory proxy, upgrades to v1
    /// @return factory The functional BaoFactory instance
    function _ensureBaoFactory() internal returns (address factory) {
        // Deploy BaoFactory proxy if not present
        if (!BaoFactoryDeployment.isBaoFactoryDeployed()) {
            BaoFactoryDeployment.deployBaoFactory();
        }

        factory = BaoFactoryDeployment.predictBaoFactoryAddress();
        vm.label(factory, "BaoFactory");

        // Upgrade to v1 if not already functional
        if (!BaoFactoryDeployment.isBaoFactoryFunctional()) {
            vm.startPrank(IBaoFactory(factory).owner());
            BaoFactoryDeployment.upgradeBaoFactoryToV1();
            vm.stopPrank();
        }

        // Set this test as operator if not already
        if (!IBaoFactory(factory).isCurrentOperator(address(this))) {
            vm.prank(IBaoFactory(factory).owner());
            IBaoFactory(factory).setOperator(address(this), 365 days);
        }
    }
}
