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
import typing

import pytest

# Load bin/doctor.py by path (import-safe — see module guard). This file lives in tests/bin/, so the
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
    assert problems and "The remappings in foundry.toml and wake.toml are different" in problems[0]
    assert "@bao/=lib/bao-base/src/" in problems[0]  # foundry-only side
    assert "@bao/=lib/harbor/lib/bao-base/src/" in problems[0]  # wake-only side


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
    reported = "\n".join(doctor.submodule_url_drift_problems(host))
    assert "Repair: yarn dep sync (this copies the URLs from .gitmodules to .git/config)" in reported, reported


def test_url_drift_inside_a_dependency_is_not_reported(tmp_path):
    # A dependency's own .gitmodules and its nested checkouts are its business; only this repository's
    # submodule urls are this repository's to keep in step.
    host = _nest(tmp_path)
    dependency = host / "lib" / "dep"
    _git(dependency, "config", "-f", ".gitmodules", "submodule.lib/child.url", "https://example.com/moved.git")

    assert doctor.submodule_url_drift(host) == []


# ── remapping_problems (item 6): a wake entry carrying foundry's context syntax names the bare fix ──
def test_remapping_problems_flags_wake_context_syntax():
    foundry = ["lib/harbor/:src/=lib/harbor/src/"]
    wake = ["lib/harbor/:src/=lib/harbor/src/"]  # copied foundry's context form verbatim — Wake can't use it
    problems = doctor.remapping_problems(foundry, wake)
    assert problems
    assert "context remappings" in problems[0]
    assert "Use `src/=lib/harbor/src/` instead" in problems[0]


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


# ── unused_file_problems: every Solidity file is reached from a test, a script or a tool-built directory ──
#
# Each test builds a small forge project in tmp_path, so the import graph read is the one forge resolves.
_SOLIDITY_HEADER = "// SPDX-License-Identifier: MIT\npragma solidity >=0.8.0;\n"


def _forge_project(root: pathlib.Path, files: dict[str, str]) -> pathlib.Path:
    """A git repo at `root` holding `files` (path -> body), each body given the licence and pragma lines."""
    _init_repo(root)
    for path, body in files.items():
        (root / path).parent.mkdir(parents=True, exist_ok=True)
        (root / path).write_text(_SOLIDITY_HEADER + body)
    return root


def _used_by_a_test_and_a_script() -> dict[str, str]:
    return {
        "src/A.sol": "contract A {}\n",
        "src/B.sol": "contract B {}\n",
        "test/A.t.sol": 'import {A} from "../src/A.sol";\ncontract ATest {}\n',
        "script/Deploy.s.sol": 'import {B} from "../src/B.sol";\ncontract Deploy {}\n',
    }


def test_unused_files_none_when_every_file_is_reached(tmp_path):
    # files a test or a script imports are in use
    repo = _forge_project(tmp_path / "host", _used_by_a_test_and_a_script())
    assert doctor.unused_file_problems(repo) == []


def test_unused_files_none_in_a_project_with_no_sources(tmp_path):
    # forge compiles nothing and writes no cache, which is not a fault when there is nothing to compile
    repo = _init_repo(tmp_path / "host")
    assert doctor.unused_file_problems(repo) == []


def test_unused_files_lists_an_unimported_mock(tmp_path):
    repo = _forge_project(
        tmp_path / "host", _used_by_a_test_and_a_script() | {"test/mocks/MockC.sol": "contract MockC {}\n"}
    )
    problems = doctor.unused_file_problems(repo)
    assert len(problems) == 1
    assert "test/mocks/MockC.sol" in problems[0]
    assert "src/A.sol" not in problems[0]
    assert "src/B.sol" not in problems[0]


def test_unused_files_lists_a_dead_chain_whole(tmp_path):
    # a file imported only by an unused file is unused too, and is listed in the same run, not the next
    repo = _forge_project(
        tmp_path / "host",
        _used_by_a_test_and_a_script()
        | {
            "test/mocks/MockD.sol": "contract MockD {}\n",
            "test/helpers/Helper.sol": 'import {MockD} from "../mocks/MockD.sol";\ncontract Helper {}\n',
        },
    )
    problems = doctor.unused_file_problems(repo)
    assert len(problems) == 1
    lines = problems[0].splitlines()
    assert any(line.strip() == "test/helpers/Helper.sol" for line in lines)
    assert any("test/mocks/MockD.sol" in line and "used only by test/helpers/Helper.sol" in line for line in lines)


