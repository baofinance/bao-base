// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {GraphTestBase, GraphSweepTestBase} from "@bao-test/GraphTestBase.t.sol";

/// @dev Exposes the writer's internal API. Row building is pure, so almost every rule about what a
///      graph line looks like is asserted without touching a file; only the file's own behaviour
///      needs real I/O. Scratch output goes to `tmp/`, which is ignored wholesale, rather than to
///      `results/`, which holds graphs someone actually reads.
contract GraphWriter is GraphTestBase {
    string private suffix;

    function outputDirectory() internal pure override returns (string memory) {
        return "./tmp/";
    }

    function setContext(string memory suffix_) external {
        suffix = suffix_;
    }

    function context() internal view override returns (string memory) {
        return suffix;
    }

    function path(string memory name) external view returns (string memory) {
        return graphPath(name);
    }

    function open(string memory name, string[] memory header) external returns (string memory) {
        return openFile(name, header);
    }

    function unsignedRow(uint256[] memory data) external pure returns (string memory) {
        return _row(data, DEFAULT_DECIMALS);
    }

    function unsignedRow(uint256[] memory data, uint8[] memory decimals) external pure returns (string memory) {
        return _row(data, decimals);
    }

    function signedRow(int256[] memory data) external pure returns (string memory) {
        return _row(data, DEFAULT_DECIMALS);
    }

    function longRow(uint256[] memory axes, uint256[] memory values) external pure returns (string memory) {
        return _longRow(axes, DEFAULT_DECIMALS, values, DEFAULT_DECIMALS);
    }

    function longRow(
        uint256[] memory axes,
        uint8 axisDecimals,
        uint256[] memory values,
        uint8 valueDecimals
    ) external pure returns (string memory) {
        return _longRow(axes, axisDecimals, values, valueDecimals);
    }

    function nan() external pure returns (int256) {
        return NaN;
    }
}

/// @dev A sweep that records the points it was driven through, so the driver can be asserted on
///      directly rather than through a file.
contract RecordingSweep is GraphSweepTestBase {
    uint256[] public visited;
    uint256 public setDownCalls;
    uint256 public setDownSawVisits;

    uint256 private stepX;

    constructor(uint256 start, uint256 finish, uint256 step) {
        startX = start;
        finishX = finish;
        stepX = step;
    }

    function doOneX() internal override {
        visited.push(currentX);
    }

    function incrementX() internal override {
        currentX += stepX;
    }

    function setDown() internal override {
        setDownCalls++;
        setDownSawVisits = visited.length;
    }

    function visitedCount() external view returns (uint256) {
        return visited.length;
    }
}

