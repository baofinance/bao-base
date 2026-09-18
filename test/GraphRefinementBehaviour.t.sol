// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {GraphRefinement} from "@bao-test/GraphRefinement.t.sol";

/// @dev A sweep whose signal is supplied by the test, recording which points were probed and which were
///      kept. Nothing is written to a file: what matters here is which samples refinement asks for and
///      in what order.
contract RecordingRefiner is GraphRefinement {
    uint256[] public emitted;
    uint256 public probes;

    uint256 private tolerance;
    uint8 private maxDepth;
    uint256 private minStep;

    /// @dev A step: flat either side of `stepAt`, which no chord can approximate.
    uint256 private stepAt;
    /// @dev A straight line, which every chord approximates exactly.
    bool private straight;

    constructor(uint256 tolerance_, uint8 maxDepth_, uint256 minStep_) {
        tolerance = tolerance_;
        maxDepth = maxDepth_;
        minStep = minStep_;
    }

    function setStepAt(uint256 x) external {
        stepAt = x;
    }

    function setStraight() external {
        straight = true;
    }

    function refinementTolerance() internal view override returns (uint256) {
        return tolerance;
    }

    function refinementMaxDepth() internal view override returns (uint8) {
        return maxDepth;
    }

    function refinementMinStep() internal view override returns (uint256) {
        return minStep;
    }

    function signalAt(uint256 x) public view returns (int256) {
        if (straight) {
            return int256(x);
        }
        return x < stepAt ? int256(0) : int256(1_000_000);
    }

    function probeSignalsAt(uint256 x) internal override returns (int256[] memory signals) {
        probes++;
        signals = new int256[](1);
        signals[0] = signalAt(x);
    }

    function _one(int256 value) private pure returns (int256[] memory boxed) {
        boxed = new int256[](1);
        boxed[0] = value;
    }

    function emitSampleAt(uint256 x) internal override {
        emitted.push(x);
    }

    function refine(uint256 x0, uint256 x1) external {
        refineBetween(x0, _one(signalAt(x0)), x1, _one(signalAt(x1)));
    }

    function refineWithEndSignals(uint256 x0, int256 y0, uint256 x1, int256 y1) external {
        refineBetween(x0, _one(y0), x1, _one(y1));
    }

    function unavailable() external pure returns (int256) {
        return SIGNAL_UNAVAILABLE;
    }

    function summary()
        external
        returns (uint256 inserted, uint256 from, uint256 to, uint256 flatFrom, uint256 flatTo, uint256 flatPoints)
    {
        return refinementSummary();
    }

    function smoothTail() external view returns (uint256 from, uint256 to, uint256 points) {
        return refinementSmoothTail();
    }

    function emittedCount() external view returns (uint256) {
        return emitted.length;
    }
}

