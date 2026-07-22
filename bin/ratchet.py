"""The regression ratchet, shared by regression-of and duration-of.

A regression file (gas.txt, coverage.txt, a *-duration.txt, ...) is a git-tracked baseline. A run
extracts fresh numbers, compares them against that baseline, and rewrites the file only when something
changed - so the file stays anchored at the committed values and the run fails until a real change is
committed. This module owns that decision once, so the two wrappers do not each re-implement it.

The baseline is the git INDEX version (`git show :<file>`), so staging an updated file is enough to
compare against it without committing. A MISSING baseline is not silently treated as empty: `resolve`
distinguishes the four states below and, for a file that is gone when it should be present, raises with
the git command that restores it - it never runs a state-changing git command itself.
"""

import difflib
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path


class BaselineMissing(Exception):
    """The regression file is absent when it should be present; the message is the fix to offer."""


class CompareFailed(Exception):
    """A type's compare script exited abnormally (neither held nor changed).

    Carries the script's exit code (always > 1) and its stderr report, so a caller can surface the
    report and propagate the exact code rather than collapsing every failure to one status.
    """

    def __init__(self, code: int, report: str):
        super().__init__(report)
        self.code = code
        self.report = report


@dataclass
class Verdict:
    """The outcome of a ratchet check: whether the baseline moved, and the report of what moved."""

    changed: bool
    report: str


def _object_in_git(ref: str) -> bool:
    """Whether `ref` (e.g. ':path' for the index, 'HEAD:path' for the commit) names a stored object."""
    return subprocess.run(["git", "cat-file", "-e", ref], capture_output=True).returncode == 0


def resolve(regression_file: str) -> str:
    """Return the baseline text for `regression_file`, read from the git index.

    Four states, by whether the index (`:file`) and HEAD hold the file and whether the working copy
    exists:
      - index present, working copy present -> the index content is the baseline
      - index present, working copy ABSENT  -> BaselineMissing, offering `git restore <file>`
      - index ABSENT, HEAD has it           -> BaselineMissing, offering `git restore --staged --worktree <file>`
      - index ABSENT, HEAD lacks it         -> "" (never tracked; the caller writes the first version)

    Only reads git state; for the two missing cases it names the command the user should run rather
    than running it.
    """
    index_ref = f":{regression_file}"
    if _object_in_git(index_ref):
        if not Path(regression_file).exists():
            raise BaselineMissing(
                f"{regression_file} is absent from the working tree. "
                f"Restore it from git: git restore {regression_file}"
            )
        return subprocess.run(
            ["git", "show", index_ref], capture_output=True, text=True, check=True
        ).stdout
    if _object_in_git(f"HEAD:{regression_file}"):
        raise BaselineMissing(
            f"{regression_file} has a staged deletion, so there is no baseline to check against. "
            f"Restore it from git: git restore --staged --worktree {regression_file}"
        )
    return ""


def apply(regression_file: str, baseline_text: str, fresh_text: str, compare_script=None) -> Verdict:
    """Compare `fresh_text` against `baseline_text`; rewrite `regression_file` only on a change.

    With `compare_script` (a `compare-<type>.py` path) the type's tolerance/ratchet merge decides
    (exit 0 held, 1 changed, anything higher an error); without one, any textual difference is a change
    (the coverage/sizes path). The merged output - or, in the fallback, the fresh text - is written
    only when something changed, so a held run leaves the file untouched.
    """
    if compare_script is not None:
        merged, report, code = _run_compare(compare_script, baseline_text, fresh_text)
        if code > 1:
            raise CompareFailed(code, report)
        if code == 1:
            Path(regression_file).write_text(merged)
            return Verdict(changed=True, report=report)
        return Verdict(changed=False, report=report)
    if fresh_text == baseline_text:
        return Verdict(changed=False, report="")
    Path(regression_file).write_text(fresh_text)
    return Verdict(changed=True, report=_diff(baseline_text, fresh_text, regression_file))


def _run_compare(compare_script, baseline_text: str, fresh_text: str):
    """Run `compare_script <baseline> <fresh>` on temp files; return (merged_stdout, report_stderr, code).

    The compare scripts take two positional file paths, so the texts are written out first. `sys.executable`
    is the bin uv interpreter (this module runs under it), so pandas/forge_tables resolve for the compare.
    """
    with tempfile.TemporaryDirectory() as directory:
        baseline = Path(directory) / "baseline.txt"
        fresh = Path(directory) / "fresh.txt"
        baseline.write_text(baseline_text)
        fresh.write_text(fresh_text)
        result = subprocess.run(
            [sys.executable, str(compare_script), str(baseline), str(fresh)],
            capture_output=True,
            text=True,
        )
    return result.stdout, result.stderr, result.returncode


def _diff(baseline_text: str, fresh_text: str, label: str) -> str:
    """A unified diff of baseline vs fresh, for the fallback path's change report."""
    return "".join(
        difflib.unified_diff(
            baseline_text.splitlines(keepends=True),
            fresh_text.splitlines(keepends=True),
            fromfile=f"{label} (baseline)",
            tofile=f"{label} (fresh)",
        )
    )
