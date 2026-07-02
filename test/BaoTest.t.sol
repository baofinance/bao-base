// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";

// ═══════════════════════════════════════════════════════════════
// Unit tests for BaoTest's own conservation assertion.
//
// assertConserved is a one-sided, directional check: the parts may
// never sum to more than the whole (no value created), and the
// shortfall the whole keeps must not exceed the caller's derived
// dust bound (no value lost beyond rounding). These tests prove it
// passes exactly, passes at the dust boundary, and fails on both an
// overshoot and an over-budget shortfall — across 0, 1 and N parts.
// ═══════════════════════════════════════════════════════════════

contract BaoTestAssertConservedTest is BaoTest {
    // External boundary so a failing inner assertion reverts and can be caught with expectRevert.
    function exposed_assertConserved(
        uint256[] memory parts,
        uint256 whole,
        uint256 maxDustWei,
        string memory memo
    ) external pure {
        assertConserved(parts, whole, maxDustWei, memo);
    }

    // Zero parts conserve a zero whole exactly (empty-loop path).
    function test_assertConserved_passesExact_zeroParts() public pure {
        uint256[] memory parts = new uint256[](0);
        assertConserved(parts, 0, 0, "zero");
    }

    // A single part that equals the whole conserves it exactly (one-iteration path).
    function test_assertConserved_passesExact_singlePart() public pure {
        uint256[] memory parts = new uint256[](1);
        parts[0] = 100;
        assertConserved(parts, 100, 0, "single");
    }

    // Three parts short by one wei of rounding are within a 1-wei dust bound (N-iteration path).
    function test_assertConserved_passesWithinDust_multipleParts() public pure {
        uint256[] memory parts = new uint256[](3);
        parts[0] = 33;
        parts[1] = 33;
        parts[2] = 33;
        // 100 split three ways floors to 33 each = 99; the pool keeps the 1 wei remainder.
        assertConserved(parts, 100, 1, "thirds");
    }

    // A shortfall exactly equal to the dust bound passes (boundary is inclusive).
    function test_assertConserved_passesAtDustBoundary() public pure {
        uint256[] memory parts = new uint256[](1);
        parts[0] = 98;
        assertConserved(parts, 100, 2, "boundary");
    }

    // Parts summing above the whole is value creation and always fails, even with a large dust budget.
    function test_assertConserved_revertsWhenPartsExceedWhole() public {
        uint256[] memory parts = new uint256[](2);
        parts[0] = 60;
        parts[1] = 50;
        // vm.assertLe appends ": <sum> > <whole>" to the memo-derived message.
        vm.expectRevert(bytes("overshoot: parts exceed whole (value created): 110 > 100"));
        this.exposed_assertConserved(parts, 100, 100, "overshoot");
    }

    // A shortfall one wei beyond the dust bound is value loss and fails.
    function test_assertConserved_revertsWhenShortfallExceedsDust() public {
        uint256[] memory parts = new uint256[](1);
        parts[0] = 97;
        // shortfall 3 > bound 2; vm.assertLe appends ": <shortfall> > <bound>" to the message.
        vm.expectRevert(bytes("shortfall: shortfall exceeds dust bound (value lost): 3 > 2"));
        this.exposed_assertConserved(parts, 100, 2, "shortfall");
    }
}

// ═══════════════════════════════════════════════════════════════
// Unit tests for BaoTest's approximate comparators (isApprox / assertApprox).
//
// These are the symmetric, two-sided tolerance helpers the numerical
// suites lean on. isApprox returns a bool (|actual - expected| within
// an effective tolerance); assertApprox asserts the same and reverts
// on failure. The effective tolerance is the larger of the absolute
// floor and a relative component scaled so 1e18 == 100%. These tests
// pin that behaviour: pure abs, pure rel, the max() interaction of the
// two, direction symmetry, the inclusive boundary, and zero magnitude.
// ═══════════════════════════════════════════════════════════════

