"""Tests for bin/doctor.py — repo-health checks (remapping consistency + submodule-tree health).

The module guards its execution under `if __name__ == "__main__"`, so loading it by path is
side-effect-free. Pure functions are exercised directly; the git-based checks run against synthetic
repositories built in `tmp_path`, so the tests are isolated and repeatable. Each test names the single
behaviour it verifies.
"""

import importlib.util
import json
import pathlib
import subprocess

# Load bin/doctor.py by path (import-safe — see module guard). This file lives in test/bin/, so the
# repo root (containing bin/) is two parents up.
_module_path = pathlib.Path(__file__).resolve().parents[2] / "bin" / "doctor.py"
_spec = importlib.util.spec_from_file_location("doctor", _module_path)
doctor = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(doctor)


def _git(repo: pathlib.Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True)


def _init_repo(path: pathlib.Path) -> pathlib.Path:
    path.mkdir(parents=True, exist_ok=True)
    _git(path, "init", "-q")
    _git(path, "config", "user.email", "doctor-test@example.com")
    _git(path, "config", "user.name", "doctor-test")
    return path


# ── strip_context_prefix: foundry's `context:prefix=target` reduces to the bare `prefix=target` ──
def test_strip_context_prefix_removes_foundry_context():
    assert doctor.strip_context_prefix("lib/harbor/:src/=lib/harbor/src/") == "src/=lib/harbor/src/"


def test_strip_context_prefix_passes_through_plain_remapping():
    assert doctor.strip_context_prefix("@bao/=lib/bao-base/src/") == "@bao/=lib/bao-base/src/"


# ── remapping_problems: foundry (context) vs wake (bare) are consistent once context is stripped ──
def test_remapping_problems_consistent_when_only_difference_is_foundry_context():
    foundry = ["lib/harbor/:src/=lib/harbor/src/", "@bao/=lib/bao-base/src/"]
    wake = ["src/=lib/harbor/src/", "@bao/=lib/bao-base/src/"]
    assert doctor.remapping_problems(foundry, wake) == []


def test_remapping_problems_reports_a_real_path_mismatch():
    foundry = ["@bao/=lib/bao-base/src/"]
    wake = ["@bao/=lib/harbor/lib/bao-base/src/"]
    problems = doctor.remapping_problems(foundry, wake)
    assert problems and "Remapping mismatch" in problems[0]
    assert "@bao/=lib/bao-base/src/" in problems[0]  # foundry-only side
    assert "@bao/=lib/harbor/lib/bao-base/src/" in problems[0]  # wake-only side


# ── ghost_submodules: an unregistered nested git repo is a ghost; gitignored/registered ones aren't ──
def test_ghost_none_in_clean_repo(tmp_path):
    repo = _init_repo(tmp_path / "host")
    (repo / "file.txt").write_text("x")
    _git(repo, "add", ".")
    _git(repo, "commit", "-qm", "init")
    assert doctor.ghost_submodules(repo) == []


def test_ghost_detected_even_inside_an_untracked_parent(tmp_path):
    # The case that defeated the first implementation: git collapses an all-untracked parent to
    # `?? lib/`, hiding the nested repo. --untracked-files=all lists `?? lib/ghost/` instead.
    repo = _init_repo(tmp_path / "host")
    _init_repo(repo / "lib" / "ghost")  # untracked nested repo, parent has no tracked siblings
    assert doctor.ghost_submodules(repo) == ["lib/ghost"]


def test_ghost_not_flagged_when_gitignored(tmp_path):
    # A nested repo under a gitignored path (e.g. uv's `.tools/` sdist cache) must NOT be a ghost —
    # this is why the check uses `git status` (honours .gitignore), not a raw filesystem `.git` walk.
    repo = _init_repo(tmp_path / "host")
    (repo / ".gitignore").write_text(".tools/\n")
    _git(repo, "add", ".gitignore")
    _git(repo, "commit", "-qm", "ignore tools")
    _init_repo(repo / ".tools" / "cache" / "sdist")  # gitignored nested repo
    assert doctor.ghost_submodules(repo) == []


