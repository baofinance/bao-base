// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title BaoTest
/// @notice Shared test utilities for Harbor Foundry suites
/// @dev Provides pytest-style approximate assertions with absolute and optional relative tolerances
abstract contract BaoTest is Test {
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
}