contract BaoTestApproxTest is BaoTest {
    // External boundary so a failing inner assertion reverts and can be caught with expectRevert.
    function exposed_assertApprox(
        uint256 actual,
        uint256 expected,
        uint256 absTolerance,
        uint256 relTolerance,
        string memory message
    ) external pure {
        assertApprox(actual, expected, absTolerance, relTolerance, message);
    }

    // A difference equal to the absolute tolerance is within (boundary inclusive).
    function test_isApprox_withinAbs_true() public pure {
        assertTrue(isApprox(105, 100, 5), "diff 5 within abs 5");
    }

    // A difference one wei beyond the absolute tolerance is out.
    function test_isApprox_beyondAbs_false() public pure {
        assertFalse(isApprox(106, 100, 5), "diff 6 beyond abs 5");
    }

    // The comparison is symmetric: order of actual/expected does not matter.
    function test_isApprox_symmetric() public pure {
        assertTrue(isApprox(105, 100, 5), "actual above");
        assertTrue(isApprox(95, 100, 5), "actual below");
        assertFalse(isApprox(94, 100, 5), "actual below, beyond");
    }

    // The relative component scales as 1e18 == 100%; here 0.5% of ~1000 is ~6 wei.
    function test_isApprox_relToleranceScaling() public pure {
        // maxMag 1005, relBound = ceil(1005 * 5e15 / 1e18) = 6; diff 5 <= 6.
        assertTrue(isApprox(1005, 1000, 0, 5e15), "diff 5 within 0.5%");
        // maxMag 1010, relBound = ceil(1010 * 5e15 / 1e18) = 6; diff 10 > 6.
        assertFalse(isApprox(1010, 1000, 0, 5e15), "diff 10 beyond 0.5%");
    }

    // When the absolute floor exceeds the relative bound, the floor governs.
    function test_isApprox_absFloorGoverns() public pure {
        // rel 0.1% of ~1050 = ceil(1050 * 1e15 / 1e18) = 2; abs floor 100 wins; diff 50 <= 100.
        assertTrue(isApprox(1050, 1000, 100, 1e15), "abs floor admits diff 50");
        // Same inputs with no abs floor fall to the rel bound of 2 and fail.
        assertFalse(isApprox(1050, 1000, 0, 1e15), "rel bound alone rejects diff 50");
    }

    // When the relative bound exceeds the absolute floor, the relative bound governs.
    function test_isApprox_relBoundGoverns() public pure {
        // rel 50% of 140 = 70; abs floor 1; diff 40 <= 70.
        assertTrue(isApprox(140, 100, 1, 5e17), "rel bound admits diff 40");
        // Same inputs with no rel component fall to abs 1 and fail.
        assertFalse(isApprox(140, 100, 1, 0), "abs 1 alone rejects diff 40");
    }

    // With both values zero the relative term is skipped and the absolute floor governs.
    function test_isApprox_zeroMagnitude() public pure {
        assertTrue(isApprox(0, 0, 0, 5e17), "0 vs 0 conserved");
    }

    // assertApprox passes silently when within tolerance. (First arg typed to select the uint256 overload;
    // a bare literal is ambiguous now that a signed overload exists — real call sites pass typed values.)
    function test_assertApprox_passesWithinAbs() public pure {
        assertApprox(uint256(105), 100, 5, "within abs");
    }

    // assertApprox reverts when the difference exceeds the effective tolerance, and the message names both
    // the absolute and relative components before forge's own delta suffix.
    function test_assertApprox_revertsBeyondTolerance() public {
        vm.expectRevert(bytes("beyond (max delta = max(abs 5, rel 0) wei): 106 !~= 100 (max delta: 5, real delta: 6)"));
        this.exposed_assertApprox(106, 100, 5, 0, "beyond");
    }

    // When the relative bound governs, the failure message reports it in wei alongside the absolute floor.
    function test_assertApprox_failureNamesRelComponent() public {
        // rel 50% of the larger magnitude (100) = 50 governs over abs 1; diff 90 exceeds it.
        vm.expectRevert(bytes("rel (max delta = max(abs 1, rel 50) wei): 10 !~= 100 (max delta: 50, real delta: 90)"));
        this.exposed_assertApprox(10, 100, 1, 5e17, "rel");
    }
}

// ═══════════════════════════════════════════════════════════════
// Unit tests for BaoTest's int256 assertApprox overloads.
//
// The signed comparator shares the effective-tolerance logic with the
// uint256 one (relative bound taken against the larger magnitude), and
// carries the same abs/rel failure message. These pin the sign-aware
// behaviour that the harbor Minter conservation checks rely on.
// ═══════════════════════════════════════════════════════════════

contract BaoTestApproxIntTest is BaoTest {
    function exposed_assertApproxInt(
        int256 actual,
        int256 expected,
        uint256 absTolerance,
        uint256 relTolerance,
        string memory message
    ) external pure {
        assertApprox(actual, expected, absTolerance, relTolerance, message);
    }

    // A signed difference within the absolute tolerance passes (straddling zero).
    function test_assertApproxInt_passesWithinAbs() public pure {
        assertApprox(int256(-2), int256(3), 5, "signed diff 5 within abs 5");
    }

    // The relative bound is taken against the larger magnitude, so 50% of 100 admits a diff of 40.
    function test_assertApproxInt_passesWithinRel() public pure {
        assertApprox(int256(-140), int256(-100), 1, 5e17, "signed diff 40 within 50% of 100");
    }

    // A signed difference beyond both tolerances reverts, message naming both components.
    function test_assertApproxInt_revertsBeyondTolerance() public {
        vm.expectRevert(bytes("signed (max delta = max(abs 1, rel 0) wei): -2 !~= 3 (max delta: 1, real delta: 5)"));
        this.exposed_assertApproxInt(-2, 3, 1, 0, "signed");
    }
}

// ═══════════════════════════════════════════════════════════════
// Unit tests for BaoTest's discrimination assertion.
//
// assertDiscriminates proves a tolerance both admits the correct
// value AND rejects a specific wrong one — so the tolerance is shown
// to catch the bug it targets, continuously, not just to pass. It
// fails if the tolerance is loose enough to also admit the wrong value.
// ═══════════════════════════════════════════════════════════════

contract BaoTestDiscriminatesTest is BaoTest {
    function exposed_assertDiscriminates(
        uint256 actual,
        uint256 expected,
        uint256 absTolerance,
        uint256 wrongValue,
        string memory memo
    ) external pure {
        assertDiscriminates(actual, expected, absTolerance, wrongValue, memo);
    }

    // A tight (exact) tolerance admits the correct value and rejects the off-by-one a rounding flip would produce.
    function test_assertDiscriminates_tightBoundPasses() public pure {
        assertDiscriminates(100, 100, 0, 101, "exact rejects ceil");
    }

    // A tolerance that still rejects the wrong value passes (correct within 2, wrong 5 away is outside).
    function test_assertDiscriminates_withToleranceRejectsFarWrong() public pure {
        assertDiscriminates(101, 100, 2, 105, "within 2, rejects 5-away");
    }

    // A tolerance loose enough to also admit the wrong value fails: it cannot discriminate.
    function test_assertDiscriminates_revertsWhenTooLoose() public {
        vm.expectRevert(bytes("loose: tolerance too loose to reject the wrong value"));
        this.exposed_assertDiscriminates(100, 100, 5, 103, "loose");
    }
}