contract GraphTestBaseBehaviourTest is Test {
    GraphWriter internal writer;

    function setUp() public {
        writer = new GraphWriter();
        // `tmp/` is ignored wholesale, so it is absent on a fresh checkout and `vm.writeFile` does not
        // create parent directories. Recursive creation is idempotent, so parallel suites do not race.
        vm.createDir("./tmp", true);
    }

    function _sa(string memory a, string memory b) internal pure returns (string[] memory r) {
        r = new string[](2);
        r[0] = a;
        r[1] = b;
    }

    function _ua(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }

    // ─── row shape (no filesystem) ───

    /// The default row must keep the 1e18-scaled shape every existing graph depends on.
    function test_row_scalesEveryColumnBy18ByDefault() public view {
        assertEq(writer.unsignedRow(_ua(1 ether, 25 ether / 10)), "1.000000000000000000,2.500000000000000000");
    }

    /// A count and a ratio must be able to share a row without the caller pre-multiplying the count.
    function test_row_appliesPerColumnDecimals() public view {
        uint8[] memory decimals = new uint8[](2);
        decimals[0] = 0;
        decimals[1] = 18;

        assertEq(writer.unsignedRow(_ua(7, 15 ether / 10), decimals), "7,1.500000000000000000");
    }

    /// Separators belong between columns only, at every arity including none and one.
    function test_row_atEachArity() public view {
        assertEq(writer.unsignedRow(new uint256[](0)), "", "no columns");

        uint256[] memory one = new uint256[](1);
        one[0] = 1 ether;
        assertEq(writer.unsignedRow(one), "1.000000000000000000", "one column carries no separator");

        assertEq(
            writer.unsignedRow(_ua(1 ether, 2 ether)),
            "1.000000000000000000,2.000000000000000000",
            "separator between each pair only"
        );
    }

    /// A graph reads a getter that can revert, and records the sentinel when it does. It must appear as
    /// the literal `NaN` — which gnuplot skips, leaving a gap — rather than as a number, which would be
    /// plotted as though it had been measured.
    function test_row_writesNaNForUnmeasurableSignedValues() public view {
        int256[] memory data = new int256[](2);
        data[0] = 2 ether;
        data[1] = writer.nan();

        assertEq(writer.signedRow(data), "2.000000000000000000,NaN");
    }

    /// A row whose scale array does not match its data is a caller error, not a silently short row.
    function test_row_revertsWhenDecimalsCountDiffersFromColumnCount() public {
        uint8[] memory tooFew = new uint8[](1);
        tooFew[0] = 18;

        vm.expectRevert(abi.encodeWithSelector(GraphTestBase.ColumnCountMismatch.selector, 2, 1));
        writer.unsignedRow(_ua(1 ether, 2 ether), tooFew);
    }

    /// Long form leads with every axis coordinate, then the measured values, in header order.
    function test_longRow_putsAxisColumnsBeforeValueColumns() public view {
        assertEq(
            writer.longRow(_ua(105 ether / 100, 98 ether / 100), _ua(3 ether, 5 ether / 10)),
            "1.050000000000000000,0.980000000000000000,3.000000000000000000,0.500000000000000000"
        );
    }

    /// An axis is often a plain index where the measurements beside it are 18-decimal, so the two
    /// halves of a long row scale independently.
    function test_longRow_scalesAxesAndValuesIndependently() public view {
        assertEq(
            writer.longRow(_ua(3, 7), 0, _ua(1 ether, 2 ether), 18),
            "3,7,1.000000000000000000,2.000000000000000000"
        );
    }

    /// Each row is built from its own coordinates alone, so a fuzz driver may append them as drawn
    /// rather than in sweep order.
    function test_longRow_dependsOnlyOnItsOwnCoordinates() public view {
        string memory first = writer.longRow(_ua(3 ether, 1 ether), _ua(30 ether, 1 ether));
        string memory again = writer.longRow(_ua(3 ether, 1 ether), _ua(30 ether, 1 ether));
        string memory other = writer.longRow(_ua(1 ether, 1 ether), _ua(10 ether, 1 ether));

        assertEq(first, again, "same point gives the same row wherever it appears");
        assertNotEq(first, other, "a different point gives a different row");
    }

    // ─── naming (no filesystem) ───

    /// One graph contract writes several variants; `context()` is what keeps their files apart.
    function test_graphPath_appliesContextToTheName() public {
        writer.setContext("_variant");

        assertEq(writer.path("shape"), "./tmp/shape_variant.csv");
    }

    /// With no context the name stands alone, which is the common single-file case.
    function test_graphPath_isTheBareNameWithoutContext() public view {
        assertEq(writer.path("shape"), "./tmp/shape.csv");
    }

    // ─── the file itself (real I/O) ───

    /// Re-opening a name must replace the previous graph rather than append to it — and must do so
    /// without a delete step, which would race a parallel test run. This is the one rule that cannot be
    /// established without a real file.
    function test_openFile_truncatesAnExistingFile() public {
        string memory file = writer.open("graphtestbase-truncate", _sa("a", "b"));
        assertEq(vm.readFile(file), "a,b\n", "header written");

        string memory reopened = writer.open("graphtestbase-truncate", _sa("c", "d"));

        assertEq(reopened, file, "same name resolves to the same path");
        assertEq(vm.readFile(file), "c,d\n", "previous content is gone");
    }

    // ─── the sweep driver ───

    /// The sweep visits start, then each step, and stops before finish.
    function test_sweep_visitsEveryPointFromStartToFinish() public {
        RecordingSweep sweep = new RecordingSweep(10, 40, 10);
        sweep.test_doGraph();

        assertEq(sweep.visitedCount(), 3, "10, 20, 30 - 40 is the exclusive bound");
        assertEq(sweep.visited(0), 10);
        assertEq(sweep.visited(1), 20);
        assertEq(sweep.visited(2), 30);
    }

    /// A sweep whose start is already at or past finish measures nothing, and still closes its files.
    function test_sweep_visitsNoPointsWhenStartIsNotBeforeFinish() public {
        RecordingSweep sweep = new RecordingSweep(40, 40, 10);
        sweep.test_doGraph();

        assertEq(sweep.visitedCount(), 0, "no points");
        assertEq(sweep.setDownCalls(), 1, "still closed");
    }

    /// `setDown` closes the files, so it must run exactly once and only after the last measurement.
    function test_sweep_callsSetDownAfterTheLastPoint() public {
        RecordingSweep sweep = new RecordingSweep(0, 30, 10);
        sweep.test_doGraph();

        assertEq(sweep.setDownCalls(), 1, "closed exactly once");
        assertEq(sweep.setDownSawVisits(), 3, "closed after every point was measured");
    }
}
