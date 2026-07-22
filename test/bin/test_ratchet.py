"""Tests for bin/ratchet.py - the shared regression ratchet.

`resolve` reads a regression file's baseline from the git INDEX and distinguishes the four states of a
possibly-missing file, OFFERING a git-restore command for the deleted cases without ever running a
state-changing git command. `apply` compares a fresh run against that baseline and rewrites the file
only on a change - via the type's compare script (tolerance/ratchet) when there is one, or exact-match
(any difference is a change) for the types without one (coverage, sizes).
"""

import os
import shutil
import stat
from pathlib import Path

import pytest

import ratchet

BIN = Path(__file__).parent.parent.parent / "bin"
COMPARE_GAS = str(BIN / "compare-gas.py")


# ── format helpers: the shapes compare-gas.py parses (fresh extract, new-format baseline) ──

def _fresh(rows: dict) -> str:
    lines = ["src/X.sol:X", "| function name | max |", "|---|---|"]
    lines += [f"| {name} | {int(value)} |" for name, value in rows.items()]
    return "\n".join(lines) + "\n"


def _committed(rows: dict) -> str:
    header = "# regression: better=lower abs=500 rel=0.001 display={:.3e} ratchet=on"
    lines = [header, "src/X.sol:X", "| function name | max | display |", "|---|---|---|"]
    lines += [f"| {name} | {int(value)} | {value:.3e} |" for name, value in rows.items()]
    return "\n".join(lines) + "\n"


def _stub_compare(directory: Path, exit_code: int, merged: str = "MERGED\n", report: str = "moved\n") -> str:
    """A compare script honouring the contract - two positional paths in; merged on stdout, report on
    stderr, an exit code out - but with a fixed, chosen result, to drive apply's branches directly."""
    script = directory / f"stub_compare_{exit_code}.py"
    script.write_text(
        "import sys\n"
        f"sys.stdout.write({merged!r})\n"
        f"sys.stderr.write({report!r})\n"
        f"sys.exit({exit_code})\n"
    )
    return str(script)


# ── resolve: the four baseline states ────────────────────────────────────────

def test_resolve_returns_the_committed_baseline(repo):
    # Present in the index and the working tree -> the index content is the baseline.
    repo.commit("BASELINE\n")
    assert ratchet.resolve(repo.file) == "BASELINE\n"


def test_resolve_reads_the_index_not_the_working_tree(repo):
    # Staging sets the baseline; a later unstaged working-tree edit must not move it.
    repo.commit("COMMITTED\n")
    repo.stage("STAGED\n")
    repo.write("WORKTREE\n")
    assert ratchet.resolve(repo.file) == "STAGED\n"


def test_resolve_offers_plain_restore_when_worktree_deleted(repo):
    # The index still holds the file, only the working copy is gone -> restore reads it from the index.
    repo.commit("BASELINE\n")
    repo.delete_worktree()
    with pytest.raises(ratchet.BaselineMissing) as excinfo:
        ratchet.resolve(repo.file)
    message = str(excinfo.value)
    assert f"git restore {repo.file}" in message
    assert "--staged" not in message


def test_resolve_offers_staged_worktree_restore_on_staged_deletion(repo):
    # The index has no version (the deletion is staged) but HEAD does -> only --staged --worktree,
    # which restores from HEAD, brings it back; a plain `git restore` would fail.
    repo.commit("BASELINE\n")
    repo.stage_deletion()
    with pytest.raises(ratchet.BaselineMissing) as excinfo:
        ratchet.resolve(repo.file)
    assert f"git restore --staged --worktree {repo.file}" in str(excinfo.value)


def test_resolve_returns_empty_for_a_never_tracked_file(repo):
    # Not in the index or HEAD -> no baseline yet; the caller generates the first version.
    assert ratchet.resolve(repo.file) == ""


def test_resolve_never_runs_a_mutating_git_command(repo, tmp_path, monkeypatch):
    # The tool OFFERS git commands; it must never RUN a state-changing one. A PATH-shim `git` records
    # every subcommand and forwards to the real git; assert only reads (cat-file, show) were used. The
    # present state exercises both the existence probe and the `git show` read.
    real_git = shutil.which("git")
    log = tmp_path / "git-calls.log"
    log.write_text("")
    shim_dir = tmp_path / "shim"
    shim_dir.mkdir()
    shim = shim_dir / "git"
    shim.write_text(f'#!/usr/bin/env bash\nprintf "%s\\n" "$1" >> {str(log)!r}\nexec {real_git!r} "$@"\n')
    shim.chmod(shim.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

    repo.commit("BASELINE\n")  # commit's mutating git runs BEFORE the shim is on PATH
    monkeypatch.setenv("PATH", str(shim_dir) + os.pathsep + os.environ["PATH"])
    assert ratchet.resolve(repo.file) == "BASELINE\n"

    used = [line for line in log.read_text().split() if line]
    assert used, "resolve did not go through the shim - the guard proved nothing"
    assert set(used) <= {"cat-file", "show"}, f"resolve ran a non-read git subcommand: {used}"


# ── apply: the compare-script path (gas) ─────────────────────────────────────

def test_apply_holds_and_leaves_the_file_untouched_on_no_change(repo):
    repo.write("ORIGINAL\n")  # a working-tree file a held run must not touch
    verdict = ratchet.apply(repo.file, _committed({"foo": 100000}), _fresh({"foo": 100000}), COMPARE_GAS)
    assert verdict.changed is False
    assert repo.read() == "ORIGINAL\n"


def test_apply_writes_the_merged_baseline_on_a_change(repo):
    repo.write("ORIGINAL\n")
    # +100000 breaks tolerance -> compare exits 1 -> apply adopts the merged output.
    verdict = ratchet.apply(repo.file, _committed({"foo": 100000}), _fresh({"foo": 200000}), COMPARE_GAS)
    assert verdict.changed is True
    assert "200000" in repo.read()


def test_apply_raises_when_the_compare_script_fails(repo, tmp_path):
    stub = _stub_compare(tmp_path, exit_code=2, report="usage error\n")
    with pytest.raises(ratchet.CompareFailed) as excinfo:
        ratchet.apply(repo.file, "BASE\n", "FRESH\n", stub)
    assert excinfo.value.code == 2  # the exact code is preserved, not collapsed
    assert "usage error" in excinfo.value.report


def test_apply_first_generation_writes_the_whole_file(repo):
    # An empty baseline (never-tracked) -> every row is new -> compare exits 1 -> the file is created.
    assert not repo.exists()
    verdict = ratchet.apply(repo.file, "", _fresh({"foo": 100000}), COMPARE_GAS)
    assert verdict.changed is True
    assert repo.exists()
    assert "100000" in repo.read()


# ── apply: the exact-match fallback (types with no compare script: coverage, sizes) ──

def test_apply_fallback_holds_identical_text(repo):
    repo.write("SAME\n")
    verdict = ratchet.apply(repo.file, "SAME\n", "SAME\n", None)
    assert verdict.changed is False
    assert repo.read() == "SAME\n"


def test_apply_fallback_writes_the_fresh_text_on_any_difference(repo):
    repo.write("OLD\n")
    verdict = ratchet.apply(repo.file, "OLD\n", "NEW\n", None)
    assert verdict.changed is True
    assert repo.read() == "NEW\n"
