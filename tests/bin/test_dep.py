"""bin/dep manages this repository's dependencies with git alone, and never touches the index.

`sync` brings a clone - fresh and non-recursive, or one a pull has moved - to what the repository
records: every top-level submodule at its gitlink, plus exactly the nested submodules forge's
remappings point into. A dependency's other nested submodules are its own business and are never
fetched, so one of them pinned to a commit no remote holds cannot stop this repository's checkout.

Every git command that changes something is reported as it runs. A failure prints git's own error and
leaves everything as it stands, so what happened can be read and unpicked by hand.

The repositories here are real, served from local paths, and the remappings are the ones the real
`forge config` resolves, so what is tested is what the commands actually do.
"""

import os
import re
import subprocess
import sys
from pathlib import Path
from typing import NamedTuple

import pytest

BAO_BASE = Path(__file__).resolve().parents[2]
DEP = BAO_BASE / "bin" / "dep"

sys.path.insert(0, str(BAO_BASE / "bin"))
import doctor  # noqa: E402 - importable only once bin is on the path

# Cloning a submodule from a path on disk is refused by default (CVE-2022-39253). Allowing it through the
# environment reaches every git call - the fixture's and the ones bin/dep makes - without touching a config.
GIT_ENV = {
    **os.environ,
    "GIT_CONFIG_COUNT": "1",
    "GIT_CONFIG_KEY_0": "protocol.file.allow",
    "GIT_CONFIG_VALUE_0": "always",
}

TOP_LEVEL = {"lib/dep", "lib/tool"}
EVERY_PATH = (
    "lib/dep",
    "lib/tool",
    "lib/dep/lib/inner",
    "lib/dep/lib/spare",
    "lib/dep/lib/inner/lib/deepest",
    "lib/tool/lib/helper",
)


def git(where: Path, *arguments: str) -> str:
    return subprocess.run(
        ["git", *arguments], cwd=where, check=True, capture_output=True, text=True, env=GIT_ENV
    ).stdout.strip()


def repository(remotes: Path, name: str, submodules: dict[str, Path] | None = None) -> Path:
    """A repository holding `src/<name>.sol` and `submodules` (path -> upstream), committed in
    remotes/<name> and published to remotes/<name>.git. Returns the published copy."""
    work = remotes / name
    (work / "src").mkdir(parents=True)
    git(work, "init", "-q", "-b", "main")
    (work / "src" / f"{name}.sol").write_text(f"// {name}\n")
    git(work, "add", "-A")
    git(work, "commit", "-qm", f"{name}: first")
    for path, upstream in (submodules or {}).items():
        git(work, "submodule", "add", "-q", str(upstream), path)
    if submodules:
        git(work, "commit", "-qm", f"{name}: submodules")
    published = remotes / f"{name}.git"
    git(remotes, "clone", "-q", "--bare", str(work), str(published))
    return published


def foundry_toml(remappings: list[str]) -> str:
    listed = ", ".join(f'"{remapping}"' for remapping in remappings)
    return f'[profile.default]\nsrc = "src"\nlibs = ["lib"]\nauto_detect_remappings = false\nremappings = [{listed}]\n'


class World(NamedTuple):
    remotes: Path
    project: Path


def make_world(tmp_path: Path, remappings: list[str]) -> World:
    """A project depending on `dep` - which holds `inner`, itself holding `deepest`, and `spare` - and on
    `tool`, which holds `helper`; `remappings` are its foundry.toml's. Everything is committed."""
    remotes = tmp_path / "remotes"
    deepest = repository(remotes, "deepest")
    inner = repository(remotes, "inner", {"lib/deepest": deepest})
    spare = repository(remotes, "spare")
    dep = repository(remotes, "dep", {"lib/inner": inner, "lib/spare": spare})
    helper = repository(remotes, "helper")
    tool = repository(remotes, "tool", {"lib/helper": helper})

    project = tmp_path / "project"
    (project / "src").mkdir(parents=True)
    git(project, "init", "-q", "-b", "main")
    (project / "foundry.toml").write_text(foundry_toml(remappings))
    (project / "src" / "Project.sol").write_text("// project\n")
    git(project, "add", "-A")
    git(project, "commit", "-qm", "project")
    git(project, "submodule", "add", "-q", str(dep), "lib/dep")
    git(project, "submodule", "add", "-q", str(tool), "lib/tool")
    git(project, "commit", "-qm", "dependencies")
    return World(remotes, project)


