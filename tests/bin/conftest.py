"""Pytest configuration, the shared temp-git-repo harness for the bin regression-system tests, and the
stand-in `run` the long-run scripts are driven through."""

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

# Put the bin directory on the path at conftest import time - BEFORE test modules are collected - so a
# test can `import ratchet` (etc.) at module top, not only inside a function where a fixture has run.
_BIN_DIR = Path(__file__).parent.parent.parent / "bin"
if str(_BIN_DIR) not in sys.path:
    sys.path.insert(0, str(_BIN_DIR))


class GitRepo:
    """A throwaway git repo for driving a regression file into each state the ratchet distinguishes.

    `file` is the regression file's repo-relative path. The state is set by the combination of HEAD,
    the index (`git show :file`), and the working-tree copy - which is what the tools read to tell a
    present baseline from a working-copy deletion, a staged deletion, or a never-tracked file.
    """

    def __init__(self, root: Path, file: str = "regression/f.txt"):
        self.root = root
        self.file = file
        self._path = root / file

    def _git(self, *args):
        subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True)

    def init(self):
        self._git("init", "-q")

    def write(self, text: str):
        """Write the working-tree copy (an unstaged edit); the index is untouched."""
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._path.write_text(text)

    def commit(self, text: str):
        """Commit `text` as the baseline: present in HEAD, the index, and the working tree."""
        self.write(text)
        self._git("add", "-A")
        self._git("commit", "-qm", "baseline")

    def stage(self, text: str):
        """Stage `text` without committing: it becomes the index (`git show :file`) baseline."""
        self.write(text)
        self._git("add", self.file)

    def stage_deletion(self):
        """Delete the working copy AND stage the deletion: the index has no version, HEAD still does."""
        self._path.unlink()
        self._git("add", self.file)

    def delete_worktree(self):
        """Delete only the working copy; the index still holds it (an unstaged deletion)."""
        self._path.unlink()

    def read(self) -> str:
        return self._path.read_text()

    def exists(self) -> bool:
        return self._path.exists()


@pytest.fixture
def repo(tmp_path, monkeypatch):
    """An initialised throwaway git repo with the process CWD moved into it.

    The tools resolve the baseline and the working-tree file relative to the CWD (they run from the
    repo root in production), so the fixture chdirs there and tests address the file by its
    repo-relative path. `regression/` is pre-created because the wrappers `mkdir -p` it before the
    ratchet runs.
    """
    repo = GitRepo(tmp_path)
    repo.init()
    (tmp_path / "regression").mkdir()
    monkeypatch.chdir(tmp_path)
    return repo


# The stand-in for bao-base's `run`. It records every call, prints a line naming it, and fails when
# told to. `test-long` is the exception: it runs the REAL bin/test-long.py, so CI-long is exercised
# against the real test-long, which in turn calls back into this stand-in for each `run test`.
_FAKE_RUN = """#!{python}
import json, os, subprocess, sys

argv = sys.argv[1:]
with open({record!r}, "a") as record:
    record.write(json.dumps({{"argv": argv, "fuzz_runs": os.environ.get("FOUNDRY_FUZZ_RUNS")}}) + "\\n")

if argv[0] == "test-long":
    sys.exit(subprocess.run([sys.executable, {test_long!r}, *argv[1:]]).returncode)

print("output of run " + " ".join(argv), flush=True)
fail_commands = os.environ.get("FAKE_RUN_FAIL_COMMANDS", "").split()
# "1" fails the run with --fuzz-seed 1; "random" fails every other seed
fail_seeds = os.environ.get("FAKE_RUN_FAIL_SEEDS", "").split()
seed = argv[argv.index("--fuzz-seed") + 1] if "--fuzz-seed" in argv else None
failing_seed = seed is not None and (seed in fail_seeds or (seed != "1" and "random" in fail_seeds))
sys.exit(1 if argv[0] in fail_commands or failing_seed else 0)
"""


class FakeBaoBase:
    """A bao-base directory holding only the stand-in `run`, and a working directory to run from.

    The long-run scripts reach every other command through `$BAO_BASE_DIR/run`, so pointing
    BAO_BASE_DIR here drives the real scripts end to end with nothing real run underneath.
    """

    def __init__(self, root: Path):
        self.work = root / "work"
        self.work.mkdir()
        self._base = root / "bao-base"
        self._base.mkdir()
        self._record = root / "calls.jsonl"
        self._record.touch()
        run = self._base / "run"
        run.write_text(
            _FAKE_RUN.format(python=sys.executable, record=str(self._record), test_long=str(_BIN_DIR / "test-long.py"))
        )
        run.chmod(0o755)
        # yarn puts a `run` of its own (`yarn run`) on PATH inside every script, so a bare `run` reaches
        # yarn instead of bao-base; this stands in for it
        self._decoy_path = root / "decoy-path"
        self._decoy_path.mkdir()
        decoy = self._decoy_path / "run"
        decoy.write_text('#!/bin/sh\necho "decoy run on PATH: $*"\nexit 1\n')
        decoy.chmod(0o755)
        self._env = {**os.environ, "BAO_BASE_DIR": str(self._base)}
        self._env.pop("FOUNDRY_FUZZ_RUNS", None)

    def run_script(self, script, *args, fail_commands=(), fail_seeds=(), env=None, in_bao_base=False):
        """Run the real bin/<script>.py from the working directory; the completed process.

        `in_bao_base` runs it the way `yarn` does inside bao-base itself: from the bao-base directory,
        where `run` sets BAO_BASE_DIR to ".", with yarn's own `run` on PATH.
        """
        process_env = {
            **self._env,
            "FAKE_RUN_FAIL_COMMANDS": " ".join(fail_commands),
            "FAKE_RUN_FAIL_SEEDS": " ".join(fail_seeds),
            **(env or {}),
        }
        if in_bao_base:
            process_env["BAO_BASE_DIR"] = "."
            process_env["PATH"] = f"{self._decoy_path}{os.pathsep}{process_env['PATH']}"
        return subprocess.run(
            [sys.executable, str(_BIN_DIR / f"{script}.py"), *args],
            cwd=self._base if in_bao_base else self.work,
            env=process_env,
            capture_output=True,
            text=True,
            check=False,
        )

    def calls(self, command=None):
        """Every call the stand-in `run` received, in order, optionally only those of one command."""
        calls = [json.loads(line) for line in self._record.read_text().splitlines()]
        return [call for call in calls if command is None or call["argv"][0] == command]

    def seeds(self):
        """The --fuzz-seed of each `run test` call, in order."""
        return [call["argv"][call["argv"].index("--fuzz-seed") + 1] for call in self.calls("test")]

    def logs(self):
        """The log files in the working directory's tmp/, by name."""
        return sorted(path.name for path in (self.work / "tmp").glob("*.log"))


@pytest.fixture
def bao_base(tmp_path):
    return FakeBaoBase(tmp_path)
