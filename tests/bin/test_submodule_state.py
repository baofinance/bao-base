"""bin/submodule_state.py reads what a submodule claims to be, and names what is wrong with it.

Every state here is BUILT WITH REAL GIT rather than hand-assembled, because the point of the module
is that it reads git correctly - a fixture that fakes the facts would only confirm the assertions
were written to match the code. The states themselves were captured from real repositories (a VSCode
version bump caught at each of its three stages, a dependency carrying unpushed commits, a nested
submodule left behind by a bump that did not recurse) and are reproduced here.

Local repositories are wired with `file://`, which needs protocol.file.allow: submodule clones over
that transport are refused by default. `forge` is not involved - this module never runs it.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import NamedTuple

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "bin"))

from submodule_state import checklist, condition, read_facts, read_lock, repair  # noqa: E402

FOUNDRY_TOML = '[profile.default]\nsrc = "src"\nlibs = ["lib"]\n'
FILE_TRANSPORT = ("-c", "protocol.file.allow=always")


def git(where: Path, *arguments: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", *FILE_TRANSPORT, *arguments], cwd=where, capture_output=True, text=True, check=check)


def make_repo(root: Path, name: str) -> Path:
    """A repository with one commit tagged v1, on branch main."""
    source = root / name
    source.mkdir(parents=True)
    git(source, "init", "-q", "-b", "main")
    git(source, "config", "user.email", "state@test")
    git(source, "config", "user.name", "state")
    (source / "A.sol").write_text("// one\n")
    git(source, "add", "-A")
    git(source, "commit", "-qm", "one")
    git(source, "tag", "v1")
    return source


def add_commit(source: Path, message: str) -> str:
    (source / "A.sol").write_text(f"// {message}\n")
    git(source, "add", "-A")
    git(source, "commit", "-qm", message)
    return git(source, "rev-parse", "HEAD").stdout.strip()


def write_lock(project: Path, path: str, kind: str, name: str | None, rev: str) -> None:
    entry = {"rev": rev} if kind == "rev" else {kind: {"name": name, "rev": rev}}
    (project / "foundry.lock").write_text(json.dumps({path: entry}, indent=2))


class World(NamedTuple):
    """The project under test, plus the remote its dependency was cloned from so a test can advance
    it, and the directory to put further remotes in."""

    project: Path
    dep_source: Path
    remotes: Path


@pytest.fixture
def world(tmp_path):
    """A project with `lib/dep` checked out at v1, and foundry.lock agreeing - the consistent state
    every other test perturbs. `world.dep_source` is the remote, so tests can advance it."""
    remote = make_repo(tmp_path / "remotes", "dep")
    project = tmp_path / "project"
    (project / "src").mkdir(parents=True)
    (project / "foundry.toml").write_text(FOUNDRY_TOML)
    git(project, "init", "-q", "-b", "main")
    git(project, "config", "user.email", "state@test")
    git(project, "config", "user.name", "state")
    git(project, "add", "-A")
    git(project, "commit", "-qm", "init")
    git(project, "submodule", "add", "-q", str(remote), "lib/dep")
    git(project / "lib" / "dep", "checkout", "-q", "v1")
    write_lock(project, "lib/dep", "tag", "v1", git(remote, "rev-parse", "v1").stdout.strip())
    git(project, "add", "-A")
    git(project, "commit", "-qm", "add dep")
    return World(project, remote, tmp_path / "remotes")


def facts_for(project: Path):
    return read_facts(project, "lib/dep")


def test_a_tree_that_agrees_is_consistent(world):
    # All four claims name the same commit, so there is nothing to report and nothing to do.
    assert condition(facts_for(world.project)).name == "consistent"
    assert not condition(facts_for(world.project)).is_fault


def test_a_branch_pin_behind_its_remote_is_not_a_fault(world):
    # bao-base's main moves daily. Reporting that as a problem every morning is how a check stops
    # being read, so it is named but excluded from what doctor reports.
    dep = world.project / "lib" / "dep"
    here = git(dep, "rev-parse", "HEAD").stdout.strip()
    # Every claim agrees on the commit checked out; only the remote has moved past it.
    write_lock(world.project, "lib/dep", "branch", "main", here)
    git(world.project, "add", "-A")
    git(world.project, "commit", "-qm", "track main")
    add_commit(world.dep_source, "moved on")
    git(dep, "fetch", "-q", "origin")

    found = condition(facts_for(world.project))
    assert found.name == "behind-moving-pin", found
    assert not found.is_fault


def test_a_dependency_holding_unpushed_commits_is_reported(world):
    # Commits that exist in one clone only: every other checkout is missing what the gitlink names,
    # and a lost machine loses them. Reported on every run until they are pushed, deliberately.
    add_commit(world.project / "lib" / "dep", "local work")
    git(world.project, "add", "-A")
    git(world.project, "commit", "-qm", "record local work")
    write_lock(
        world.project,
        "lib/dep",
        "branch",
        "main",
        git(world.project / "lib" / "dep", "rev-parse", "HEAD").stdout.strip(),
    )

    facts = facts_for(world.project)
    assert facts.unpushed, "the fixture must leave a commit no remote holds"
    found = condition(facts)
    assert found.name == "at-risk-content"
    assert found.is_fault, "one threshold: what blocks a delete is also what doctor reports"
    assert facts.has_own_work, "and it blocks a destructive stage"


@pytest.mark.parametrize(
    "stop_after, expected_reach",
    [("checkout", "the working tree"), ("stage", "the index"), ("commit", "HEAD")],
)
def test_a_version_bump_is_named_by_how_far_it_travelled(world, stop_after, expected_reach):
    # The three states a VSCode bump passes through, captured from a real v5.4.0 -> v5.7.0 bump. The
    # lock is stale in all three; what differs is how much of the parent has caught up, which is what
    # the user still has left to do.
    add_commit(world.dep_source, "v2")
    git(world.dep_source, "tag", "v2")
    git(world.project / "lib" / "dep", "fetch", "-q", "origin", "--tags")
    git(world.project / "lib" / "dep", "checkout", "-q", "v2")
    if stop_after in ("stage", "commit"):
        git(world.project, "add", "lib/dep")
    if stop_after == "commit":
        git(world.project, "commit", "-qm", "bump dep to v2")

    found = condition(facts_for(world.project))
    assert found.name == "bumped-not-locked", found
    assert found.reach == expected_reach, found
    assert found.is_fault


def test_an_uninitialised_submodule_outranks_every_other_reading(world):
    # Nothing else about it is meaningful, so it must not be reported as a version disagreement.
    subprocess.run(["rm", "-rf", str(world.project / "lib" / "dep")], check=True)

    found = condition(facts_for(world.project))
    assert found.name == "uninitialised"


def test_a_developer_edit_is_reported_and_nested_drift_is_not(world):
    # The distinction the old tools could not make. A modified file is the developer's work and blocks
    # a delete; a nested submodule off its pin belongs to the dependency and is fixed by recursing.
    (world.project / "lib" / "dep" / "A.sol").write_text("// edited by hand\n")

    facts = facts_for(world.project)
    assert facts.edits, "a hand-edited file must be seen"
    assert condition(facts).name == "at-risk-content"
    assert facts.has_own_work


def test_nested_drift_alone_is_not_the_developers_work(world):
    # `git status` inside a submodule reports its nested submodules as modifications, which is what
    # made the old wrapper tell the user to commit and push a third-party repository. Read with
    # --ignore-submodules=all there is nothing of theirs here at all.
    # The nested submodule is added UPSTREAM and pulled in, so `dep` carries no commit of its own -
    # otherwise the fixture would produce unpushed work as well and prove nothing about drift alone.
    inner = make_repo(world.remotes, "inner")
    git(world.dep_source, "submodule", "add", "-q", str(inner), "lib/inner")
    git(world.dep_source, "commit", "-qm", "add inner")
    dep = world.project / "lib" / "dep"
    git(dep, "fetch", "-q", "origin")
    git(dep, "checkout", "-q", "origin/main")
    git(dep, "submodule", "update", "--init", "-q")
    add_commit(inner, "inner moved")
    git(dep / "lib" / "inner", "fetch", "-q", "origin")
    git(dep / "lib" / "inner", "checkout", "-q", "origin/main")

    facts = facts_for(world.project)
    assert facts.nested_drift, "the nested submodule must be off its recorded commit"
    assert facts.edits == [], "nested drift must not be counted as the developer's edits"
    assert not facts.has_own_work, "it must not block a delete"


def test_an_untracked_repository_inside_a_dependency_is_litter(world):
    # What "unable to rmdir" leaves behind: a populated directory the new version no longer declares.
    # It is the dependency's, not ours, so it must never be reported as work to commit.
    orphan = world.project / "lib" / "dep" / "lib" / "stranded"
    orphan.mkdir(parents=True)
    git(orphan, "init", "-q")

    facts = facts_for(world.project)
    assert facts.litter == ["lib/stranded"], facts.litter
    assert facts.edits == [], "litter is not a file the developer edited"
    assert condition(facts).name == "litter-present"


def test_litter_in_a_nested_dependency_is_repaired_at_its_own_path(world):
    # The repair for a NESTED submodule must name that submodule, not its bare directory name: a
    # dependency's dependency routinely shares a name with one of ours (both bao-base and OZ carry
    # `lib/forge-std`), so a basename sends `yarn update` to a different repository - moving one that
    # was fine and leaving the litter where it was.
    inner = make_repo(world.remotes, "inner")
    git(world.dep_source, "submodule", "add", "-q", str(inner), "lib/inner")
    git(world.dep_source, "commit", "-qm", "add inner")
    dep = world.project / "lib" / "dep"
    git(dep, "fetch", "-q", "origin")
    git(dep, "checkout", "-q", "origin/main")
    git(dep, "submodule", "update", "--init", "-q")
    # A same-named dependency of our own, which the basename form would target instead.
    git(world.project, "submodule", "add", "-q", str(inner), "lib/inner")
    orphan = dep / "lib" / "inner" / "lib" / "stranded"
    orphan.mkdir(parents=True)
    git(orphan, "init", "-q")

    facts = read_facts(world.project, "lib/dep/lib/inner")
    found = condition(facts)
    assert found.name == "litter-present", found
    fix = repair(facts, found)
    assert "lib/dep/lib/inner" in fix, fix
    assert not fix.endswith(" inner"), f"a bare name resolves to our own lib/inner: {fix}"


def test_the_lock_records_which_kind_of_pin_it_is(world):
    # Only a branch can resolve itself, which is what decides whether a bare `yarn update <dep>` has a
    # ref to move to or must ask for one.
    write_lock(world.project, "lib/dep", "branch", "main", "abc")
    assert read_lock(world.project)["lib/dep"].moving is True
    write_lock(world.project, "lib/dep", "tag", "v1", "abc")
    assert read_lock(world.project)["lib/dep"].moving is False
    write_lock(world.project, "lib/dep", "rev", None, "abc")
    assert read_lock(world.project)["lib/dep"].moving is False


def test_a_missing_lock_leaves_every_dependency_unpinned(tmp_path):
    # Better than half a picture: no lock means nothing claims a ref, which is exactly true.
    (tmp_path / "foundry.lock").write_text("{ not json")
    assert read_lock(tmp_path) == {}


def test_a_consistent_tree_has_nothing_left_on_the_checklist(world):
    facts = facts_for(world.project)
    stages = checklist(facts, "v1", facts.worktree)
    assert all(stage.done for stage in stages), [s for s in stages if not s.done]


def test_the_checklist_leaves_only_what_is_undone(world):
    # The property that lets `yarn update` continue someone else's half-finished job: a bump that has
    # reached the working tree needs the lock, the staging and the commit - and nothing else. In
    # particular stage 2 is already done, so nothing is deleted or re-cloned.
    add_commit(world.dep_source, "v2")
    git(world.dep_source, "tag", "v2")
    git(world.project / "lib" / "dep", "fetch", "-q", "origin", "--tags")
    git(world.project / "lib" / "dep", "checkout", "-q", "v2")
    target = git(world.project / "lib" / "dep", "rev-parse", "HEAD").stdout.strip()

    stages = {stage.number: stage for stage in checklist(facts_for(world.project), "v2", target)}

    assert stages[2].done, "the working tree is already there - nothing may be deleted"
    assert stages[0].done and stages[1].done
    assert not stages[5].done, "the lock still names the old version"
    assert not stages[6].done and not stages[7].done
    assert stages[6].action == "git add lib/dep"


def test_a_stationary_pin_with_no_ref_fails_the_checklist_rather_than_guessing(world):
    # Two pins disagree and the tool cannot know which was intended, so it must ask. The stage carries
    # the command that answers it rather than only refusing.
    stages = {stage.number: stage for stage in checklist(facts_for(world.project), None, None)}

    assert not stages[1].done
    assert "yarn update lib/dep@<ref>" in stages[1].action


def test_work_that_a_delete_would_destroy_stops_the_checklist_at_stage_zero(world):
    add_commit(world.project / "lib" / "dep", "local work")

    stages = {stage.number: stage for stage in checklist(facts_for(world.project), "v1", "whatever")}

    assert not stages[0].done
    assert "--force" in stages[0].action and "commit and push" in stages[0].action


def test_litter_is_found_inside_an_entirely_untracked_parent(world):
    # The case that defeated an earlier implementation: git collapses an all-untracked directory to
    # `?? lib/`, hiding the repository nested in it. --untracked-files=all lists `?? lib/ghost/`.
    orphan = world.project / "lib" / "dep" / "untracked" / "ghost"
    orphan.mkdir(parents=True)
    git(orphan, "init", "-q")

    assert facts_for(world.project).litter == ["untracked/ghost"]


def test_a_gitignored_nested_repository_is_not_litter(world):
    # Tooling caches (uv's `.tools/` sdist clones, for one) are nested repositories that belong where
    # they are. Reading through `git status` rather than walking the filesystem for `.git` is what
    # keeps them out.
    dep = world.project / "lib" / "dep"
    (dep / ".gitignore").write_text(".tools/\n")
    git(dep, "add", ".gitignore")
    git(dep, "commit", "-qm", "ignore tools")
    cache = dep / ".tools" / "cache"
    cache.mkdir(parents=True)
    git(cache, "init", "-q")

    assert facts_for(world.project).litter == []


def test_a_version_disagreement_is_never_repaired_by_staging(world):
    # The mistake the old doctor made, now impossible: `git add` moves the gitlink and cannot touch
    # foundry.lock, so offering it for a version disagreement records the disagreement instead of
    # resolving it. The repair must be the one command that writes both.
    add_commit(world.dep_source, "v2")
    git(world.dep_source, "tag", "v2")
    git(world.project / "lib" / "dep", "fetch", "-q", "origin", "--tags")
    git(world.project / "lib" / "dep", "checkout", "-q", "v2")

    facts = facts_for(world.project)
    fix = repair(facts, condition(facts))

    assert fix == "yarn update lib/dep@v2", fix
    assert "git add" not in fix and "git submodule update" not in fix


def test_the_repair_names_the_tag_the_working_tree_is_on(world):
    # What makes the refusal answerable. The GUI checks a tag out by name, so the intended version is
    # still readable from the commit; a commit that is no tag leaves a placeholder for the user.
    dep = world.project / "lib" / "dep"
    add_commit(world.dep_source, "v2")
    git(world.dep_source, "tag", "v2")
    git(dep, "fetch", "-q", "origin", "--tags")

    git(dep, "checkout", "-q", "v2")
    assert facts_for(world.project).worktree_ref == "v2"

    # A commit made AFTER the tag, so it carries no tag of its own.
    add_commit(world.dep_source, "past the tag")
    git(dep, "fetch", "-q", "origin")
    git(dep, "checkout", "-q", "origin/main")
    untagged = facts_for(world.project)
    assert untagged.worktree_ref is None, "an untagged commit must not be presented as a version"
    assert repair(untagged, condition(untagged)) == "yarn update lib/dep@<ref>"


def test_a_nested_submodules_own_commits_block_a_delete(world):
    # A `+` in `git submodule status` is produced identically by a version bump nobody recursed and
    # by a day of work committed inside the nested submodule. The flag cannot tell them apart, so the
    # question asked is not "whose is this" but "does any remote have it".
    inner = make_repo(world.remotes, "inner")
    git(world.dep_source, "submodule", "add", "-q", str(inner), "lib/inner")
    git(world.dep_source, "commit", "-qm", "add inner")
    dep = world.project / "lib" / "dep"
    git(dep, "fetch", "-q", "origin")
    git(dep, "checkout", "-q", "origin/main")
    git(dep, "submodule", "update", "--init", "-q")
    add_commit(dep / "lib" / "inner", "a day of work, unpushed")

    facts = facts_for(world.project)

    assert facts.edits == [], "it is not an edit at this level"
    assert facts.unpushed == [], "it is not a commit at this level either"
    assert facts.has_own_work, "but it would still be destroyed by a delete"
    assert any(item.path.startswith("lib/inner") and item.kind == "unpushed" for item in facts.at_risk)
    assert not checklist(facts, "v1", facts.worktree)[0].done


def test_an_untracked_repositorys_own_commits_block_a_delete(world):
    # The same for litter: "untracked directory containing .git" says nothing about what is inside.
    # A stranded checkout is pristine and safe to remove; one someone worked in is not.
    scratch = world.project / "lib" / "dep" / "scratch"
    scratch.mkdir(parents=True)
    git(scratch, "init", "-q")
    git(scratch, "config", "user.email", "state@test")
    git(scratch, "config", "user.name", "state")
    (scratch / "notes.txt").write_text("precious\n")
    git(scratch, "add", "-A")
    git(scratch, "commit", "-qm", "unpushed, and no remote at all")

    facts = facts_for(world.project)

    assert facts.litter == ["scratch"], "it is still reported as litter for the reader"
    assert facts.has_own_work, "but it must not be deleted on that basis"
    assert any(item.path.startswith("scratch") for item in facts.at_risk)


def test_a_pristine_stranded_checkout_does_not_block_a_delete(world):
    # The other half: litter that holds nothing of its own is exactly what the cleanup is for, and
    # must not be turned into a permanent refusal.
    stranded = world.project / "lib" / "dep" / "stranded"
    git(world.project, "clone", "-q", str(world.dep_source), str(stranded))

    facts = facts_for(world.project)

    assert facts.litter == ["stranded"], facts.litter
    assert not facts.has_own_work, "a clean clone of a reachable remote is replaceable"
    assert checklist(facts, "v1", facts.worktree)[0].done


def test_an_untracked_file_blocks_a_delete(world):
    # Nothing tracks it, so nothing can restore it - the third shape, and the one both earlier
    # classifications missed entirely.
    (world.project / "lib" / "dep" / "scratch.txt").write_text("notes I have not committed\n")

    facts = facts_for(world.project)

    assert facts.edits == [], "an untracked file is not a modification"
    assert facts.has_own_work
    assert any(item.kind == "untracked" for item in facts.at_risk)


def _arrange(dep: Path, state: str) -> None:
    """Put the dependency into one named git state. Every one of these is a change someone made that
    a delete would throw away, whatever git calls it."""
    if state == "untracked file":
        (dep / "new.txt").write_text("not committed anywhere\n")
    elif state == "staged new file":
        (dep / "new.txt").write_text("not committed anywhere\n")
        git(dep, "add", "new.txt")
    elif state == "modified":
        (dep / "A.sol").write_text("// edited\n")
    elif state == "staged modification":
        (dep / "A.sol").write_text("// edited\n")
        git(dep, "add", "A.sol")
    elif state == "deleted":
        (dep / "A.sol").unlink()
    elif state == "staged deletion":
        git(dep, "rm", "-q", "A.sol")
    elif state == "renamed":
        git(dep, "mv", "A.sol", "B.sol")
    elif state == "unpushed commit":
        (dep / "A.sol").write_text("// committed but never pushed\n")
        git(dep, "add", "-A")
        git(dep, "commit", "-qm", "local only")
    else:
        raise AssertionError(f"unhandled state {state!r}")


@pytest.mark.parametrize(
    "state",
    [
        "untracked file",
        "staged new file",
        "modified",
        "staged modification",
        "deleted",
        "staged deletion",
        "renamed",
        "unpushed commit",
    ],
)
def test_every_kind_of_uncommitted_change_blocks_a_delete(world, state):
    # The safety question is not "which git status code is this" but "would deleting the directory
    # lose it". Staged and unstaged, added and removed, renamed and rewritten all answer yes, so the
    # walk must not enumerate codes it recognises and quietly pass everything else.
    _arrange(world.project / "lib" / "dep", state)

    facts = facts_for(world.project)

    assert facts.at_risk, f"{state} was not seen at all"
    assert facts.has_own_work
    stage_zero = checklist(facts, "v1", facts.worktree)[0]
    assert not stage_zero.done, f"{state} did not stop the checklist"
    assert "--force" in stage_zero.action


@pytest.mark.parametrize("state", ["modified", "renamed", "staged deletion", "untracked file"])
def test_what_is_at_risk_is_named_by_path_not_merely_counted(world, state):
    # Only the user can tell a day's work from a stray file, and they cannot judge a number - so the
    # refusal has to say which file, for every shape of change.
    _arrange(world.project / "lib" / "dep", state)

    detail = checklist(facts_for(world.project), "v1", facts_for(world.project).worktree)[0].detail

    assert "A.sol" in detail or "new.txt" in detail, detail


def test_a_gitignored_file_is_not_treated_as_at_risk(world):
    # Deliberate, and worth knowing: build output is regenerable and listing it would bury the real
    # findings. It does mean a delete removes gitignored files that are NOT regenerable, a local .env
    # being the obvious one.
    dep = world.project / "lib" / "dep"
    # Via info/exclude so the fixture leaves no commit of its own to be seen instead. A submodule's
    # .git is a file pointing at the real gitdir, so ask git where that is rather than assuming.
    gitdir = Path(git(dep, "rev-parse", "--absolute-git-dir").stdout.strip())
    (gitdir / "info").mkdir(parents=True, exist_ok=True)
    (gitdir / "info" / "exclude").write_text("out/\n")
    (dep / "out").mkdir()
    (dep / "out" / "artifact.json").write_text("{}\n")

    facts = facts_for(world.project)

    assert facts.at_risk == [], facts.at_risk
    assert not facts.has_own_work


def test_a_disagreement_that_is_not_a_bump_is_not_narrated_as_one(world):
    # Found in a third repository the tests had never seen: the working tree and foundry.lock agreed
    # while the index and HEAD named something else. The old rule fell through to "the change has
    # reached HEAD; foundry.lock is behind it" - the exact opposite of the truth. `reach` is now set
    # only for the three shapes a version bump actually produces; every other disagreement is stated
    # as the grouping of who agrees with whom, which is always true.
    dep = world.project / "lib" / "dep"
    add_commit(world.dep_source, "v2")
    git(world.dep_source, "tag", "v2")
    git(dep, "fetch", "-q", "origin", "--tags")
    git(dep, "checkout", "-q", "v2")
    git(world.project, "add", "lib/dep")
    git(world.project, "commit", "-qm", "record v2")
    # ...then go back, leaving the recorded gitlink ahead of both the working tree and the lock.
    git(dep, "checkout", "-q", "v1")

    found = condition(facts_for(world.project))

    assert found.name == "bumped-not-locked"
    assert found.reach is None, f"this is not a bump, so nothing may be claimed about one: {found}"
    assert "working tree + foundry.lock say" in found.detail, found.detail
    assert "index + HEAD say" in found.detail, found.detail


def test_the_repair_asks_for_a_commit_when_that_is_all_that_is_left(world):
    # Found by comparing five repositories: one had every claim agreeing except HEAD - a bump staged
    # and not committed - and a fixed "yarn update" string told the user to update a dependency whose
    # only need was `git commit`. The repair now comes from the checklist, so it names whichever of
    # the two tools actually has work left.
    dep = world.project / "lib" / "dep"
    add_commit(world.dep_source, "v2")
    git(world.dep_source, "tag", "v2")
    git(dep, "fetch", "-q", "origin", "--tags")
    git(dep, "checkout", "-q", "v2")
    write_lock(world.project, "lib/dep", "tag", "v2", git(dep, "rev-parse", "HEAD").stdout.strip())
    git(world.project, "add", "lib/dep", "foundry.lock")

    facts = facts_for(world.project)
    found = condition(facts)

    assert found.name == "bumped-not-locked", found
    assert repair(facts, found) == "git commit", repair(facts, found)


def test_the_repair_asks_for_staging_when_that_is_what_is_missing(world):
    dep = world.project / "lib" / "dep"
    add_commit(world.dep_source, "v2")
    git(world.dep_source, "tag", "v2")
    git(dep, "fetch", "-q", "origin", "--tags")
    git(dep, "checkout", "-q", "v2")
    write_lock(world.project, "lib/dep", "tag", "v2", git(dep, "rev-parse", "HEAD").stdout.strip())

    facts = facts_for(world.project)

    assert repair(facts, condition(facts)) == "git add lib/dep"