def clone(world: World) -> Path:
    """A non-recursive clone of the project: its submodules are declared and none is checked out."""
    target = world.project.parent / "clone"
    git(world.project.parent, "clone", "-q", str(world.project), str(target))
    return target


def sync(where: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run([str(DEP), "sync"], cwd=where, capture_output=True, text=True, env=GIT_ENV)


def checked_out(checkout: Path) -> str | None:
    return git(checkout, "rev-parse", "HEAD") if (checkout / ".git").exists() else None


def checked_out_paths(here: Path) -> set[str]:
    return {path for path in EVERY_PATH if (here / path / ".git").exists()}


def recorded(here: Path, path: str) -> str:
    """The commit the submodule's parent records for it: `lib/dep/lib/inner` is recorded by lib/dep."""
    parent, nested, child = path.rpartition("/lib/")
    return git(here / parent, "ls-files", "-s", "--", f"lib/{child}" if nested else path).split()[1]


def steps(output: str) -> list[str]:
    return [line.strip() for line in output.splitlines() if line.strip().startswith(("ran:", "failed"))]


# ── what sync checks out ──────────────────────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("remappings", "nested"),
    [
        (["dep/=lib/dep/src/", "local/=src/"], set()),
        (["dep/=lib/dep/src/", "inner/=lib/dep/lib/inner/src/"], {"lib/dep/lib/inner"}),
        (["inner/=lib/dep/lib/inner/src/", "helper/=lib/tool/lib/helper/src/"], {"lib/dep/lib/inner", "lib/tool/lib/helper"}),
    ],
    ids=["none", "one", "two"],
)
def test_sync_after_a_non_recursive_clone(tmp_path, remappings, nested):
    # The build reads every top-level dependency and, beneath them, only what a remapping names: those are
    # checked out at the commits recorded for them, and nothing else is fetched.
    here = clone(make_world(tmp_path, remappings))

    result = sync(here)

    assert result.returncode == 0, result.stdout + result.stderr
    assert checked_out_paths(here) == TOP_LEVEL | nested
    for path in TOP_LEVEL | nested:
        assert checked_out(here / path) == recorded(here, path), path


def test_sync_follows_a_remapping_through_every_level_it_names(tmp_path):
    # A remapping into a nested submodule's own submodule needs every level on the way, and only those.
    here = clone(make_world(tmp_path, ["deepest/=lib/dep/lib/inner/lib/deepest/src/"]))

    result = sync(here)

    assert result.returncode == 0, result.stdout + result.stderr
    assert checked_out_paths(here) == TOP_LEVEL | {"lib/dep/lib/inner", "lib/dep/lib/inner/lib/deepest"}


def test_sync_with_no_submodules_runs_nothing(tmp_path):
    project = tmp_path / "project"
    project.mkdir()
    git(project, "init", "-q", "-b", "main")
    (project / "foundry.toml").write_text(foundry_toml([]))
    git(project, "add", "-A")
    git(project, "commit", "-qm", "project")

    result = sync(project)

    assert result.returncode == 0, result.stdout + result.stderr
    assert [step for step in steps(result.stdout) if "submodule update" in step] == []


def test_sync_moves_a_stale_checkout_to_the_recorded_commit(tmp_path):
    # A pull that moves a gitlink leaves the checkout behind what is now recorded.
    here = clone(make_world(tmp_path, ["dep/=lib/dep/src/"]))
    sync(here)
    dependency = here / "lib" / "dep"
    git(dependency, "checkout", "-q", "HEAD~1")
    assert checked_out(dependency) != recorded(here, "lib/dep"), "the checkout must start off the record"

    result = sync(here)

    assert result.returncode == 0, result.stdout + result.stderr
    assert checked_out(dependency) == recorded(here, "lib/dep")
    assert "ran: git submodule update --init -- lib/dep" in steps(result.stdout)


def test_sync_rewrites_a_drifted_url(tmp_path):
    # `git submodule update` fetches from the url in .git/config, which nothing rewrites when .gitmodules
    # changes, so a checkout can go on fetching from somewhere no one else does.
    here = clone(make_world(tmp_path, ["dep/=lib/dep/src/"]))
    sync(here)
    git(here, "config", "submodule.lib/dep.url", "/nowhere/dep.git")

    result = sync(here)

    assert result.returncode == 0, result.stdout + result.stderr
    assert git(here, "config", "submodule.lib/dep.url") == git(here, "config", "-f", ".gitmodules", "submodule.lib/dep.url")