def test_unused_files_reads_an_import_listed_below_the_top_level(tmp_path):
    # forge tree lists a file's imports once, where the file first appears: here B's import of C appears only
    # inside the unused A's tree, and B's own top-level line is a bare "(*)"
    repo = _forge_project(
        tmp_path / "host",
        {
            "src/A.sol": 'import {B} from "./B.sol";\ncontract A {}\n',
            "src/B.sol": 'import {C} from "./C.sol";\ncontract B {}\n',
            "src/C.sol": "contract C {}\n",
            "test/B.t.sol": 'import {B} from "../src/B.sol";\ncontract BTest {}\n',
        },
    )
    problems = doctor.unused_file_problems(repo)
    assert len(problems) == 1
    listed = [line.strip() for line in problems[0].splitlines()[1:] if line.strip().startswith("src/")]
    assert listed == ["src/A.sol"]


@pytest.mark.parametrize("tag", ["oz-upgrades-from", "bao-upgrades-from"])
def test_unused_files_counts_an_upgrade_annotation_as_use(tmp_path, tag):
    # validate compiles the predecessor an upgrade annotation names, though nothing imports it
    repo = _forge_project(
        tmp_path / "host",
        {
            "src/Foo_v1.sol": "contract Foo_v1 {}\n",
            "src/Foo_v2.sol": f"/// @custom:{tag} src/Foo_v1.sol:Foo_v1\ncontract Foo_v2 {{}}\n",
            "test/Foo.t.sol": 'import {Foo_v2} from "../src/Foo_v2.sol";\ncontract FooTest {}\n',
        },
    )
    assert doctor.unused_file_problems(repo) == []


@pytest.mark.parametrize("directory", ["test/_sizes", "test/fixtures"])
def test_unused_files_tool_built_directories_are_entry_points(tmp_path, directory):
    # bin/sizes builds test/_sizes by path and the Python tests build test/fixtures by path, so what they
    # hold, and what it imports, is in use
    repo = _forge_project(
        tmp_path / "host",
        {
            "src/A.sol": "contract A {}\n",
            f"{directory}/Built.sol": 'import {A} from "../../src/A.sol";\ncontract Built {}\n',
        },
    )
    assert doctor.unused_file_problems(repo) == []


def test_unused_files_none_when_warnings_are_denied(tmp_path):
    # harbor and bao-base set deny = "warnings", under which forge keeps no build cache; the check must
    # not depend on one
    repo = _forge_project(tmp_path / "host", _used_by_a_test_and_a_script())
    (repo / "foundry.toml").write_text('[profile.default]\ndeny = "warnings"\n')
    assert doctor.unused_file_problems(repo) == []


def test_unused_files_reports_forge_tree_failing(tmp_path):
    # without the import graph nothing can be said, so forge's failure is this check's finding, not a crash
    repo = _forge_project(tmp_path / "host", _used_by_a_test_and_a_script())
    (repo / "foundry.toml").write_text("[profile.default\n")
    problems = doctor.unused_file_problems(repo)
    assert len(problems) == 1
    assert problems[0].startswith("forge tree failed")


def _with_forge_tree_output(monkeypatch, stdout: str) -> None:
    """Make `forge tree` print `stdout`; every other command runs for real."""
    real_run = subprocess.run

    def run(command, *args, **kwargs):
        if command[:2] == ["forge", "tree"]:
            return subprocess.CompletedProcess(command, 0, stdout=stdout, stderr="")
        return real_run(command, *args, **kwargs)

    monkeypatch.setattr(doctor.subprocess, "run", run)


def test_unused_files_reports_an_unrecognised_tree_line(tmp_path, monkeypatch):
    # the tree is a display format; a line it cannot read means the graph is unknown, not that nothing is unused
    repo = _forge_project(tmp_path / "host", {"src/A.sol": "contract A {}\n"})
    _with_forge_tree_output(monkeypatch, "src/A.sol >=0.8.0\n  something else\n")
    problems = doctor.unused_file_problems(repo)
    assert len(problems) == 1
    assert "a line doctor does not understand" in problems[0]
    assert "something else" in problems[0]


