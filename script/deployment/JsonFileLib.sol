// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";

/// @notice Writes JSON files that end as a text file does: with a newline.
/// @dev forge's `vm.writeJson` pretty-prints and ends the file at its closing brace. Editors and formatters end a text
///      file with a newline when they save it, so a file written without one differs from the same file saved.
library JsonFileLib {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Write `json` to `path` pretty-printed, as `vm.writeJson` does, ending with a newline.
    function write(string memory json, string memory path) internal {
        vm.writeJson(json, path);
        endWithNewline(path);
    }

    /// @notice Append a newline to the file at `path` unless it ends with one. An empty file holds no line to end, and
    ///         is left empty.
    function endWithNewline(string memory path) internal {
        bytes memory content = bytes(vm.readFile(path));
        if (content.length == 0 || content[content.length - 1] == "\n") {
            return;
        }
        // `writeLine` appends its argument, then a newline
        vm.writeLine(path, "");
    }
}