@pytest.mark.parametrize("branch_at", ["recorded", "elsewhere"])
def test_sync_puts_head_on_a_branch_only_where_it_already_points(tmp_path, branch_at):
    # A dependency that follows a branch stands on it when the branch already holds the recorded commit. A
    # branch anywhere else is the developer's, so sync detaches at the recorded commit rather than move it.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    git(world.project, "config", "-f", ".gitmodules", "submodule.lib/dep.branch", "main")
    git(world.project, "commit", "-qam", "dep follows main")
    here = clone(world)
    dependency = here / "lib" / "dep"
    sync(here)
    if branch_at == "elsewhere":
        git(dependency, "checkout", "-q", "--detach")
        git(dependency, "branch", "-q", "-f", "main", "HEAD~1")
    branch_before = git(dependency, "rev-parse", "refs/heads/main")
    assert (branch_before == recorded(here, "lib/dep")) == (branch_at == "recorded"), "the branch must start where named"

    result = sync(here)

    assert result.returncode == 0, result.stdout + result.stderr
    assert git(dependency, "rev-parse", "refs/heads/main") == branch_before, "sync must never move a branch"
    assert checked_out(dependency) == recorded(here, "lib/dep")
    standing_on = subprocess.run(
        ["git", "symbolic-ref", "-q", "--short", "HEAD"], cwd=dependency, capture_output=True, text=True
    ).stdout.strip()
    assert standing_on == ("main" if branch_at == "recorded" else ""), standing_on


def test_sync_reports_remappings_no_submodule_provides(tmp_path):
    # Two shapes seen in the repositories: a path inside a dependency that declares nothing there (ds-test,
    # since forge-std dropped it), and a path under lib/ that no submodule declares at all (@uniswap). Neither
    # can be checked out; sync says so and carries on, and doctor is what grades it.
    remappings = ["ds-test/=lib/dep/lib/ds-test/src/", "@uniswap/v3-core/=lib/v3-core/"]
    here = clone(make_world(tmp_path, remappings))

    result = sync(here)

    assert result.returncode == 0, result.stdout + result.stderr
    assert "! remapping ds-test/=lib/dep/lib/ds-test/src/ points to lib/dep/lib/ds-test/src, which does not exist" in (
        result.stdout
    )
    assert "! remapping @uniswap/v3-core/=lib/v3-core/ points to lib/v3-core, which does not exist" in result.stdout
    assert checked_out_paths(here) == TOP_LEVEL


def test_sync_skips_a_dependency_holding_work_and_syncs_the_rest(tmp_path):
    # Moving a folder is what would put a developer's work at risk. So a dependency holding work that only
    # this computer has stays as it is, and says why; the other dependencies are synced all the same.
    here = clone(make_world(tmp_path, ["dep/=lib/dep/src/"]))
    sync(here)
    dependency, tool = here / "lib" / "dep", here / "lib" / "tool"
    git(dependency, "checkout", "-q", "HEAD~1")
    (dependency / "notes.txt").write_text("mine\n")
    git(tool, "checkout", "-q", "HEAD~1")
    held = checked_out(dependency)

    result = sync(here)

    assert result.returncode != 0, "a dependency left behind is not a finished sync"
    assert "Skipped lib/dep" in result.stdout, result.stdout
    assert "lib/dep/notes.txt: not tracked by git" in result.stdout, result.stdout
    assert checked_out(dependency) == held, "the folder holding work must not move"
    assert checked_out(tool) == recorded(here, "lib/tool"), "the rest is synced"
    ran = steps(result.stdout)
    assert "ran: git submodule update --init -- lib/tool" in ran, ran
    assert "ran: git submodule update --init -- lib/dep" not in ran, ran


def test_sync_leaves_the_index_unchanged(tmp_path):
    # The index is the developer's: sync changes checkouts, and a change already staged is still staged,
    # exactly as it was.
    here = clone(make_world(tmp_path, ["inner/=lib/dep/lib/inner/src/"]))
    (here / "notes.md").write_text("staged\n")
    git(here, "add", "notes.md")
    staged = git(here, "ls-files", "--stage")

    result = sync(here)

    assert result.returncode == 0, result.stdout + result.stderr
    assert git(here, "ls-files", "--stage") == staged


# ── when a step fails ─────────────────────────────────────────────────────────────────────────────


