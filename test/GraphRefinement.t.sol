// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {console2} from "forge-std/console2.sol";

import {BaoTestLib} from "@bao-test/BaoTestLib.sol";

/// @notice Adds samples to a sweep where its curves bend, without moving the samples it already takes.
///
/// A sweep at a fixed step spends its samples evenly, which is the wrong distribution whenever what is
/// being measured is flat over most of the range and turns sharply over a little of it. This refines by
/// recursive subdivision: take the midpoint of an interval, and if any line being drawn there departs
/// from the straight line between that interval's ends by more than a tolerance, keep the midpoint and
/// recurse into both halves. It is the one-dimensional case of adaptive mesh refinement, and what
/// plotting packages do to draw a curve from an expensive function.
///
/// **Every line counts, none is nominated.** A region is only uninteresting if nothing drawn there is
/// doing anything, so both the refining and the reporting look at every column the graph plots. Judging
/// by a single chosen column would refine where that one bends and — worse — would report a region as
/// having nothing to say while another line moved through it.
///
/// **Every point of the original sweep is still taken.** Refinement only ever INSERTS, so a graph's rows
/// remain a superset of the ones it had before. That is what keeps a tracked result diffable: the
/// uniform rows stay at the same coordinates and line up as context, and refinement shows as inserted
/// lines rather than shifting every row in the file.
///
/// The tolerance is relative to each column's own magnitude, so one number serves columns of different
/// scales, and so that what counts as a bend matches what a reader sees on a logarithmic axis - where
/// equal ratios, not equal differences, are equal distances.
///
/// A discontinuity never satisfies the criterion - no midpoint of a step is near the chord - so the
/// recursion would refine a jump forever. `refinementMaxDepth` is what stops it, and a jump therefore
/// costs about `2 ** depth` extra samples. That is the intended behaviour: it draws the cliff sharply.
///
/// Refinement is OFF unless a sweep opts in, by returning a non-zero `refinementTolerance`.
abstract contract GraphRefinement {
    /// @notice What a column reads where its quantity has no value at that point - one that does not
    ///         exist rather than one that happens to be zero.
    /// @dev Such a column is skipped when judging an interval, since a straight line cannot be drawn to
    ///      a value that is not there. Without this a missing value would read as an enormous one and
    ///      refinement would spend its whole depth on the edge of the gap. Numerically it is the value a
    ///      graph writes as `NaN`, which is not a coincidence: both mean "no measurement here".
    int256 internal constant SIGNAL_UNAVAILABLE = type(int256).max;

    /// @notice How far a line may depart from the straight line between its neighbours before the
    ///         midpoint earns a place in the graph, as a fraction of that line's own magnitude, 1e18
    ///         being all of it.
    /// @dev Zero disables refinement entirely, which is the default: a sweep that overrides nothing
    ///      samples exactly the points it always did.
    function refinementTolerance() internal view virtual returns (uint256) {
        return 0;
    }

    /// @notice How many times one interval of the original sweep may be halved.
    function refinementMaxDepth() internal view virtual returns (uint8) {
        return 6;
    }

    /// @notice The interval width below which an interval is left alone, whatever its shape.
    function refinementMinStep() internal view virtual returns (uint256) {
        return 0;
    }

    /// @notice Measure every column the graph draws at `x`, WITHOUT recording a row.
    /// @dev Refinement has to know a candidate's values before it can decide whether to keep it, so this
    ///      is separate from recording. It must leave the subject as it found it.
    function probeSignalsAt(uint256 x) internal virtual returns (int256[] memory);

    /// @notice Measure at `x` and record the row.
    function emitSampleAt(uint256 x) internal virtual;

    /// @dev What the sweep spent and where, accumulated as it goes and read only at the end to report.
    ///      Nothing here steers a decision; it is a record of what happened.
    uint256 private insertedCount;
    uint256 private insertedFrom;
    uint256 private insertedTo;
    uint256 private flatRunFrom;
    uint256 private flatRunTo;
    uint256 private longestFlatFrom;
    uint256 private longestFlatTo;
    uint256 private flatRunPoints;
    uint256 private longestFlatPoints;
    bool private inFlatRun;
    uint256 private missingRunFrom;
    uint256 private missingRunTo;
    uint256 private longestMissingFrom;
    uint256 private longestMissingTo;
    uint256 private missingRunPoints;
    uint256 private longestMissingPoints;
    bool private inMissingRun;
    uint256 private sweptTo;
    bool private sweepStarted;
    uint256 private smoothRunFrom;
    uint256 private smoothRunPoints;

    /// @notice Insert whatever samples the interval `x0..x1` needs, given the columns already measured at
    ///         its ends. Rows are emitted in increasing `x`, so a graph reads in order without sorting.
    function refineBetween(uint256 x0, int256[] memory y0, uint256 x1, int256[] memory y1) internal {
        _recordInterval(x0, y0, x1, y1);
        if (!sweepStarted) {
            smoothRunFrom = x0;
            smoothRunPoints = 1;
            sweepStarted = true;
        }
        sweptTo = x1;

        uint256 insertedBefore = insertedCount;
        _refineBetween(x0, y0, x1, y1, refinementMaxDepth());

        if (insertedCount > insertedBefore) {
            smoothRunFrom = x1;
            smoothRunPoints = 1;
        } else {
            smoothRunPoints++;
        }
    }

    /// @notice The stretch running to the end of the sweep over which nothing had to be inserted: where
    ///         it starts, where it ends, and how many swept points it holds.
    /// @dev Not the same as a still stretch. The lines there may be moving a great deal - just smoothly
    ///      enough that the sweep's own step already draws them.
    function refinementSmoothTail() internal view returns (uint256 from, uint256 to, uint256 points) {
        return (smoothRunFrom, sweptTo, smoothRunPoints);
    }

    /// @dev A stretch is only still if EVERY line is still across it, and only absent if every line is.
    function _recordInterval(uint256 x0, int256[] memory y0, uint256 x1, int256[] memory y1) private {
        bool allMissing = true;
        bool allEqual = true;
        for (uint256 i = 0; i < y0.length; i++) {
            bool missing = y0[i] == SIGNAL_UNAVAILABLE && y1[i] == SIGNAL_UNAVAILABLE;
            if (!missing) {
                allMissing = false;
            }
            if (y0[i] != y1[i]) {
                allEqual = false;
            }
        }

        if (allEqual && !allMissing) {
            if (!inFlatRun) {
                flatRunFrom = x0;
                flatRunPoints = 1;
                inFlatRun = true;
            }
            flatRunTo = x1;
            flatRunPoints++;
        } else {
            _closeFlatRun();
        }

        if (allMissing) {
            if (!inMissingRun) {
                missingRunFrom = x0;
                missingRunPoints = 1;
                inMissingRun = true;
            }
            missingRunTo = x1;
            missingRunPoints++;
        } else {
            _closeMissingRun();
        }
    }

    function _refineBetween(
        uint256 x0,
        int256[] memory y0,
        uint256 x1,
        int256[] memory y1,
        uint8 depthLeft
    ) private {
        if (refinementTolerance() == 0) {
            return;
        }
        if (depthLeft == 0) {
            return;
        }
        uint256 width = x1 - x0;
        if (width < 2) {
            return;
        }
        if (width <= refinementMinStep()) {
            return;
        }

        // A column with no value at either end cannot be judged against a straight line. If that is true
        // of every column there is nothing to decide, so the midpoint is not worth measuring - which is
        // what spares the probe across a stretch the graph draws nothing in.
        if (_nothingJudgeable(y0, y1)) {
            return;
        }

        uint256 middle = x0 + width / 2;
        int256[] memory measured = probeSignalsAt(middle);
        if (!_anyColumnBends(y0, y1, measured)) {
            return;
        }

        _refineBetween(x0, y0, middle, measured, depthLeft - 1);

        emitSampleAt(middle);
        if (insertedCount == 0 || middle < insertedFrom) {
            insertedFrom = middle;
        }
        if (middle > insertedTo) {
            insertedTo = middle;
        }
        insertedCount++;

        _refineBetween(middle, measured, x1, y1, depthLeft - 1);
    }

    function _nothingJudgeable(int256[] memory y0, int256[] memory y1) private pure returns (bool) {
        for (uint256 i = 0; i < y0.length; i++) {
            if (y0[i] != SIGNAL_UNAVAILABLE && y1[i] != SIGNAL_UNAVAILABLE) {
                return false;
            }
        }
        return true;
    }

    /// @dev Relative to the column's own magnitude, so one tolerance serves every column whatever its
    ///      scale. A column missing a value at either end or in the middle cannot be judged and is
    ///      passed over; if that leaves nothing to judge, the interval is left alone.
    function _anyColumnBends(
        int256[] memory y0,
        int256[] memory y1,
        int256[] memory measured
    ) private view returns (bool) {
        uint256 tolerance = refinementTolerance();
        for (uint256 i = 0; i < measured.length; i++) {
            if (
                y0[i] == SIGNAL_UNAVAILABLE || y1[i] == SIGNAL_UNAVAILABLE || measured[i] == SIGNAL_UNAVAILABLE
            ) {
                continue;
            }
            int256 chord = SignedMath.average(y0[i], y1[i]);
            uint256 deviation = SignedMath.abs(measured[i] - chord);
            uint256 magnitude = SignedMath.abs(chord);
            if (magnitude < 1) {
                magnitude = 1;
            }
            if ((deviation * 1 ether) / magnitude > tolerance) {
                return true;
            }
        }
        return false;
    }

    function _closeFlatRun() private {
        if (inFlatRun && flatRunPoints > longestFlatPoints) {
            longestFlatPoints = flatRunPoints;
            longestFlatFrom = flatRunFrom;
            longestFlatTo = flatRunTo;
        }
        inFlatRun = false;
    }

    function _closeMissingRun() private {
        if (inMissingRun && missingRunPoints > longestMissingPoints) {
            longestMissingPoints = missingRunPoints;
            longestMissingFrom = missingRunFrom;
            longestMissingTo = missingRunTo;
        }
        inMissingRun = false;
    }

    /// @notice What the sweep spent and where: how many samples were inserted and over what span, the
    ///         longest run over which every line held still, and the longest over which none had a value.
    function refinementSummary()
        internal
        returns (uint256 inserted, uint256 from, uint256 to, uint256 flatFrom, uint256 flatTo, uint256 flatPoints)
    {
        _closeFlatRun();
        _closeMissingRun();
        return (insertedCount, insertedFrom, insertedTo, longestFlatFrom, longestFlatTo, longestFlatPoints);
    }

    /// @notice Report where the sweep's samples earned their keep, so its range and step can be chosen
    ///         from evidence rather than habit.
    /// @dev Three findings, wanting different remedies. A run where NO line has a value is not drawn at
    ///      all, so the sweep is paying for samples that never reach the graph. A run where every line
    ///      holds still still carries information - that nothing happens there is worth seeing - but it
    ///      does not need many samples or much of the width to say so. A stretch needing NO INSERTED
    ///      samples is not idle: the lines may be varying smoothly and rendering perfectly at the
    ///      sweep's own step.
    function reportRefinement() internal {
        _closeFlatRun();
        _closeMissingRun();
        if (refinementTolerance() == 0) {
            return;
        }

        if (insertedCount == 0) {
            console2.log("refinement: inserted nothing - the sweep's own step resolved every line");
        } else {
            console2.log(
                string.concat(
                    "refinement: inserted ",
                    LibString.toString(insertedCount),
                    " samples, all between ",
                    BaoTestLib.toStringScaled(insertedFrom, 18),
                    " and ",
                    BaoTestLib.toStringScaled(insertedTo, 18),
                    " - the step resolved every line elsewhere"
                )
            );
        }

        if (longestMissingPoints > 2) {
            console2.log(
                string.concat(
                    "refinement: no line had a value from ",
                    BaoTestLib.toStringScaled(longestMissingFrom, 18),
                    " to ",
                    BaoTestLib.toStringScaled(longestMissingTo, 18),
                    " across ",
                    LibString.toString(longestMissingPoints),
                    " swept points - nothing is drawn there"
                )
            );
        }

        (uint256 smoothFrom, uint256 smoothTo, uint256 smoothPoints) = refinementSmoothTail();
        if (smoothPoints > 2 && insertedCount > 0) {
            console2.log(
                string.concat(
                    "refinement: nothing needed inserting from ",
                    BaoTestLib.toStringScaled(smoothFrom, 18),
                    " to ",
                    BaoTestLib.toStringScaled(smoothTo, 18),
                    " across ",
                    LibString.toString(smoothPoints),
                    " swept points - the lines run smooth there, so that stretch wants less of the width, not fewer of its own points"
                )
            );
        }

        if (longestFlatPoints > 2) {
            console2.log(
                string.concat(
                    "refinement: every line held still from ",
                    BaoTestLib.toStringScaled(longestFlatFrom, 18),
                    " to ",
                    BaoTestLib.toStringScaled(longestFlatTo, 18),
                    " across ",
                    LibString.toString(longestFlatPoints),
                    " swept points - worth showing, but not worth this many samples or this much width"
                )
            );
        }
    }
}