def test_unused_files_reports_a_tree_that_disagrees_with_the_disk(tmp_path, monkeypatch):
    # a source the tree does not list would be judged on no data at all
    repo = _forge_project(tmp_path / "host", {"src/A.sol": "contract A {}\n", "src/B.sol": "contract B {}\n"})
    _with_forge_tree_output(monkeypatch, "src/A.sol >=0.8.0\n")
    problems = doctor.unused_file_problems(repo)
    assert len(problems) == 1
    assert "src/B.sol" in problems[0]
    assert "on disk but not in forge tree" in problems[0]


def test_unused_file_check_runs_only_when_asked(tmp_path):
    # it cannot see uses from other repos or from Python, so a plain doctor run leaves it out
    repo = _init_repo(tmp_path / "host")
    by_default = {check.name for check in doctor.build_checks(repo, [], [], unused_files=False)}
    when_asked = {check.name for check in doctor.build_checks(repo, [], [], unused_files=True)}
    assert when_asked - by_default == {"no unused Solidity files"}


def test_every_check_function_is_registered(tmp_path, monkeypatch):
    # The guard for what actually went wrong: `tracked_but_ignored_problems` was written, tested by
    # hand, and then never added to the checks list, so it silently never ran. A check that exists
    # but is not registered is worse than one that does not exist — it reads as covered. Registered
    # means the function's findings reach a check, so each function is replaced by one returning a
    # marker of its own, and every marker must come out of `build_checks`. A function returning a
    # tuple of lists feeds one check per list, so it returns one marker per list.
    repo = _init_repo(tmp_path / "host")
    markers: set[str] = set()
    for name in dir(doctor):
        if name.startswith("_") or not name.endswith("_problems"):
            continue
        returned = typing.get_type_hints(getattr(doctor, name))["return"]
        per_check = typing.get_args(returned) if typing.get_origin(returned) is tuple else (returned,)
        lists = [[f"{name}[{index}]"] for index in range(len(per_check))]
        markers.update(marker for problems in lists for marker in problems)
        result = tuple(lists) if typing.get_origin(returned) is tuple else lists[0]
        monkeypatch.setattr(doctor, name, lambda *args, result=result, **kwargs: result)
    assert markers, "no check functions were found to stub"

    reported = {problem for check in doctor.build_checks(repo, [], [], unused_files=True) for problem in check.problems}
    assert markers <= reported, f"check functions whose findings reach no check: {sorted(markers - reported)}"


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


# ── submodule_problems: one finding per submodule, and silence about states that are normal ──
#
# It returns (versions, leftovers), split by what the reader must DO - a version is moved, staged or
# locked, and a leftover is deleted - because that is what each check's title has to be true of. Which
# list a finding lands in is asserted here rather than taken on trust, so a finding cannot migrate to
# a check whose title does not describe it.
def _submodule_at(host: pathlib.Path, sub: pathlib.Path, path: str = "lib/sub") -> str:
    _git(host, "-c", "protocol.file.allow=always", "submodule", "add", str(sub), path)
    _git(host, "commit", "-qm", f"add {path}")
    return subprocess.run(
        ["git", "-C", str(host / path), "rev-parse", "HEAD"], check=True, capture_output=True, text=True
    ).stdout.strip()


def test_submodule_problems_says_nothing_when_every_claim_agrees(tmp_path):
    sub = _init_repo(tmp_path / "sub")
    (sub / "a.txt").write_text("a")
    _git(sub, "add", ".")
    _git(sub, "commit", "-qm", "content")
    host = _init_repo(tmp_path / "host")
    sha = _submodule_at(host, sub)
    (host / "foundry.lock").write_text(json.dumps({"lib/sub": {"tag": {"name": "v1", "rev": sha}}}))

    assert doctor.submodule_problems(host, []) == ([], [])


