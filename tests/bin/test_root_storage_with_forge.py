"""`storage-successor --list-root-storage` on what the forge in use really writes.

bin/validate runs this file, so it meets every forge version validate meets; the python test job meets only one. The
list reads solc's storage layout from the build-info, and a contract with no root variables has no layout there at all.
So a forge that stopped recording layouts would make every contract look clean. Compiling a contract with known root
variables shows that has not happened.
"""

import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "bin" / "storage-successor.py"

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


def test_root_variables_are_listed_and_namespaced_fields_are_not(tmp_path):
    (tmp_path / "foundry.toml").write_text("[profile.default]\n")
    (tmp_path / "src").mkdir()
    (tmp_path / "src" / "Storage.sol").write_text(SOURCE)
    build_info = tmp_path / "build-info"

    # the flags that matter from bin/validate's build
    build = subprocess.run(
        [
            "forge",
            "build",
            "--root",
            str(tmp_path),
            "--build-info",
            "--build-info-path",
            str(build_info),
            "--extra-output",
            "storageLayout",
        ],
        capture_output=True,
        text=True,
    )
    assert build.returncode == 0, build.stdout + build.stderr

    listed = subprocess.run(
        [sys.executable, str(SCRIPT), str(build_info), "--list-root-storage"],
        capture_output=True,
        text=True,
    )
    assert listed.returncode == 0, listed.stdout + listed.stderr
    assert listed.stdout.splitlines() == [
        "src/Storage.sol:RootAndNamespaced first slot 0 offset 0",
        "src/Storage.sol:RootAndNamespaced second slot 1 offset 0",
    ]