def record_an_unpushed_nested_commit(world: World, nested: str) -> str:
    """Commit inside dep's own checkout of `nested` without publishing it, then record that in dep and
    publish dep. Returns the commit, which no remote holds."""
    dep_work = world.remotes / "dep"
    checkout = dep_work / "lib" / nested
    (checkout / "src" / "Local.sol").write_text("// never published\n")
    git(checkout, "add", "-A")
    git(checkout, "commit", "-qm", "never published")
    commit = git(checkout, "rev-parse", "HEAD")
    git(dep_work, "add", f"lib/{nested}")
    git(dep_work, "commit", "-qm", f"dep records {nested}")
    git(dep_work, "push", "-q", str(world.remotes / "dep.git"), "HEAD:main")
    return commit


def record_dep_in_project(world: World) -> None:
    """Move the project's record of dep to dep's published tip."""
    project_dep = world.project / "lib" / "dep"
    git(project_dep, "fetch", "-q", "origin")
    git(project_dep, "checkout", "-q", "origin/main")
    git(world.project, "add", "lib/dep")
    git(world.project, "commit", "-qm", "project records dep's tip")


def test_a_sync_failure_reports_gits_error_the_steps_run_and_where_things_stand(tmp_path):
    # The shape that stranded lib/harbor, on a path a remapping does name: dep records a nested commit its
    # remote never received. sync stops there and undoes nothing, printing every step it ran in order, git's
    # own error, and where each dependency now stands - enough to unpick by hand.
    world = make_world(tmp_path, ["inner/=lib/dep/lib/inner/src/"])
    unpushed = record_an_unpushed_nested_commit(world, "inner")
    record_dep_in_project(world)
    here = clone(world)

    result = sync(here)

    assert result.returncode != 0
    ran = steps(result.stdout)
    assert ran[:-1] == [
        "ran: git submodule sync",
        "ran: git submodule update --init -- lib/dep",
        "ran: git submodule update --init -- lib/tool",
    ], ran
    assert re.fullmatch(r"failed \(exit \d+\): git -C lib/dep submodule update --init -- lib/inner", ran[-1]), ran
    assert unpushed in result.stdout, f"git's own error names the commit it could not fetch:\n{result.stdout}"
    assert "[x] lib/dep - at " in result.stdout, result.stdout
    assert "[ ] lib/dep/lib/inner - the folder has " in result.stdout, result.stdout
    # inner does provide the remapped path; it is the checkout that failed, and the row above says so
    assert "which does not exist" not in result.stdout, result.stdout


# ── update: moving one dependency to a named version ──────────────────────────────────────────────
#
# `update` moves a dependency the way update-submodule does, without foundry.lock: the branch it follows
# is recorded in .gitmodules, and only the nested paths a remapping names are checked out beneath it.