def test_a_folder_holding_unpushed_commits_is_repaired_by_pushing_or_removing_them(tmp_path):
    # Making the repository point to a commit no remote holds breaks every other clone - the fault that
    # started this work - and `yarn dep sync` refuses to move a folder that holds one. So the repair
    # says to push first, or to remove the commits first.
    sub = _init_repo(tmp_path / "sub")
    (sub / "a.txt").write_text("a")
    _git(sub, "add", ".")
    _git(sub, "commit", "-qm", "content")
    host = _init_repo(tmp_path / "host")
    _submodule_at(host, sub)
    (host / "lib" / "sub" / "a.txt").write_text("only here\n")
    _git(host / "lib" / "sub", "commit", "-qam", "only here")

    problems, _ = doctor.submodule_problems(host, [])

    repair = next(line for line in problems[0].splitlines() if "Repair:" in line)
    assert "git -C lib/sub push" in repair, repair
    assert "remove the unpushed commit" in repair, repair


def test_submodule_problems_reports_one_finding_carrying_its_own_repair(tmp_path):
    # What replaced four checks reporting the same cause four ways with two contradictory repairs. A folder
    # moved to a newer commit than the repository points to is a move not yet added, and only the user
    # knows whether it was meant: the repair names keeping it and going back, and nothing else. The newer
    # commit is published and new to the repository, so a plain sync is what keeps it.
    sub = _init_repo(tmp_path / "sub")
    (sub / "a.txt").write_text("a")
    _git(sub, "add", ".")
    _git(sub, "commit", "-qm", "content")
    host = _init_repo(tmp_path / "host")
    recorded = _submodule_at(host, sub)
    # The newer commit is the remote's, so nothing in the folder is only on this computer.
    commit_in(sub, "moved on")
    _git(host / "lib" / "sub", "pull", "-q", "--ff-only")
    moved = subprocess.run(
        ["git", "-C", str(host / "lib" / "sub"), "rev-parse", "HEAD"], check=True, capture_output=True, text=True
    ).stdout.strip()

    problems, leftovers = doctor.submodule_problems(host, [])

    assert len(problems) == 1 and leftovers == [], (problems, leftovers)
    assert problems[0].startswith("lib/sub: the folder has a newer commit than the one host points to"), problems[0]
    # The two commits arrive as aligned rows, the commit first, then where it is.
    assert f"{moved[:10]}  in the lib/sub folder" in problems[0], problems[0]
    assert f"{recorded[:10]}  host points to" in problems[0], problems[0]
    assert (
        "Repair: To keep the folder's version: yarn dep sync (host then points to it). "
        "To go back to the version host points to: yarn dep sync lib/sub."
    ) in problems[0], problems[0]


# ── the coverage the four superseded checks had, which iterating foundry.lock alone did not ──
def _nest(tmp_path: pathlib.Path) -> pathlib.Path:
    """A host with lib/dep -> lib/child, and lib/unlocked which foundry.lock never mentions."""
    for name in ("child", "dep", "unlocked"):
        repo = _init_repo(tmp_path / "remotes" / name)
        (repo / "a.txt").write_text("a")
        _git(repo, "add", ".")
        _git(repo, "commit", "-qm", "content")
    _git(
        tmp_path / "remotes" / "dep",
        "-c",
        "protocol.file.allow=always",
        "submodule",
        "add",
        str(tmp_path / "remotes" / "child"),
        "lib/child",
    )
    _git(tmp_path / "remotes" / "dep", "commit", "-qm", "add child")
    host = _init_repo(tmp_path / "host")
    for name in ("dep", "unlocked"):
        _git(
            host,
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            str(tmp_path / "remotes" / name),
            f"lib/{name}",
        )
    _git(host, "-c", "protocol.file.allow=always", "submodule", "update", "--init", "--recursive")
    _git(host, "commit", "-qm", "add deps")
    sha = subprocess.run(
        ["git", "-C", str(host / "lib" / "dep"), "rev-parse", "HEAD"], check=True, capture_output=True, text=True
    ).stdout.strip()
    (host / "foundry.lock").write_text(json.dumps({"lib/dep": {"tag": {"name": "v1", "rev": sha}}}))
    return host


