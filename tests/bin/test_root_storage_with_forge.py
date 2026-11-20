"""`storage-successor --list-root-storage` on what the forge in use really writes.

The list reads solc's storage layout from the build-info, and forge leaves out a layout that would be empty. So
bin/validate adds bin/solidity/KnownRootVariablesCanary.sol to its build, and the listing refuses a build that lists no root
variables for it. This test builds a project the same way, from the project's folder, with the real known contract
named by its path from there, and lists it.
"""

import os
import subprocess
import sys
from pathlib import Path

BAO_BASE = Path(__file__).resolve().parents[2]
SCRIPT = BAO_BASE / "bin" / "storage-successor.py"
KNOWN_SOURCE = BAO_BASE / "bin" / "solidity" / "KnownRootVariablesCanary.sol"

SOURCE = """// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

contract Base {
    /// @custom:storage-location erc7201:example.storage.Base
    struct BaseStorage {
        uint64 initialized;
        mapping(address => uint256) balances;
    }
}

contract RootAndNamespaced is Base {
    uint256 public first;
    address public second;
}

contract OnlyNamespaced is Base {}
"""


def test_root_variables_are_listed_and_namespaced_fields_and_the_known_contract_are_not(tmp_path):
    (tmp_path / "foundry.toml").write_text("[profile.default]\n")
    (tmp_path / "src").mkdir()
    (tmp_path / "src" / "Storage.sol").write_text(SOURCE)
    known = os.path.relpath(KNOWN_SOURCE, tmp_path)

    # the build-info and the layouts, as bin/validate's build asks for them
    build = subprocess.run(
        ["forge", "build", "src", known]
        + ["--build-info", "--build-info-path", "build-info", "--extra-output", "storageLayout"],
        cwd=tmp_path,
        capture_output=True,
        text=True,
    )
    assert build.returncode == 0, build.stdout + build.stderr

    listed = subprocess.run(
        [sys.executable, str(SCRIPT), "build-info", "--list-root-storage"]
        + ["--known-root-variables", f"{known}:KnownRootVariablesCanary"],
        cwd=tmp_path,
        capture_output=True,
        text=True,
    )
    assert listed.returncode == 0, listed.stdout + listed.stderr
    assert listed.stdout.splitlines() == [
        "src/Storage.sol:RootAndNamespaced first slot 0 offset 0",
        "src/Storage.sol:RootAndNamespaced second slot 1 offset 0",
    ]
