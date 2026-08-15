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


def test_foundry_lock_problems_flags_stale_pin_with_forge_fix(tmp_path):
    # foundry.lock is forge-managed; the fix must be a forge command, NOT git add / git submodule
    # update (which only move the gitlink and leave the lock stale — the real-world failure that
    # prompted this). A branch pin must also note that forge update follows the branch HEAD.
    sub = _init_repo(tmp_path / "sub")
    _commit_one(sub)
    host = _init_repo(tmp_path / "host")
    _add_submodule(host, sub)
    (host / "foundry.lock").write_text(json.dumps({"lib/sub": {"branch": {"name": "main", "rev": "0" * 40}}}))
    problems = doctor.foundry_lock_problems(host)
    assert problems
    p = problems[0]
    assert "lib/sub" in p and "foundry.lock pins" in p
    assert "forge update lib/sub" in p  # forge's resolution (re-fetch + rewrite the lock)
    assert "git -C lib/sub checkout" in p  # the other direction: adopt the locked commit
    assert "branch main" in p  # branch-vs-tag is surfaced


# ── claude_local_settings_problems: the machine-local settings file must stay out of the repo ──
# `.claude/settings.local.json` is a per-machine override. Committing it publishes one developer's
# permission grants to everyone and makes them a reviewable part of the source, which is how a loose
# rule outlives the session that needed it. Both halves are required: untracking without ignoring
# lets the next `git add .` bring it back, and ignoring an already-tracked file does nothing.
def _write_local_settings(repo: pathlib.Path, allow: list[str], *, tracked: bool = False) -> pathlib.Path:
    claude = repo / ".claude"
    claude.mkdir(parents=True, exist_ok=True)
    path = claude / "settings.local.json"
    path.write_text(json.dumps({"permissions": {"allow": allow, "deny": []}}))
    if tracked:
        _git(repo, "add", "-f", ".claude/settings.local.json")
        _git(repo, "commit", "-qm", "track settings")
    return path


def test_local_settings_clean_when_absent(tmp_path):
    repo = _init_repo(tmp_path / "host")
    assert doctor.claude_local_settings_problems(repo) == []


def test_local_settings_clean_when_present_and_ignored(tmp_path):
    repo = _init_repo(tmp_path / "host")
    _write_local_settings(repo, [])
    (repo / ".gitignore").write_text(".claude/settings.local.json\n")
    assert doctor.claude_local_settings_problems(repo) == []


def test_local_settings_flags_a_tracked_file(tmp_path):
    repo = _init_repo(tmp_path / "host")
    _write_local_settings(repo, [])
    _git(repo, "add", "-f", ".claude/settings.local.json")
    _git(repo, "commit", "-qm", "track it")
    problems = doctor.claude_local_settings_problems(repo)
    assert problems
    assert "git rm --cached" in problems[0]  # the repair must untrack, not just ignore


def test_local_settings_flags_present_but_not_ignored(tmp_path):
    # Only a rule inside the repo counts. A personal ~/.gitignore_global covers the author's machine
    # and nobody else's, so accepting it would report the repo protected while every teammate can
    # still commit the file — the exact route by which one gets committed. This machine HAS such a
    # global rule, so a check trusting `git check-ignore` alone passes here and fails for everyone.
    repo = _init_repo(tmp_path / "host")
    _write_local_settings(repo, [])
    problems = doctor.claude_local_settings_problems(repo)
    assert problems
    assert ".gitignore" in problems[0]


# ── claude_permission_scope_problems: three rule shapes that grant more than this repo's work needs ──
def test_permission_scope_clean_for_repo_scoped_rules(tmp_path):
    repo = _init_repo(tmp_path / "host")
    _write_local_settings(repo, ["Bash(forge build)", "Read(src/**)", "WebSearch"], tracked=True)
    assert doctor.claude_permission_scope_problems(repo) == []


def test_permission_scope_flags_a_path_outside_the_repo(tmp_path):
    repo = _init_repo(tmp_path / "host")
    _write_local_settings(repo, ["Read(//home/someone/github/other-project/**)"], tracked=True)
    problems = doctor.claude_permission_scope_problems(repo)
    assert problems
    assert "other-project" in problems[0]


def test_permission_scope_allows_the_claude_plans_repo(tmp_path):
    # CLAUDE.md *requires* committing to ~/.claude/plans after every plan update, so a rule reaching
    # it is the documented working mode, not an over-grant. Hardcoded rather than left to an ignore
    # file: a check that flags its own instructions gets switched off wholesale. Written with `~`,
    # which is the portable spelling — see the hardcoded-home test below.
    repo = _init_repo(tmp_path / "host")
    _write_local_settings(repo, ["Read(~/.claude/plans/**)"], tracked=True)
    assert doctor.claude_permission_scope_problems(repo) == []


def test_permission_scope_flags_a_hardcoded_home_path_even_when_the_scope_is_allowed(tmp_path):
    # The plans repo is exempt on SCOPE, but spelling it `/home/<user>/...` still ties the settings
    # file to one machine and one account. Scope and portability are independent defects, so the
    # exemption for the first must not suppress the second.
    repo = _init_repo(tmp_path / "host")
    _write_local_settings(repo, [f"Read(/{pathlib.Path.home()}/.claude/plans/**)"], tracked=True)
    problems = doctor.claude_permission_scope_problems(repo)
    assert problems
    assert "~" in problems[0]
    assert "outside this repository" not in problems[0]  # scope is fine; only the spelling is not