def test_a_stray_clone_in_our_own_tree_is_reported(tmp_path):
    # Ours to delete, and invisible to everyone else. It is in no .gitmodules and no foundry.lock, so
    # nothing that iterates either would ever look at it.
    host = _nest(tmp_path)
    _init_repo(host / "lib" / "strayclone")

    versions, leftovers = doctor.submodule_problems(host, [])

    assert any(p.startswith("lib/strayclone:") and "is not a submodule" in p for p in leftovers), leftovers
    assert not any("strayclone" in p for p in versions), "a directory to delete is not a version to move"


def commit_in(checkout: pathlib.Path, message: str) -> None:
    """Move a checkout to a new commit of its own, off whatever its parent records."""
    (checkout / "a.txt").write_text(f"{message}\n")
    _git(checkout, "commit", "-qam", message)


@pytest.mark.parametrize("shape", ["off its record", "not checked out", "holding litter"])
def test_a_dependencys_own_nested_submodules_are_not_reported(tmp_path, shape):
    # A dependency's nested submodules are its own lockfile: nothing here builds from one unless a remapping
    # names it, so whatever state it is in is not this repository's finding.
    host = _nest(tmp_path)
    child = host / "lib" / "dep" / "lib" / "child"
    if shape == "off its record":
        commit_in(child, "moved on")
    elif shape == "not checked out":
        _git(host / "lib" / "dep", "submodule", "deinit", "-q", "-f", "lib/child")
    else:
        _init_repo(child / "lib" / "orphan")

    problems = sum(doctor.submodule_problems(host, []), [])

    assert not any(p.startswith(("lib/dep:", "lib/dep/lib/child:")) for p in problems), problems


def test_a_remapped_nested_path_off_its_record_is_reported(tmp_path):
    # Once a remapping names a nested path, the build reads it, so its being off the commit the dependency
    # records is this repository's finding - and sync is what brings it back.
    host = _nest(tmp_path)
    commit_in(host / "lib" / "dep" / "lib" / "child", "moved on")

    problems, _ = doctor.submodule_problems(host, ["child/=lib/dep/lib/child/"])

    finding = next((p for p in problems if p.startswith("lib/dep:")), None)
    assert finding is not None, problems
    assert "lib/dep/lib/child" in finding and "Repair: yarn dep sync (" in finding, finding


def test_a_dependency_at_the_wrong_version_with_leftovers_is_in_both_lists(tmp_path):
    # Two faults, two commands, and `condition` names only the more urgent of them. Reading leftovers
    # through it had the leftovers check report all-clear while the version finding beside it named a
    # stranded directory - one tree, two answers, which is what splitting the check must not cost.
    host = _nest(tmp_path)
    _init_repo(host / "lib" / "dep" / "lib" / "orphan")
    commit_in(host / "lib" / "dep", "moved on")

    versions, leftovers = doctor.submodule_problems(host, [])

    assert any(p.startswith("lib/dep: the folder has a newer commit than the one host points to") for p in versions), (
        versions
    )
    assert any(p.startswith("lib/dep: contains old git repositories") and "lib/orphan" in p for p in leftovers), leftovers
    # Each carries its own fault: the version finding does not name the old repositories, and the leftover
    # finding's repair is sync, which removes them.
    version_finding = next(p for p in versions if p.startswith("lib/dep:"))
    assert "lib/orphan" not in version_finding, version_finding
    assert "Repair: yarn dep sync" in next(p for p in leftovers if p.startswith("lib/dep:"))


def test_an_uninitialised_dependency_is_reported(tmp_path):
    # Enumerated from .gitmodules, so a dependency nothing has checked out is looked at all the same, and
    # checking it out at its record is sync's job.
    host = _nest(tmp_path)
    _git(host, "submodule", "deinit", "-q", "-f", "lib/unlocked")

    problems, _ = doctor.submodule_problems(host, [])

    finding = next((p for p in problems if p.startswith("lib/unlocked:")), "")
    assert finding.startswith("lib/unlocked: is in .gitmodules, but nothing is checked out in its folder"), problems
    assert "Repair: yarn dep sync (" in finding, finding


