"""Tests for bin/validate, which `./run validate` runs, typed in bao-base or in a project that uses it.

Typed in a project that uses bao-base, validate runs in that project's folder. So it must reach bao-base's own files
through bao-base's folder, and never as paths read from the folder it runs in.

Each test runs validate through `run` in a small project in a temporary folder, outside bao-base. Every tool is the
real one except npx, and forge where a test says so. validate runs OpenZeppelin upgrades-core through npx, and a
folder with no node_modules of its own would download it. A stub `npx` first on PATH prints the report upgrades-core
gives for a project with no upgradeable contracts.
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

BAO_BASE = Path(__file__).resolve().parents[2]

# Stands in for npx. It runs under this interpreter by its absolute path.
STUB_NPX = """#!{interpreter}
print()
print("SUCCESS (0 upgradeable contracts detected, 0 passed, 0 failed)")
"""

# Stands in for forge: runs the real one, then removes every storage layout from the build-info of validate's own
# build (written under out/_validate), as a forge would that asked solc for layouts and wrote none. Other builds keep
# theirs.
STUB_FORGE = """#!{interpreter}
import glob, json, subprocess, sys
arguments = sys.argv[1:]
status = subprocess.run([{forge!r}, *arguments]).returncode
if "--build-info-path" in arguments:
    folder = arguments[arguments.index("--build-info-path") + 1]
    if folder.startswith("out/_validate"):
        for path in glob.glob(folder + "/*.json"):
            with open(path) as file:
                build_info = json.load(file)
            for contracts in build_info.get("output", {{}}).get("contracts", {{}}).values():
                for contract in contracts.values():
                    contract.pop("storageLayout", None)
            with open(path, "w") as file:
                json.dump(build_info, file)
sys.exit(status)
"""

PLAIN_CONTRACT = """// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

contract Plain {
    function answer() external pure returns (uint256) {
        return 42;
    }
}
"""


def _stub(folder: Path, name: str, text: str) -> None:
    folder.mkdir(exist_ok=True)
    path = folder / name
    path.write_text(text)
    path.chmod(0o755)


def _validate(tmp_path: Path, stub: Path) -> subprocess.CompletedProcess:
    """Run validate in `tmp_path/project`, a project with one plain contract, with `stub` first on PATH."""
    project = tmp_path / "project"
    (project / "src").mkdir(parents=True)
    (project / "script").mkdir()
    (project / "foundry.toml").write_text("[profile.default]\n")
    (project / "src" / "Plain.sol").write_text(PLAIN_CONTRACT)
    _stub(stub, "npx", STUB_NPX.format(interpreter=sys.executable))
    return subprocess.run(
        [str(BAO_BASE / "run"), "validate"],
        cwd=project,
        env={**os.environ, "PATH": f"{stub}{os.pathsep}{os.environ['PATH']}"},
        capture_output=True,
        text=True,
    )


def test_validate_passes_in_a_project_that_uses_bao_base(tmp_path):
    # validate typed in another project finds the files it runs from bao-base, and passes a project with nothing wrong
    result = _validate(tmp_path, tmp_path / "stub")

    assert result.returncode == 0, result.stdout + result.stderr


def test_validate_refuses_a_build_that_holds_no_storage_layouts(tmp_path):
    # forge leaves an empty layout out, so a build with none would make every contract look free of root variables
    stub = tmp_path / "stub"
    _stub(stub, "forge", STUB_FORGE.format(interpreter=sys.executable, forge=shutil.which("forge")))

    result = _validate(tmp_path, stub)

    assert result.returncode == 1, result.stdout + result.stderr
    assert "KnownRootVariablesCanary.sol:KnownRootVariablesCanary" in result.stderr, result.stdout + result.stderr
