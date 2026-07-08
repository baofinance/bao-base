// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {LibString} from "@solady/utils/LibString.sol";

import {BaoFactoryTestLib} from "@bao-test/BaoFactoryTestLib.sol";
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

    // ─────────────────────────────────────────────────────────────────────────
    // Approximate comparators (abs OR rel). `assertApprox` passes when the actual
    // value is within the *larger* of the absolute tolerance and the relative
    // tolerance (rel scaled so 1e18 == 100%). `isApprox` is the same predicate
    // returning a bool. int256 overloads compare signed values; their relative
    // bound is taken against the larger magnitude. On failure the message names
    // both components — `max delta = max(abs A, rel R) wei` — before forge's own
    // `a !~= b (max delta …, real delta …)` suffix, so neither budget is hidden.
    // ─────────────────────────────────────────────────────────────────────────

    function isApprox(uint256 actual, uint256 expected, uint256 absTolerance) internal pure returns (bool) {
        return isApprox(actual, expected, absTolerance, 0);
    }

    function isApprox(
        uint256 actual,
        uint256 expected,
        uint256 absTolerance,
        uint256 relTolerance
    ) internal pure returns (bool) {
        (uint256 effectiveTolerance, ) = _effectiveTolerance(actual, expected, absTolerance, relTolerance);
        uint256 diff = actual > expected ? actual - expected : expected - actual;
        return diff <= effectiveTolerance;
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

    function assertApprox(int256 actual, int256 expected, uint256 absTolerance, string memory message) internal pure {
        _assertApprox(actual, expected, absTolerance, 0, message);
    }

    function assertApprox(
        int256 actual,
        int256 expected,
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
        (uint256 effectiveTolerance, uint256 relBound) = _effectiveTolerance(
            actual,
            expected,
            absTolerance,
            relTolerance
        );
        assertApproxEqAbs(actual, expected, effectiveTolerance, _toleranceMemo(message, absTolerance, relBound));
    }

    function _assertApprox(
        int256 actual,
        int256 expected,
        uint256 absTolerance,
        uint256 relTolerance,
        string memory message
    ) private pure {
        (uint256 effectiveTolerance, uint256 relBound) = _effectiveTolerance(
            SignedMath.abs(actual),
            SignedMath.abs(expected),
            absTolerance,
            relTolerance
        );
        assertApproxEqAbs(actual, expected, effectiveTolerance, _toleranceMemo(message, absTolerance, relBound));
    }

    /// @dev The effective tolerance is the larger of the absolute floor and the relative bound; `relBound`
    ///      is returned separately so the failure message can name each component.
    function _effectiveTolerance(
        uint256 actualMagnitude,
        uint256 expectedMagnitude,
        uint256 absTolerance,
        uint256 relTolerance
    ) private pure returns (uint256 effectiveTolerance, uint256 relBound) {
        if (relTolerance > 0) {
            uint256 maxMagnitude = actualMagnitude > expectedMagnitude ? actualMagnitude : expectedMagnitude;
            if (maxMagnitude > 0) {
                relBound = Math.mulDiv(maxMagnitude, relTolerance, RELATIVE_TOLERANCE_SCALE, Math.Rounding.Ceil);
            }
        }
        effectiveTolerance = absTolerance > relBound ? absTolerance : relBound;
    }

    /// @dev Prefixes the caller's message with the tolerance breakdown; forge appends the actual/expected
    ///      delta after this, so a failure reads e.g. "memo (max delta = max(abs 2, rel 1) wei): 100 !~= 98 …".
    function _toleranceMemo(
        string memory message,
        uint256 absTolerance,
        uint256 relBound
    ) private pure returns (string memory) {
        return
            string.concat(
                message,
                " (max delta = max(abs ",
                LibString.toString(absTolerance),
                ", rel ",
                LibString.toString(relBound),
                ") wei)"
            );
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

    /// @notice Asserts a tolerance both ADMITS the correct value and REJECTS a specific wrong one — so the
    ///         tolerance is shown to discriminate, not merely to pass. `actual` must be within `absTolerance` of
    ///         `expected` (as `assertApprox`), and `wrongValue` — the value a bug would produce (e.g. the ceil
    ///         where the code floors, or a deviation just past a conservation dust cliff) — must be OUTSIDE it.
    ///         This turns a one-off "seed a bug, confirm the test flips" mutation-check into a continuous, every-run
    ///         guarantee that the bound stays tight enough to catch that bug (and can't be silently widened past it).
    /// @param actual The value produced by the code under test.
    /// @param expected The independently-derived correct value.
    /// @param absTolerance The tolerance being asserted (the derived rounding bound).
    /// @param wrongValue A value a real bug would produce; must fall outside `absTolerance` of `expected`.
    /// @param memo A label prefixed to the failure message.
    function assertDiscriminates(
        uint256 actual,
        uint256 expected,
        uint256 absTolerance,
        uint256 wrongValue,
        string memory memo
    ) internal pure {
        assertApprox(actual, expected, absTolerance, memo);
        assertFalse(
            isApprox(wrongValue, expected, absTolerance),
            string.concat(memo, ": tolerance too loose to reject the wrong value")
        );
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
        return BaoFactoryTestLib.ensureBaoFactory();
    }
}