def test_a_hand_edited_file_in_a_dependency_is_not_a_finding(tmp_path):
    # Editing inside a dependency is what working in one looks like, not a defect.
    host = _nest(tmp_path)
    (host / "lib" / "dep" / "a.txt").write_text("edited by hand\n")

    assert [p for p in sum(doctor.submodule_problems(host, []), []) if p.startswith("lib/dep:")] == []


def test_an_unreadable_dependency_is_reported_in_gits_words(tmp_path):
    # With the gitdir unreadable nothing about the checkout can be compared, so git's refusal is the
    # finding, with the command that mends the gitdir - and no version claim nothing measured.
    host = _nest(tmp_path)
    _git(
        host,
        "config",
        "-f",
        str(host / ".git" / "modules" / "lib" / "dep" / "config"),
        "core.worktree",
        "../../../../nowhere/lib/dep",
    )

    problems = [p for p in doctor.submodule_problems(host, [])[0] if p.startswith("lib/dep:")]

    assert problems, "an unreadable dependency is a finding"
    assert problems[0].startswith("lib/dep: has a folder that git cannot read"), problems[0]
    assert "fatal:" in problems[0], problems[0]
    assert "Repair: yarn dep sync" in problems[0], problems[0]
    assert "commit than the one" not in problems[0], f"no comparison can be claimed: {problems[0]}"


# ── remapping_target_problems: every remapping leads to a path a submodule provides ──
def test_a_remapping_no_submodule_provides_is_reported(tmp_path):
    # The two shapes found in harbor-yield: a path inside a dependency that declares nothing there
    # (ds-test, dropped by forge-std) and a path no submodule declares at all (@uniswap). Each resolves no
    # import, and a nested one would be checked out by nothing.
    host = _nest(tmp_path)
    remappings = ["ds-test/=lib/dep/lib/ds-test/src/", "@uniswap/v3-core/=lib/v3-core/", "dep/=lib/dep/"]

    problems = doctor.remapping_target_problems(host, remappings)

    assert len(problems) == 1, problems
    listed = [line.strip() for line in problems[0].splitlines()[1:] if not line.strip().startswith("Repair:")]
    assert listed == ["ds-test/=lib/dep/lib/ds-test/src/", "@uniswap/v3-core/=lib/v3-core/"], problems[0]
    assert "Repair: remove each one from foundry.toml and from wake.toml" in problems[0], problems[0]


def test_a_remapping_into_a_dependency_not_checked_out_is_not_called_dead(tmp_path):
    # The path is missing because its dependency is not checked out - a finding of its own, repaired by
    # sync - not because nothing provides it.
    host = _nest(tmp_path)
    _git(host, "submodule", "deinit", "-q", "-f", "lib/unlocked")

    assert doctor.remapping_target_problems(host, ["unlocked/=lib/unlocked/src/"]) == []


# ── wake_scope_problems: wake compiles only what forge builds ──
#
# wake compiles every Solidity file in the project that wake.toml's exclude_paths does not cover; forge
# builds only its source, test and script directories and what they import. Each test builds a project
# in tmp_path, so the directories read are the ones `forge config` resolves.
def _with_wake_excludes(repo: pathlib.Path, exclude_paths: list[str]) -> pathlib.Path:
    (repo / "wake.toml").write_text(f"[compiler.solc]\nexclude_paths = {json.dumps(exclude_paths)}\n")
    return repo


def _wake_scope_rows(problem: str) -> list[str]:
    """The rows of a wake-scope finding: every line between its heading and its repair, unindented."""
    return [line.strip() for line in problem.splitlines()[1:] if not line.strip().startswith("Repair:")]


def test_wake_scope_clean_when_only_forge_directories_hold_solidity(tmp_path):
    repo = _with_wake_excludes(_forge_project(tmp_path / "host", _used_by_a_test_and_a_script()), [])
    assert doctor.wake_scope_problems(repo) == []


def test_wake_scope_reports_a_directory_forge_does_not_build(tmp_path):
    # a parked file is outside forge's directories, so nothing builds it, but wake compiles it
    repo = _with_wake_excludes(
        _forge_project(
            tmp_path / "host", _used_by_a_test_and_a_script() | {"deprecated/src/Old.sol": "contract Old {}\n"}
        ),
        [],
    )
    problems = doctor.wake_scope_problems(repo)
    assert len(problems) == 1
    assert _wake_scope_rows(problems[0]) == ["deprecated  1 file"]
    assert "compiler.solc.exclude_paths in wake.toml" in problems[0]


