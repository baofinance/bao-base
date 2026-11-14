// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {JsonFileLib} from "@bao-script/deployment/JsonFileLib.sol";

/// @notice `JsonFileLib` ends each file it writes with one newline. Each test writes its own file under `tmp/`, which
///         git ignores, before the call under test, so a file an earlier run left cannot pass it.
contract JsonFileLibTest is Test {
    /// @dev The file under `tmp/` named for the calling test: its own, as the tests run in parallel.
    function _path(string memory test) private returns (string memory) {
        vm.createDir(string.concat(vm.projectRoot(), "/tmp"), true);
        return string.concat(vm.projectRoot(), "/tmp/JsonFileLibTest::", test, ".json");
    }

    function test_write_endsTheFileWithOneNewline() public {
        // JSON is written pretty-printed, as `vm.writeJson` writes it, and then ends with one newline
        string memory path = _path("write_endsTheFileWithOneNewline");
        vm.writeFile(path, "not written by this run");

        // The JSON is a literal: on forge 1.9.0, a `vm.serialize*` cheatcode aborts the whole run with a stack overflow
        // on the fixtures' structs that hold themselves (doc/forge-serialize-recursive-struct-crash.md).
        JsonFileLib.write('{"value":1}', path);

        assertEq(vm.readFile(path), '{\n  "value": 1\n}\n');
    }

    function test_endWithNewline_addsOneToAFileWithout() public {
        // a file whose last line has no newline gets one
        string memory path = _path("endWithNewline_addsOneToAFileWithout");
        vm.writeFile(path, "x");

        JsonFileLib.endWithNewline(path);

        assertEq(vm.readFile(path), "x\n");
    }

    function test_endWithNewline_leavesAFileThatHasOne() public {
        // a file that already ends with a newline gains no second one
        string memory path = _path("endWithNewline_leavesAFileThatHasOne");
        vm.writeFile(path, "x\n");

        JsonFileLib.endWithNewline(path);

        assertEq(vm.readFile(path), "x\n");
    }

    function test_endWithNewline_leavesAnEmptyFileEmpty() public {
        // an empty file holds no line to end, so it stays empty
        string memory path = _path("endWithNewline_leavesAnEmptyFileEmpty");
        vm.writeFile(path, "");

        JsonFileLib.endWithNewline(path);

        assertEq(vm.readFile(path), "");
    }
}