def test_permission_scope_reports_every_reason_a_rule_fails(tmp_path):
    # A rule can fail on more than one count, and reporting only the first sends the reader round the
    # loop again after they fix it.
    repo = _init_repo(tmp_path / "host")
    _write_local_settings(repo, [f"Read(/{pathlib.Path.home()}/github/elsewhere/**)"], tracked=True)
    problems = doctor.claude_permission_scope_problems(repo)
    assert problems
    assert "outside this repository" in problems[0]  # reason 1: scope
    assert "~" in problems[0]  # reason 2: machine-specific spelling


def test_permission_scope_flags_an_arbitrary_command_suffix(tmp_path):
    # `Bash(cd <repo> *)` matches `cd <repo> && rm -rf ~` — a trailing ` *` is a shell-continuation
    # hole, not an argument wildcard.
    repo = _init_repo(tmp_path / "host")
    _write_local_settings(repo, [f"Bash(cd {repo} *)"], tracked=True)
    problems = doctor.claude_permission_scope_problems(repo)
    assert problems
    assert any("&&" in p for p in problems)  # the message must explain WHY a trailing * is unsafe


def test_permission_scope_flags_a_wildcard_on_a_state_changing_command(tmp_path):
    repo = _init_repo(tmp_path / "host")
    _write_local_settings(repo, ["Bash(chmod:*)"], tracked=True)
    problems = doctor.claude_permission_scope_problems(repo)
    assert problems
    assert "chmod" in problems[0]


# ── tracked_but_ignored_problems: a .gitignore rule has no effect on an already-tracked file ──
def test_tracked_but_ignored_none_when_the_ignored_file_is_untracked(tmp_path):
    # The normal, healthy arrangement: the rule matches a file git never took under management.
    repo = _init_repo(tmp_path / "host")
    (repo / ".gitignore").write_text("*.log\n")
    (repo / "build.log").write_text("noise")
    _git(repo, "add", ".gitignore")
    _git(repo, "commit", "-qm", "ignore logs")
    assert doctor.tracked_but_ignored_problems(repo) == []


def test_tracked_but_ignored_flags_a_file_committed_before_its_ignore_rule(tmp_path):
    # The failure this catches: the file was committed first, so adding the rule later changes nothing
    # — git keeps tracking it and its edits keep landing in commits.
    repo = _init_repo(tmp_path / "host")
    (repo / "settings.local.json").write_text("{}")
    _git(repo, "add", "settings.local.json")
    _git(repo, "commit", "-qm", "add settings")
    (repo / ".gitignore").write_text("settings.local.json\n")
    _git(repo, "add", ".gitignore")
    _git(repo, "commit", "-qm", "ignore settings")

    problems = doctor.tracked_but_ignored_problems(repo)
    assert problems
    p = problems[0]
    assert "settings.local.json" in p
    assert ".gitignore:1" in p  # the rule that matches, so its author can judge which side is wrong
    assert "git rm --cached" in p  # untrack, keeping the working-tree copy


def test_tracked_but_ignored_lists_every_matching_file(tmp_path):
    # A wildcard rule usually catches a whole set; each tracked member must be named individually
    # rather than the report stopping at the first.
    repo = _init_repo(tmp_path / "host")
    for name in ("one.json", "two.json", "three.json"):
        (repo / name).write_text("{}")
    _git(repo, "add", ".")
    _git(repo, "commit", "-qm", "add generated files")
    (repo / ".gitignore").write_text("*.json\n")
    _git(repo, "add", ".gitignore")
    _git(repo, "commit", "-qm", "ignore generated files")

    problems = doctor.tracked_but_ignored_problems(repo)
    assert problems
    p = problems[0]
    assert "one.json" in p and "two.json" in p and "three.json" in p


def test_every_check_function_is_registered(tmp_path):
    # The guard for what actually went wrong: `tracked_but_ignored_problems` was written, tested by
    # hand, and then never added to the checks list, so it silently never ran. A check that exists
    # but is not registered is worse than one that does not exist — it reads as covered.
    repo = _init_repo(tmp_path / "host")
    registered = {check.name for check in doctor.build_checks(repo, [], [])}
    # submodule_status_problems is a building block of submodule_tree_problems, not a check itself.
    helpers = {"submodule_status_problems"}
    defined = {
        name for name in dir(doctor) if name.endswith("_problems") and not name.startswith("_") and name not in helpers
    }
    unregistered = {
        name for name in defined if not any(name.split("_problems")[0].split("_")[0] in check for check in registered)
    }
    assert not unregistered, f"check functions never reached the checks list: {sorted(unregistered)}"


# ── scope is checked on TRACKED settings only: an untracked file is not the repository's business ──
def test_permission_scope_ignores_an_untracked_settings_file(tmp_path):
    # The check's whole justification is that these grants are published to everyone who clones and
    # outlive the session that needed them. That holds only while the file is in the index. Untracked,
    # it is one developer's own machine, and doctor is a repo-health tool. Checking it anyway also puts
    # the two checks in conflict: untracking is the fix the sibling check asks for, and it would leave
    # this one red forever — a permanently-red check is one people stop reading.
    repo = _init_repo(tmp_path / "host")
    _write_local_settings(repo, ["Read(//home/someone/elsewhere/**)"])  # untracked
    assert doctor.claude_permission_scope_problems(repo) == []


def test_permission_scope_flags_the_same_file_once_it_is_tracked(tmp_path):
    repo = _init_repo(tmp_path / "host")
    _write_local_settings(repo, ["Read(//home/someone/elsewhere/**)"], tracked=True)
    problems = doctor.claude_permission_scope_problems(repo)
    assert problems
    assert "elsewhere" in problems[0]
