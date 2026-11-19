"""A build of bao-base compiles each file with one compiler, the same one for every file its pragma does not pin.

The pragmas alone do not decide the compiler. Most files allow `>=0.8.28 <0.9.0`, some pin 0.8.30, and one test
fixture pins 0.8.28. No version satisfies every file, so forge splits a build into groups. Without a cap, a full
`forge build` or `forge coverage` then compiled 204 files with the newest compiler installed, 0.8.35, 112 of them
also with 0.8.30, while `forge test` compiled all of them with 0.8.30. The `compilation_restrictions` cap in
foundry.toml takes the choice from forge.

The build runs with `--deny never`: with warnings denied, forge keeps no cache to read the compilers from
(test_forge_deny_warnings_cache.py), and a warning would hide the compiler choice behind a failed build.
"""

import json
import os
import subprocess
from pathlib import Path

import pytest

BAO_BASE = Path(__file__).resolve().parents[2]


@pytest.fixture(scope="module")
def compilers(tmp_path_factory) -> dict[str, tuple[str, set[str]]]:
    """Build bao-base from nothing into a scratch folder: each source's version requirement, and the compiler
    versions that built it."""
    scratch = tmp_path_factory.mktemp("build")
    environment = dict(os.environ, FOUNDRY_OUT=str(scratch / "out"), FOUNDRY_CACHE_PATH=str(scratch / "cache"))
    built = subprocess.run(
        ["forge", "build", "--deny", "never"],
        cwd=BAO_BASE,
        env=environment,
        capture_output=True,
        text=True,
        timeout=600,
    )
    assert built.returncode == 0, built.stdout + built.stderr
    files = json.loads((scratch / "cache" / "solidity-files-cache.json").read_text())["files"]
    return {
        path: (
            entry["versionRequirement"],
            {version for by_version in entry["artifacts"].values() for version in by_version},
        )
        for path, entry in files.items()
    }


def test_each_file_is_compiled_by_one_compiler(compilers):
    # a file compiled twice is in two groups, and which of its two artifacts a test reads is forge's choice
    twice = sorted(
        f"{path}: {', '.join(sorted(versions))}" for path, (_, versions) in compilers.items() if len(versions) > 1
    )
    assert twice == [], f"{len(twice)} files compiled with more than one compiler:\n  " + "\n  ".join(twice)


def test_every_file_its_pragma_does_not_pin_shares_one_compiler(compilers):
    # an exact pin is recorded as `=0.8.30`; every other file gets whatever version forge chooses for it
    unpinned = {}
    for path, (requirement, versions) in compilers.items():
        if not requirement.startswith("="):
            for version in versions:
                unpinned.setdefault(version, []).append(path)
    assert len(unpinned) == 1, "files whose pragma pins no version are compiled with several compilers: " + ", ".join(
        f"{version} ({len(paths)} files, such as {sorted(paths)[0]})" for version, paths in sorted(unpinned.items())
    )