def update(here: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([str(DEP), "update", *arguments], cwd=here, capture_output=True, text=True, env=GIT_ENV)


def synced(world: World) -> Path:
    """A clone of the project brought to its records by `sync`."""
    here = clone(world)
    result = sync(here)
    assert result.returncode == 0, f"setup sync failed:\n{result.stdout}{result.stderr}"
    return here


def advance(world: World, name: str) -> str:
    """Publish a new commit on `name`'s main. Returns it."""
    work = world.remotes / name
    (work / "src" / f"{name}.sol").write_text(f"// {name}, moved on\n")
    git(work, "add", "-A")
    git(work, "commit", "-qm", f"{name}: moved on")
    git(work, "push", "-q", str(world.remotes / f"{name}.git"), "HEAD:main")
    return git(work, "rev-parse", "HEAD")


def publish_tag(world: World, name: str, tag: str) -> None:
    git(world.remotes / name, "tag", tag)
    git(world.remotes / name, "push", "-q", str(world.remotes / f"{name}.git"), "--tags")


def branch_of(checkout: Path) -> str | None:
    """The branch HEAD is on, or None when it is detached."""
    standing = subprocess.run(
        ["git", "symbolic-ref", "-q", "--short", "HEAD"], cwd=checkout, capture_output=True, text=True
    )
    return standing.stdout.strip() or None


def following_main(tmp_path: Path, remappings: list[str]) -> World:
    """A world whose .gitmodules records that dep follows main."""
    world = make_world(tmp_path, remappings)
    git(world.project, "config", "-f", ".gitmodules", "submodule.lib/dep.branch", "main")
    git(world.project, "commit", "-qam", "dep follows main")
    return world


def test_update_an_uncommitted_edit_stops_it_before_anything_moves(tmp_path):
    # Moving the checkout is what would put the edit at risk, so it is refused before anything runs.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    advance(world, "dep")
    dependency = here / "lib" / "dep"
    (dependency / "src" / "dep.sol").write_text("// edited\n")
    before = checked_out(dependency)

    result = update(here, "dep@main")

    assert result.returncode != 0
    assert "exist only on this computer" in result.stdout, result.stdout
    assert "lib/dep/src/dep.sol: changed and not committed" in result.stdout, result.stdout
    assert steps(result.stdout) == [], "nothing may run"
    assert checked_out(dependency) == before
    assert (dependency / "src" / "dep.sol").read_text() == "// edited\n", "the edit must survive"


def test_an_update_refusal_names_what_is_at_risk_by_its_path_and_offers_both_choices(tmp_path):
    # The reader must see where each thing is, and that pushing is not the only way out: a commit nobody
    # wants - lib/harbor's downgrade was one - should be removed, not published.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    dependency = here / "lib" / "dep"
    git(dependency, "checkout", "-q", "-B", "main", "origin/main")
    (dependency / "src" / "Mine.sol").write_text("// mine\n")
    git(dependency, "add", "-A")
    git(dependency, "commit", "-qm", "mine")
    unpushed = git(dependency, "log", "-1", "--format=%h")

    result = update(here, "dep@main")

    assert result.returncode != 0
    named = next(line.strip() for line in result.stdout.splitlines() if unpushed in line)
    assert named.startswith("lib/dep"), f"the commit must be named with the dependency's path: {named}"
    assert "remove what you do not" in result.stdout, result.stdout


def test_update_force_is_the_answer_to_a_refusal(tmp_path):
    # --force is the user's decision once told what is at stake, which is why the tool stops rather than
    # warning and going on.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    (here / "lib" / "dep" / "scratch.txt").write_text("scratch\n")

    refused = update(here, "dep@main")
    forced = update(here, "--force", "dep@main")

    assert refused.returncode != 0
    assert forced.returncode == 0, forced.stdout + forced.stderr


def diverge_local_branch(world: World, here: Path) -> str:
    """Give the checkout's local `main` a commit its remote lacks, leave HEAD detached at the remote, then
    move the remote on. HEAD holds nothing unpushed - only the branch does. Returns that commit."""
    dependency = here / "lib" / "dep"
    git(dependency, "checkout", "-q", "-B", "main", "origin/main")
    (dependency / "src" / "Mine.sol").write_text("// mine\n")
    git(dependency, "add", "-A")
    git(dependency, "commit", "-qm", "mine")
    git(dependency, "checkout", "-q", "--detach", "origin/main")
    advance(world, "dep")
    return git(dependency, "rev-parse", "refs/heads/main")


def test_update_a_local_branch_holding_commits_the_target_lacks_is_refused(tmp_path):
    # Standing the branch at the target would take those commits off it. That is the user's decision, so
    # nothing moves.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    mine = diverge_local_branch(world, here)
    dependency = here / "lib" / "dep"
    before = checked_out(dependency)

    result = update(here, "dep@main")

    assert result.returncode != 0
    assert "mine" in result.stdout, f"the refusal must name the commit: {result.stdout}"
    assert checked_out(dependency) == before
    assert git(dependency, "rev-parse", "refs/heads/main") == mine, "the branch must keep its commit"


def test_update_force_over_a_diverged_local_branch_moves_detached_and_keeps_the_branch(tmp_path):
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    mine = diverge_local_branch(world, here)
    dependency = here / "lib" / "dep"

    result = update(here, "--force", "dep@main")

    assert result.returncode == 0, result.stdout + result.stderr
    assert branch_of(dependency) is None, "HEAD is detached, since the branch cannot be stood on"
    assert checked_out(dependency) == git(world.remotes / "dep", "rev-parse", "HEAD")
    assert git(dependency, "rev-parse", "refs/heads/main") == mine, "the branch must keep its commit"
    assert "Your branch main keeps its own commits" in result.stdout, result.stdout


def test_update_refuses_a_ref_that_names_nothing(tmp_path):
    here = synced(make_world(tmp_path, ["dep/=lib/dep/src/"]))

    result = update(here, "dep@no-such-ref")

    assert result.returncode != 0
    assert "not a tag, branch or commit" in result.stdout, result.stdout


def test_update_refuses_a_nested_dependency(tmp_path):
    # A dependency's own submodule is recorded by that dependency, so its version is its parent's to change.
    here = synced(make_world(tmp_path, ["inner/=lib/dep/lib/inner/src/"]))

    result = update(here, "lib/dep/lib/inner@main")

    assert result.returncode != 0
    assert "is a submodule inside another submodule" in result.stdout, result.stdout


def test_update_a_branch_lands_on_it_at_the_remote_tip(tmp_path):
    # Updating a dependency someone works in leaves them where they were: on the branch, now at its tip.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    tip = advance(world, "dep")

    result = update(here, "dep@main")

    assert result.returncode == 0, result.stdout + result.stderr
    assert branch_of(here / "lib" / "dep") == "main"
    assert checked_out(here / "lib" / "dep") == tip


def test_update_a_detached_branch_dependency_at_its_commit_is_put_on_its_branch(tmp_path):
    # Running it again repairs a detached HEAD even with nothing to move.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    dependency = here / "lib" / "dep"
    before = checked_out(dependency)
    assert branch_of(dependency) is None, "the checkout must start detached"

    result = update(here, "dep@main")

    assert result.returncode == 0, result.stdout + result.stderr
    assert branch_of(dependency) == "main"
    assert checked_out(dependency) == before, "the checkout must not move"


def test_update_a_branch_with_no_local_branch_gains_one_tracking_the_remote(tmp_path):
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    dependency = here / "lib" / "dep"
    git(dependency, "checkout", "-q", "--detach")
    git(dependency, "branch", "-q", "-D", "main")
    tip = advance(world, "dep")

    result = update(here, "dep@main")

    assert result.returncode == 0, result.stdout + result.stderr
    assert branch_of(dependency) == "main"
    assert checked_out(dependency) == tip
    assert git(dependency, "rev-parse", "--abbrev-ref", "main@{upstream}") == "origin/main"


def test_update_a_tag_moves_detached(tmp_path):
    # A tag names one commit and there is no branch to stand on.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    tip = advance(world, "dep")
    publish_tag(world, "dep", "v2")

    result = update(here, "dep@v2")

    assert result.returncode == 0, result.stdout + result.stderr
    assert branch_of(here / "lib" / "dep") is None
    assert checked_out(here / "lib" / "dep") == tip


# ── update: what .gitmodules records ──────────────────────────────────────────────────────────────


def test_update_without_a_ref_follows_the_recorded_branch_and_says_so(tmp_path):
    # The branch was given once, when the dependency was set to follow it, and .gitmodules keeps it. A bare
    # update follows that and says so; nothing is guessed.
    world = following_main(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    tip = advance(world, "dep")

    result = update(here, "dep")

    assert result.returncode == 0, result.stdout + result.stderr
    assert "Following branch main (set in .gitmodules)." in result.stdout, result.stdout
    assert branch_of(here / "lib" / "dep") == "main"
    assert checked_out(here / "lib" / "dep") == tip


def test_update_without_a_ref_is_refused_when_no_branch_is_recorded(tmp_path):
    # A dependency at a tag or a commit has no branch on record, so a bare update has nothing it was told
    # to follow, and asks.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    advance(world, "dep")
    before = checked_out(here / "lib" / "dep")

    result = update(here, "dep")

    assert result.returncode != 0
    assert "does not say which branch lib/dep follows" in result.stdout, result.stdout
    assert "yarn dep update lib/dep@<tag, branch or commit>" in result.stdout, result.stdout
    assert steps(result.stdout) == [], "nothing may run"
    assert checked_out(here / "lib" / "dep") == before


def test_update_to_a_branch_records_it_in_gitmodules(tmp_path):
    # What a dependency follows is recorded where git records it, so the next bare update can follow it.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)

    result = update(here, "dep@main")

    assert result.returncode == 0, result.stdout + result.stderr
    assert git(here, "config", "-f", ".gitmodules", "submodule.lib/dep.branch") == "main"


def test_update_to_a_tag_drops_the_branch_line(tmp_path):
    # At a tag the dependency follows no branch, and a branch line left behind would have a bare update move
    # it off the tag.
    world = following_main(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    advance(world, "dep")
    publish_tag(world, "dep", "v2")

    result = update(here, "dep@v2")

    assert result.returncode == 0, result.stdout + result.stderr
    recorded_branch = subprocess.run(
        ["git", "config", "-f", ".gitmodules", "--get", "submodule.lib/dep.branch"], cwd=here, capture_output=True, text=True
    )
    assert recorded_branch.returncode == 1 and recorded_branch.stdout == "", recorded_branch.stdout


# ── update: beneath the dependency ────────────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("remappings", "nested"),
    [
        ([], set()),
        (["inner/=lib/dep/lib/inner/src/"], {"lib/dep/lib/inner"}),
        (["inner/=lib/dep/lib/inner/src/", "spare/=lib/dep/lib/spare/src/"], {"lib/dep/lib/inner", "lib/dep/lib/spare"}),
    ],
    ids=["none", "one", "two"],
)
def test_update_checks_out_only_remapped_nested_paths(tmp_path, remappings, nested):
    # Beneath the dependency it moves, update checks out what a remapping names, and nothing else.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    (here / "foundry.toml").write_text(foundry_toml(["dep/=lib/dep/src/", *remappings]))
    advance(world, "dep")

    result = update(here, "dep@main")

    assert result.returncode == 0, result.stdout + result.stderr
    assert checked_out_paths(here) - TOP_LEVEL == nested


def test_update_succeeds_when_an_unremapped_nested_pin_is_on_no_remote(tmp_path):
    # The case that stranded lib/harbor: the dependency's new version pins one of its own submodules at a
    # commit no remote holds. Nothing here builds from that submodule, so it is never fetched and the
    # update completes.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    record_an_unpushed_nested_commit(world, "spare")

    result = update(here, "dep@main")

    assert result.returncode == 0, result.stdout + result.stderr
    assert checked_out(here / "lib" / "dep") == git(world.remotes / "dep", "rev-parse", "HEAD")
    assert "lib/dep/lib/spare" not in checked_out_paths(here)


def test_update_does_not_fetch_into_a_checked_out_nested_submodule_no_remapping_names(tmp_path):
    # lib/harbor's real shape: earlier recursive checkouts left the dependency's nested submodules checked
    # out. git's fetch would follow them on its own (fetch.recurseSubmodules defaults to on-demand) and fail
    # on a nested pin no remote holds - for a submodule nothing here builds from.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    git(here / "lib" / "dep", "submodule", "update", "--init", "--", "lib/spare")
    record_an_unpushed_nested_commit(world, "spare")

    result = update(here, "dep@main")

    assert result.returncode == 0, result.stdout + result.stderr
    assert checked_out(here / "lib" / "dep") == git(world.remotes / "dep", "rev-parse", "HEAD")


def test_an_update_whose_ref_never_resolves_does_not_judge_what_gitmodules_should_record(tmp_path):
    # Whether .gitmodules should record a branch depends on what the ref turns out to be, so with the fetch
    # failed there is nothing to compare against, and no command to offer for it.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    git(here / "lib" / "dep", "remote", "set-url", "origin", str(tmp_path / "nowhere.git"))

    result = update(here, "dep@main")

    assert result.returncode != 0
    stage_five = next(line for line in result.stdout.splitlines() if line.strip().startswith("[ ] 5."))
    assert "unknown until the version is found" in stage_five, result.stdout
    assert "--unset" not in result.stdout, result.stdout


def test_an_update_failure_reports_gits_error_the_steps_run_and_where_things_stand(tmp_path):
    # The same pin on a path a remapping does name: the update stops there and undoes nothing, printing
    # every step it ran, git's own error, and the checklist as it now stands.
    world = make_world(tmp_path, ["inner/=lib/dep/lib/inner/src/"])
    here = synced(world)
    unpushed = record_an_unpushed_nested_commit(world, "inner")

    result = update(here, "dep@main")

    assert result.returncode != 0
    ran = steps(result.stdout)
    assert ran[:-1] == [
        "ran: git -C lib/dep fetch --tags --quiet --no-recurse-submodules origin",
        "ran: git -C lib/dep checkout --quiet --track -B main origin/main",
        "ran: git config -f .gitmodules submodule.lib/dep.branch main",
    ], ran
    assert re.fullmatch(r"failed \(exit \d+\): git -C lib/dep submodule update --init -- lib/inner", ran[-1]), ran
    assert unpushed in result.stdout, f"git's own error names the commit it could not fetch:\n{result.stdout}"
    assert "[x] 2." in result.stdout and "[ ] 3." in result.stdout, result.stdout


# ── update: leftovers ─────────────────────────────────────────────────────────────────────────────


def test_update_removes_a_stranded_directory(tmp_path):
    # A repository nothing tracks inside the dependency - what a version that stops declaring a populated
    # submodule leaves - is removed, shown as the steps it took. Stage 0 has found nothing in it that exists
    # only here.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    stranded = here / "lib" / "dep" / "stranded"
    git(tmp_path, "clone", "-q", str(world.remotes / "helper.git"), str(stranded))

    result = update(here, "dep@main")

    assert result.returncode == 0, result.stdout + result.stderr
    assert not stranded.exists()
    assert "ran: rm -rf lib/dep/stranded" in steps(result.stdout), result.stdout


def test_update_keeps_a_stranded_directory_holding_work(tmp_path):
    # The same directory holding a commit no remote has is stopped on, not swept up.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    stranded = here / "lib" / "dep" / "stranded"
    git(tmp_path, "clone", "-q", str(world.remotes / "helper.git"), str(stranded))
    (stranded / "src" / "Mine.sol").write_text("// a day of work\n")
    git(stranded, "add", "-A")
    git(stranded, "commit", "-qm", "unpushed")

    result = update(here, "dep@main")

    assert result.returncode != 0
    assert (stranded / "src" / "Mine.sol").is_file()
    assert "exist only on this computer" in result.stdout, result.stdout


def test_a_leftover_that_cannot_be_removed_is_reported_not_claimed(tmp_path):
    # A deletion that fails is shown with the system's own error, and never reported as done.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    stranded = here / "lib" / "dep" / "stranded"
    git(tmp_path, "clone", "-q", str(world.remotes / "helper.git"), str(stranded))
    (stranded / "src").chmod(0o555)

    result = update(here, "dep@main")

    assert result.returncode != 0
    assert "failed: rm -rf lib/dep/stranded" in result.stdout, result.stdout
    assert "ran: rm -rf lib/dep/stranded" not in result.stdout
    assert stranded.exists()


# ── update: what is left for the user ─────────────────────────────────────────────────────────────


def test_update_hands_over_staging_and_committing_without_running_them(tmp_path):
    # The move changes the gitlink and the branch .gitmodules records; both are the user's to stage, so they
    # are named, not staged - and a change the user had already staged is still staged, exactly.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    (here / "notes.md").write_text("staged\n")
    git(here, "add", "notes.md")
    staged = git(here, "ls-files", "--stage")
    advance(world, "dep")

    result = update(here, "dep@main")

    assert result.returncode == 0, result.stdout + result.stderr
    assert "Next, run: git add lib/dep .gitmodules && git commit" in result.stdout, result.stdout
    assert git(here, "ls-files", "--stage") == staged


def commit_a_move(here: Path) -> None:
    """Move dep to main's tip and commit the move as the user would."""
    moved = update(here, "dep@main")
    assert moved.returncode == 0, moved.stdout + moved.stderr
    git(here, "add", "lib/dep", ".gitmodules")
    git(here, "commit", "-qm", "dep at main")


def test_update_of_a_move_already_committed_leaves_nothing_to_run(tmp_path):
    # Run over a move already staged and committed, it says so, rather than handing over commands that would
    # record nothing.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    advance(world, "dep")
    commit_a_move(here)

    result = update(here, "dep@main")

    assert result.returncode == 0, result.stdout + result.stderr
    assert "Next, run" not in result.stdout, result.stdout
    assert "Nothing to do" in result.stdout, result.stdout


def test_doctor_names_the_staging_dep_update_hands_over(tmp_path):
    # The two tools must not give different answers about one tree. After a move, the staging doctor
    # offers is the staging `dep update` handed over - the gitlink and, here, the .gitmodules entry.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    advance(world, "dep")
    moved = update(here, "dep@main")
    assert "Next, run: git add lib/dep .gitmodules && git commit" in moved.stdout, moved.stdout

    findings = [p for p in sum(doctor.submodule_problems(here, ["dep/=lib/dep/src/"]), []) if p.startswith("lib/dep:")]

    assert len(findings) == 1, findings
    assert "Repair: To keep the folder's version: git add lib/dep .gitmodules (" in findings[0], findings[0]


def test_another_dependencys_gitmodules_entry_does_not_hold_this_one_back(tmp_path):
    # Staged and committed are asked of this dependency's own entry, not of the whole .gitmodules, whose
    # other entries belong to other dependencies' moves.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    advance(world, "dep")
    commit_a_move(here)
    git(here, "config", "-f", ".gitmodules", "submodule.lib/tool.branch", "main")

    result = update(here, "dep@main")

    assert result.returncode == 0, result.stdout + result.stderr
    assert "Nothing to do" in result.stdout, result.stdout