def test_wake_scope_clean_once_the_directory_is_excluded(tmp_path):
    repo = _with_wake_excludes(
        _forge_project(
            tmp_path / "host", _used_by_a_test_and_a_script() | {"deprecated/src/Old.sol": "contract Old {}\n"}
        ),
        ["deprecated"],
    )
    assert doctor.wake_scope_problems(repo) == []


def test_wake_scope_names_each_directory_once_with_its_file_count(tmp_path):
    repo = _with_wake_excludes(
        _forge_project(
            tmp_path / "host",
            _used_by_a_test_and_a_script()
            | {
                "deprecated/src/Old.sol": "contract Old {}\n",
                "deprecated/script/OldDeploy.s.sol": "contract OldDeploy {}\n",
                "tmp/copy/src/A.sol": "contract A {}\n",
            },
        ),
        [],
    )
    problems = doctor.wake_scope_problems(repo)
    assert len(problems) == 1
    assert _wake_scope_rows(problems[0]) == ["deprecated  2 files", "tmp         1 file"]


def test_wake_scope_exclusion_covers_whole_directories_not_name_prefixes(tmp_path):
    # wake matches an exclusion against whole path components: `lib` covers lib/ and not library/
    repo = _with_wake_excludes(
        _forge_project(
            tmp_path / "host",
            _used_by_a_test_and_a_script()
            | {"lib/dep/Dep.sol": "contract Dep {}\n", "library/Helper.sol": "contract Helper {}\n"},
        ),
        ["lib"],
    )
    problems = doctor.wake_scope_problems(repo)
    assert len(problems) == 1
    assert _wake_scope_rows(problems[0]) == ["library  1 file"]


def test_wake_scope_skips_hidden_directories_and_files(tmp_path):
    # wake's search for Solidity files enters no directory, and matches no file, whose name starts with a dot
    repo = _with_wake_excludes(
        _forge_project(
            tmp_path / "host",
            _used_by_a_test_and_a_script()
            | {".cache/Hidden.sol": "contract Hidden {}\n", "notes/.Draft.sol": "contract Draft {}\n"},
        ),
        [],
    )
    assert doctor.wake_scope_problems(repo) == []


def test_wake_scope_follows_a_symlinked_directory(tmp_path):
    # wake's search follows a symlink to a directory, so Solidity reached through one is compiled
    outside = tmp_path / "elsewhere"
    outside.mkdir()
    (outside / "Linked.sol").write_text(_SOLIDITY_HEADER + "contract Linked {}\n")
    repo = _with_wake_excludes(_forge_project(tmp_path / "host", _used_by_a_test_and_a_script()), [])
    (repo / "linked").symlink_to(outside, target_is_directory=True)
    problems = doctor.wake_scope_problems(repo)
    assert len(problems) == 1
    assert _wake_scope_rows(problems[0]) == ["linked  1 file"]


def test_wake_scope_reads_the_directories_forge_builds_from_its_config(tmp_path):
    # which directories forge builds is forge's to say: with src = "contracts", src/ is no longer built
    repo = _with_wake_excludes(
        _forge_project(
            tmp_path / "host", {"contracts/A.sol": "contract A {}\n", "src/Stale.sol": "contract Stale {}\n"}
        ),
        [],
    )
    (repo / "foundry.toml").write_text('[profile.default]\nsrc = "contracts"\n')
    problems = doctor.wake_scope_problems(repo)
    assert len(problems) == 1
    assert _wake_scope_rows(problems[0]) == ["src  1 file"]


def test_wake_scope_names_the_shallowest_path_that_holds_no_forge_directory(tmp_path):
    # excluding a directory that holds one of forge's would hide that one from wake too, so the finding
    # names the path a level below it, or the file itself when the file sits directly beside forge's
    repo = _with_wake_excludes(
        _forge_project(
            tmp_path / "host",
            {
                "contracts/src/A.sol": "contract A {}\n",
                "contracts/legacy/Old.sol": "contract Old {}\n",
                "contracts/Loose.sol": "contract Loose {}\n",
            },
        ),
        [],
    )
    (repo / "foundry.toml").write_text('[profile.default]\nsrc = "contracts/src"\n')
    problems = doctor.wake_scope_problems(repo)
    assert len(problems) == 1
    assert _wake_scope_rows(problems[0]) == ["contracts/Loose.sol  1 file", "contracts/legacy     1 file"]