contract GraphRefinementBehaviourTest is Test {
    /// A sweep that has not opted in samples exactly the points it always did.
    function test_refinementIsOffUntilAToleranceIsSet() public {
        RecordingRefiner refiner = new RecordingRefiner(0, 6, 0);
        refiner.setStepAt(500);

        refiner.refine(0, 1000);

        assertEq(refiner.emittedCount(), 0, "no samples inserted");
        assertEq(refiner.probes(), 0, "and nothing measured to decide that");
    }

    /// A straight line is already drawn by its endpoints, so nothing is inserted however deep the
    /// refinement is allowed to go.
    function test_aStraightLineEarnsNoExtraSamples() public {
        RecordingRefiner refiner = new RecordingRefiner(1, 8, 0);
        refiner.setStraight();

        refiner.refine(0, 1000);

        assertEq(refiner.emittedCount(), 0, "a chord matches the line exactly, so no midpoint is kept");
        assertEq(refiner.probes(), 1, "one midpoint measured, then the interval left alone");
    }

    /// Inserted samples arrive in increasing order, so a graph reads in order without being sorted.
    function test_insertedSamplesAreInIncreasingOrder() public {
        RecordingRefiner refiner = new RecordingRefiner(1, 6, 0);
        refiner.setStepAt(500);

        refiner.refine(0, 1000);

        uint256 count = refiner.emittedCount();
        assertGt(count, 1, "a step should attract several samples");
        for (uint256 i = 1; i < count; i++) {
            assertGt(refiner.emitted(i), refiner.emitted(i - 1), "samples must increase");
        }
    }

    /// Samples land around the step rather than being spread across the interval - the point of
    /// refining at all.
    function test_samplesConcentrateAroundTheBend() public {
        RecordingRefiner refiner = new RecordingRefiner(1, 6, 0);
        refiner.setStepAt(500);

        refiner.refine(0, 1000);

        uint256 count = refiner.emittedCount();
        uint256 near;
        for (uint256 i = 0; i < count; i++) {
            uint256 x = refiner.emitted(i);
            uint256 distance = x > 500 ? x - 500 : 500 - x;
            if (distance <= 32) {
                near++;
            }
        }
        assertGe(near * 2, count, "at least half the inserted samples sit within a thirty-second of the step");
    }

    /// A discontinuity never satisfies the criterion, so the depth limit is the only thing that ends the
    /// recursion. Its cost must therefore be bounded by that limit.
    function test_aStepRefinesOnlyAsDeepAsItIsAllowed() public {
        RecordingRefiner shallow = new RecordingRefiner(1, 3, 0);
        shallow.setStepAt(500);
        shallow.refine(0, 1000);

        RecordingRefiner deeper = new RecordingRefiner(1, 6, 0);
        deeper.setStepAt(500);
        deeper.refine(0, 1000);

        assertLe(shallow.emittedCount(), 2 ** 3, "a depth of three cannot cost more than eight samples");
        assertGt(deeper.emittedCount(), shallow.emittedCount(), "more depth resolves the step further");
    }

    /// Below the minimum step an interval is left alone whatever its shape, so a sweep cannot be asked
    /// for a resolution it has no way to drive.
    function test_theMinimumStepStopsRefinementRegardlessOfShape() public {
        RecordingRefiner refiner = new RecordingRefiner(1, 8, 1000);
        refiner.setStepAt(500);

        refiner.refine(0, 1000);

        assertEq(refiner.emittedCount(), 0, "the whole interval is at the minimum step, so it is left alone");
    }

    /// The sweep records where its samples were spent, so a range and step can be chosen from evidence.
    /// Across a step, the inserted samples span only the interval holding it, and the flat side is
    /// reported as a run drawing one value.
    function test_theSweepReportsWhereItsSamplesWereSpent() public {
        RecordingRefiner refiner = new RecordingRefiner(1, 6, 0);
        refiner.setStepAt(950);

        // three intervals: two wholly on the flat side, the third holding the step
        refiner.refine(0, 300);
        refiner.refine(300, 600);
        refiner.refine(600, 1000);

        (uint256 inserted, uint256 from, uint256 to, uint256 flatFrom, uint256 flatTo, uint256 flatPoints) = refiner
            .summary();

        assertEq(inserted, refiner.emittedCount(), "counts what it inserted");
        assertGe(from, 600, "and where: nothing inserted before the interval holding the step");
        assertLe(to, 1000, "nor after it");
        assertEq(flatFrom, 0, "the flat run starts at the beginning");
        assertEq(flatTo, 600, "and ends where the signal first changed");
        assertEq(flatPoints, 3, "spanning the three swept points that drew one value");
    }

    /// The stretch the sweep's own step already drew well is reported separately from a still one: the
    /// signal there has changed, it simply never bent enough to earn another sample.
    function test_theSweepReportsWhereItsOwnStepWasEnough() public {
        RecordingRefiner refiner = new RecordingRefiner(1, 6, 0);
        refiner.setStepAt(150);

        // the step falls in the first interval; the three after it are drawn by their endpoints alone
        refiner.refine(0, 300);
        refiner.refine(300, 600);
        refiner.refine(600, 900);
        refiner.refine(900, 1200);

        (uint256 from, uint256 to, uint256 points) = refiner.smoothTail();

        assertEq(from, 300, "the stretch starts where the last inserted sample's interval ended");
        assertEq(to, 1200, "and runs to the end of the sweep");
        assertEq(points, 4, "spanning the four swept points that needed nothing between them");
    }

    /// An interval whose signal has no value at one end cannot be judged against a straight line, so it
    /// is left alone rather than refined against a sentinel standing in for the missing measurement.
    function test_anIntervalWithNoSignalIsLeftAlone() public {
        RecordingRefiner refiner = new RecordingRefiner(1, 8, 0);
        refiner.setStepAt(500);

        refiner.refineWithEndSignals(0, refiner.unavailable(), 1000, 0);

        assertEq(refiner.emittedCount(), 0, "nothing inserted");
        assertEq(refiner.probes(), 0, "and the midpoint is not even measured");
    }

    /// An interval too narrow to have a midpoint is left alone, whatever the limits say.
    function test_anIntervalWithNoMidpointIsLeftAlone() public {
        RecordingRefiner refiner = new RecordingRefiner(1, 8, 0);
        refiner.setStepAt(500);

        refiner.refine(500, 501);

        assertEq(refiner.emittedCount(), 0, "adjacent points cannot be subdivided");
    }
}