# ── submodule_status_problems: a recorded-but-not-checked-out submodule reports '-' uninitialized ──
def test_status_flags_uninitialized_submodule(tmp_path):
    sub = _init_repo(tmp_path / "sub")
    (sub / "a.txt").write_text("a")
    _git(sub, "add", ".")
    _git(sub, "commit", "-qm", "sub")
    host = _init_repo(tmp_path / "host")
    _git(host, "-c", "protocol.file.allow=always", "submodule", "add", str(sub), "lib/sub")
    _git(host, "commit", "-qm", "add sub")
    _git(host, "submodule", "deinit", "-f", "lib/sub")  # registered but not checked out → '-'
    problems = doctor.submodule_status_problems(host)
    assert any("lib/sub" in p and "uninitialized" in p for p in problems)


# ── submodule_url_drift: .gitmodules url changed without `git submodule sync` → stale .git/config ──
def test_url_drift_detected_when_gitmodules_url_changes(tmp_path):
    sub = _init_repo(tmp_path / "sub")
    (sub / "a.txt").write_text("a")
    _git(sub, "add", ".")
    _git(sub, "commit", "-qm", "sub")
    host = _init_repo(tmp_path / "host")
    _git(host, "-c", "protocol.file.allow=always", "submodule", "add", str(sub), "lib/sub")
    _git(host, "commit", "-qm", "add sub")
    # change the committed url but do NOT `git submodule sync`, so .git/config stays stale
    _git(host, "config", "-f", ".gitmodules", "submodule.lib/sub.url", "https://example.com/moved.git")
    drift = doctor.submodule_url_drift(host)
    assert any("lib/sub" in display for display, _gm, _gc in drift)


# ── remapping_problems (item 6): a wake entry carrying foundry's context syntax names the bare fix ──
def test_remapping_problems_flags_wake_context_syntax():
    foundry = ["lib/harbor/:src/=lib/harbor/src/"]
    wake = ["lib/harbor/:src/=lib/harbor/src/"]  # copied foundry's context form verbatim — Wake can't use it
    problems = doctor.remapping_problems(foundry, wake)
    assert problems
    assert "context remappings" in problems[0]
    assert "use the bare form `src/=lib/harbor/src/`" in problems[0]


# ── foundry_lock_problems (item 3): a submodule whose checked-out commit != foundry.lock's pinned rev ──
def _add_submodule(host: pathlib.Path, sub: pathlib.Path, path: str = "lib/sub") -> str:
    _git(host, "-c", "protocol.file.allow=always", "submodule", "add", str(sub), path)
    _git(host, "commit", "-qm", f"add {path}")
    return subprocess.run(
        ["git", "-C", str(host / path), "rev-parse", "HEAD"], check=True, capture_output=True, text=True
    ).stdout.strip()


def _commit_one(repo: pathlib.Path) -> None:
    (repo / "a.txt").write_text("a")
    _git(repo, "add", ".")
    _git(repo, "commit", "-qm", "content")


def test_foundry_lock_problems_none_when_no_lock(tmp_path):
    host = _init_repo(tmp_path / "host")
    assert doctor.foundry_lock_problems(host) == []


def test_foundry_lock_problems_passes_when_pin_matches(tmp_path):
    sub = _init_repo(tmp_path / "sub")
    _commit_one(sub)
    host = _init_repo(tmp_path / "host")
    sha = _add_submodule(host, sub)
    (host / "foundry.lock").write_text(json.dumps({"lib/sub": {"tag": {"name": "v1", "rev": sha}}}))
    assert doctor.foundry_lock_problems(host) == []


def test_foundry_lock_problems_flags_stale_pin(tmp_path):
    sub = _init_repo(tmp_path / "sub")
    _commit_one(sub)
    host = _init_repo(tmp_path / "host")
    _add_submodule(host, sub)
    (host / "foundry.lock").write_text(json.dumps({"lib/sub": {"tag": {"name": "v1", "rev": "0" * 40}}}))
    problems = doctor.foundry_lock_problems(host)
    assert any("lib/sub" in p and "foundry.lock pins" in p for p in problems)