@pytest.mark.parametrize(
    ("wake_toml", "reported"),
    [
        (None, "wake.toml is missing"),
        ("[compiler.solc]\n", "does not set compiler.solc.exclude_paths"),
        ('[compiler.solc]\nexclude_paths = "lib"\n', "'lib'"),
        ("[compiler.solc]\nexclude_paths = [1]\n", "[1]"),
    ],
)
def test_wake_scope_reports_exclusions_it_cannot_read(tmp_path, wake_toml, reported):
    # without a list of paths what wake compiles is unknown, and wake's built-in default, used when the key
    # is absent, is wake's to change, so each is this check's finding rather than a guess
    repo = _forge_project(tmp_path / "host", _used_by_a_test_and_a_script())
    if wake_toml is not None:
        (repo / "wake.toml").write_text(wake_toml)
    problems = doctor.wake_scope_problems(repo)
    assert len(problems) == 1
    assert reported in problems[0]
    assert "doctor cannot tell which files wake compiles" in problems[0]


# ── remapping_detection_problems: forge uses only the remappings foundry.toml writes ──
#
# With auto_detect_remappings on, forge adds remappings it derives from the library directories it finds,
# nested ones inside dependencies included. Each test builds a project in tmp_path, so the value read is the
# one `forge config` resolves; the environment variable that overrides it is set or removed explicitly.
def _with_foundry_toml(repo: pathlib.Path, default_profile: str) -> pathlib.Path:
    (repo / "foundry.toml").write_text(f"[profile.default]\n{default_profile}")
    return repo


def test_remapping_detection_clean_when_forge_resolves_it_off(tmp_path, monkeypatch):
    monkeypatch.delenv("FOUNDRY_AUTO_DETECT_REMAPPINGS", raising=False)
    repo = _with_foundry_toml(
        _forge_project(tmp_path / "host", _used_by_a_test_and_a_script()), "auto_detect_remappings = false\n"
    )
    assert doctor.remapping_detection_problems(repo) == []


def test_remapping_detection_reported_at_forges_default(tmp_path, monkeypatch):
    # forge detects remappings unless told not to, so a foundry.toml that says nothing is a finding
    monkeypatch.delenv("FOUNDRY_AUTO_DETECT_REMAPPINGS", raising=False)
    repo = _with_foundry_toml(_forge_project(tmp_path / "host", _used_by_a_test_and_a_script()), "")
    problems = doctor.remapping_detection_problems(repo)
    assert len(problems) == 1
    assert "forge config gives auto_detect_remappings = true" in problems[0], problems[0]
    assert "Repair: set auto_detect_remappings = false in [profile.default] in foundry.toml" in problems[0], problems[0]


def test_remapping_detection_reads_what_forge_resolves_not_the_file(tmp_path, monkeypatch):
    # an environment variable overrides foundry.toml, and forge builds with what it resolves
    monkeypatch.setenv("FOUNDRY_AUTO_DETECT_REMAPPINGS", "true")
    repo = _with_foundry_toml(
        _forge_project(tmp_path / "host", _used_by_a_test_and_a_script()), "auto_detect_remappings = false\n"
    )
    problems = doctor.remapping_detection_problems(repo)
    assert len(problems) == 1
    assert "forge config gives auto_detect_remappings = true" in problems[0], problems[0]


def test_remapping_detection_reported_when_forge_does_not_report_it(tmp_path, monkeypatch):
    # a forge whose config does not carry the key leaves the question unanswered, which is a finding, not a pass
    monkeypatch.setattr(doctor, "forge_config", lambda repo_root: {})
    problems = doctor.remapping_detection_problems(tmp_path)
    assert len(problems) == 1
    assert "forge config does not give auto_detect_remappings" in problems[0], problems[0]
