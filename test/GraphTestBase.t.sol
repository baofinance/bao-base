// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {BaoTestLib} from "@bao-test/BaoTestLib.sol";

/// @notice Writes measurement data to a CSV under `./results/` for plotting.
///
/// Two row shapes, and which one a graph wants depends on how many things it sweeps:
///
/// - **Wide** (`openFile` / `writeLine`) — a fixed set of named value columns, one row per point of a
///   single sweep. The point's own coordinate is just the first value the caller passes.
/// - **Long** (`openLongFile` / `writeRow`) — every axis coordinate as its own leading column,
///   followed by the measured values. This is the shape that survives adding an axis, and the only one
///   a fuzz driver can use, since rows then carry their own coordinates and need not arrive in order.
///
/// This contract deliberately owns no sweep loop. A stepped single-axis sweep gets one from
/// `GraphSweepTestBase`; a fuzz-driven graph declares its own `testFuzz_…` taking the axes as
/// arguments and appends a row per run. Welding a loop to the writer is what previously left
/// fuzz-driven graphs with nowhere to plug in.
abstract contract GraphTestBase is Test {
    /// @dev Values are fixed-point with 18 decimals unless a column says otherwise.
    uint8 internal constant DEFAULT_DECIMALS = 18;

    /// @dev Written as the literal `NaN`, which gnuplot skips, so a point whose getter reverted leaves
    ///      a gap in the line rather than a zero that would read as a measurement.
    ///
    ///      Signed only, deliberately. Every `uint256` is a legitimate measurement, so an unsigned
    ///      sentinel has to steal a real value — and `type(uint256).max`, the obvious choice, is a live
    ///      "no cap" argument in this codebase. A column that needs gaps is therefore `int256`.
    int256 internal constant NaN = type(int256).max;

    /// @dev Distinguishes several files written by one graph contract, suffixed to the file name.
    ///      `view` rather than `pure` so a variant may be chosen from state; the common case of a
    ///      literal suffix still overrides this as `pure`.
    function context() internal view virtual returns (string memory) {
        return "";
    }

    /// @dev Where graphs are written. Overridden by suites whose output is scratch rather than a graph
    ///      anyone reads, so it does not accumulate among the real measurements.
    function outputDirectory() internal view virtual returns (string memory) {
        return "./results/";
    }

    // ─── wide rows ───

    /// @dev The path a graph of this name resolves to. Separate from `openFile` so the name-to-path
    ///      rule can be established without creating anything.
    function graphPath(string memory name) internal view returns (string memory) {
        return string.concat(outputDirectory(), string.concat(name, context()), ".csv");
    }

    /// @dev Creates the file and writes its header, replacing any previous content. `vm.writeFile`
    ///      truncates, so there is no delete step to race with a parallel test run.
    function openFile(string memory name, string[] memory header) internal returns (string memory file) {
        file = graphPath(name);
        vm.writeFile(file, string.concat(BaoTestLib.join(header, ","), "\n"));
    }

    function writeLine(string memory file, uint256[] memory data) internal {
        vm.writeLine(file, _row(data, DEFAULT_DECIMALS));
    }

    function writeLine(string memory file, int256[] memory data) internal {
        vm.writeLine(file, _row(data, DEFAULT_DECIMALS));
    }

    /// @dev One scale per column, so a row can carry a count, an index and an 18-decimal ratio
    ///      together without the caller pre-multiplying the ones that are not scaled.
    function writeLine(string memory file, uint256[] memory data, uint8[] memory decimals) internal {
        vm.writeLine(file, _row(data, decimals));
    }

    function writeLine(string memory file, int256[] memory data, uint8[] memory decimals) internal {
        vm.writeLine(file, _row(data, decimals));
    }

    // ─── long rows ───

    /// @dev Header is every axis name followed by every value name; `writeRow` must match that order.
    function openLongFile(
        string memory name,
        string[] memory axes,
        string[] memory values
    ) internal returns (string memory file) {
        string[] memory header = new string[](axes.length + values.length);
        for (uint256 i = 0; i < axes.length; i++) {
            header[i] = axes[i];
        }
        for (uint256 i = 0; i < values.length; i++) {
            header[axes.length + i] = values[i];
        }
        file = openFile(name, header);
    }

    function writeRow(string memory file, uint256[] memory axes, uint256[] memory values) internal {
        writeRow(file, axes, DEFAULT_DECIMALS, values, DEFAULT_DECIMALS);
    }

    /// @dev Axes and values usually want different scales — an axis is often a plain count or index
    ///      where the measurements beside it are 18-decimal.
    function writeRow(
        string memory file,
        uint256[] memory axes,
        uint8 axisDecimals,
        uint256[] memory values,
        uint8 valueDecimals
    ) internal {
        vm.writeLine(file, _longRow(axes, axisDecimals, values, valueDecimals));
    }

    // ─── formatting ───
    //
    // The row builders are separate from the writers, and `internal` rather than `private`, so that
    // what a row looks like can be established without a filesystem: every scaling, separator and
    // sentinel rule is pure, and only the file's own behaviour needs real I/O to verify.

    error ColumnCountMismatch(uint256 dataLength, uint256 decimalsLength);

    function _longRow(
        uint256[] memory axes,
        uint8 axisDecimals,
        uint256[] memory values,
        uint8 valueDecimals
    ) internal pure returns (string memory) {
        string[] memory cells = new string[](axes.length + values.length);
        for (uint256 i = 0; i < axes.length; i++) {
            cells[i] = BaoTestLib.toStringScaled(axes[i], axisDecimals);
        }
        for (uint256 i = 0; i < values.length; i++) {
            cells[axes.length + i] = BaoTestLib.toStringScaled(values[i], valueDecimals);
        }
        return BaoTestLib.join(cells, ",");
    }

    function _row(uint256[] memory data, uint8 decimals) internal pure returns (string memory) {
        string[] memory cells = new string[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            cells[i] = BaoTestLib.toStringScaled(data[i], decimals);
        }
        return BaoTestLib.join(cells, ",");
    }

    function _row(int256[] memory data, uint8 decimals) internal pure returns (string memory) {
        string[] memory cells = new string[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            cells[i] = data[i] == NaN ? "NaN" : BaoTestLib.toStringScaled(data[i], decimals);
        }
        return BaoTestLib.join(cells, ",");
    }

    function _row(uint256[] memory data, uint8[] memory decimals) internal pure returns (string memory) {
        if (data.length != decimals.length) {
            revert ColumnCountMismatch(data.length, decimals.length);
        }
        string[] memory cells = new string[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            cells[i] = BaoTestLib.toStringScaled(data[i], decimals[i]);
        }
        return BaoTestLib.join(cells, ",");
    }

    function _row(int256[] memory data, uint8[] memory decimals) internal pure returns (string memory) {
        if (data.length != decimals.length) {
            revert ColumnCountMismatch(data.length, decimals.length);
        }
        string[] memory cells = new string[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            cells[i] = data[i] == NaN ? "NaN" : BaoTestLib.toStringScaled(data[i], decimals[i]);
        }
        return BaoTestLib.join(cells, ",");
    }
}

/// @notice A stepped sweep over one axis, for graphs whose x advances by a rule the subclass supplies
///         (a fixed step, an exponential one, a clock warp). Multi-axis and fuzz-driven graphs use
///         `GraphTestBase` directly and drive themselves.
abstract contract GraphSweepTestBase is GraphTestBase {
    uint256 startX;
    uint256 currentX;
    uint256 finishX;

    /// @dev Measure and write one row at `currentX`.
    function doOneX() internal virtual;

    /// @dev Advance `currentX`. Must make progress, or the sweep does not terminate.
    function incrementX() internal virtual;

    /// @dev Run once after the last point, to close the files the graph opened.
    function setDown() internal virtual;

    function test_doGraph() public virtual {
        currentX = startX;
        while (currentX < finishX) {
            doOneX();
            incrementX();
        }
        setDown();
    }
}
