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
    """A forge project holding `src/<name>.sol`, its own foundry.toml, and `submodules` (path -> upstream),
    committed in remotes/<name> and published to remotes/<name>.git. Returns the published copy."""
    work = remotes / name
    (work / "src").mkdir(parents=True)
    git(work, "init", "-q", "-b", "main")
    (work / "src" / f"{name}.sol").write_text(f"// {name}\n")
    (work / "foundry.toml").write_text(foundry_toml([]))
    git(work, "add", "-A")
    git(work, "commit", "-qm", f"{name}: first")
    for path, upstream in (submodules or {}).items():
        git(work, "submodule", "add", "-q", str(upstream), path)
    if submodules:
        git(work, "commit", "-qm", f"{name}: submodules")
    published = remotes / f"{name}.git"
    git(remotes, "clone", "-q", "--bare", str(work), str(published))
    return published


def foundry_toml(remappings: list[str], libs: tuple[str, ...] = ("lib",)) -> str:
    listed = ", ".join(f'"{remapping}"' for remapping in remappings)
    folders = ", ".join(f'"{folder}"' for folder in libs)
    return (
        f'[profile.default]\nsrc = "src"\nlibs = [{folders}]\nauto_detect_remappings = false\n'
        f"remappings = [{listed}]\n"
    )


class World(NamedTuple):
    remotes: Path
    project: Path


def empty_world(tmp_path: Path, remappings: list[str], libs: tuple[str, ...] = ("lib",)) -> World:
    """Published repositories - `dep`, which holds `inner`, itself holding `deepest`, and `spare`; `tool`,
    which holds `helper` - and a committed project with no dependencies; `remappings` and `libs` are its
    foundry.toml's."""
    remotes = tmp_path / "remotes"
    deepest = repository(remotes, "deepest")
    inner = repository(remotes, "inner", {"lib/deepest": deepest})
    spare = repository(remotes, "spare")
    repository(remotes, "dep", {"lib/inner": inner, "lib/spare": spare})
    helper = repository(remotes, "helper")
    repository(remotes, "tool", {"lib/helper": helper})

    project = tmp_path / "project"
    (project / "src").mkdir(parents=True)
    git(project, "init", "-q", "-b", "main")
    (project / "foundry.toml").write_text(foundry_toml(remappings, libs))
    (project / "src" / "Project.sol").write_text("// project\n")
    git(project, "add", "-A")
    git(project, "commit", "-qm", "project")
    return World(remotes, project)


def make_world(tmp_path: Path, remappings: list[str]) -> World:
    """The project of `empty_world` depending on `dep` and `tool`, committed."""
    world = empty_world(tmp_path, remappings)
    git(world.project, "submodule", "add", "-q", str(world.remotes / "dep.git"), "lib/dep")
    git(world.project, "submodule", "add", "-q", str(world.remotes / "tool.git"), "lib/tool")
    git(world.project, "commit", "-qm", "dependencies")
    return world


def clone(world: World) -> Path:
    """A non-recursive clone of the project: its submodules are declared and none is checked out."""
    target = world.project.parent / "clone"
    git(world.project.parent, "clone", "-q", str(world.project), str(target))
    return target


def sync(where: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([str(DEP), "sync", *arguments], cwd=where, capture_output=True, text=True, env=GIT_ENV)


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


def unused_checkout_line(path: str) -> str:
    return f"! {path} is checked out, and no remapping uses it. yarn dep sync removes it."


def test_sync_skips_a_dependency_holding_work_and_syncs_the_rest(tmp_path):
    # Moving a folder is what would put a developer's work at risk. So a dependency holding work that only
    # this computer has stays as it is, and says why; the other dependencies are synced all the same. Holding
    # work is a reason to skip, not a failure, so sync succeeds.
    here = clone(make_world(tmp_path, ["dep/=lib/dep/src/"]))
    sync(here)
    dependency, tool = here / "lib" / "dep", here / "lib" / "tool"
    git(dependency, "checkout", "-q", "HEAD~1")
    (dependency / "notes.txt").write_text("mine\n")
    git(tool, "checkout", "-q", "HEAD~1")
    held = checked_out(dependency)

    result = sync(here)

    assert result.returncode == 0, result.stdout + result.stderr
    assert "Skipping lib/dep, because it holds work." in result.stdout, result.stdout
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


def make_develop_the_default_branch(world: World, name: str) -> str:
    """Publish a `develop` branch a commit ahead of main and make it the remote's default branch (its HEAD),
    so git's default can be told apart from `main`. Returns develop's tip."""
    work = world.remotes / name
    git(work, "checkout", "-q", "-b", "develop")
    (work / "src" / f"{name}.sol").write_text(f"// {name}, on develop\n")
    git(work, "commit", "-qam", f"{name}: develop")
    git(work, "push", "-q", str(world.remotes / f"{name}.git"), "develop")
    git(world.remotes / f"{name}.git", "symbolic-ref", "HEAD", "refs/heads/develop")
    git(work, "checkout", "-q", "main")
    return git(work, "rev-parse", "develop")


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


def test_update_of_a_dependency_not_checked_out_is_refused(tmp_path):
    # update moves a checkout, so a dependency with none is checked out first, by sync.
    here = clone(make_world(tmp_path, ["dep/=lib/dep/src/"]))

    result = update(here, "dep@main")

    assert result.returncode != 0
    assert "Stopped: lib/dep is not checked out." in result.stdout, result.stdout
    assert "To check it out: yarn dep sync" in result.stdout, result.stdout
    assert steps(result.stdout) == [], "nothing may run"


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
    # .gitmodules alone says what a bare update does. With no branch named the dependency is pinned, so a
    # bare update leaves it where it is - whatever the remote's default branch has become - and says how to
    # move it.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    make_develop_the_default_branch(world, "dep")
    before = checked_out(here / "lib" / "dep")

    result = update(here, "dep")

    assert result.returncode != 0
    assert "Stopped: lib/dep is pinned. .gitmodules names no branch for it to follow." in result.stdout, result.stdout
    assert "To move it: yarn dep update lib/dep@<branch, tag or commit>" in result.stdout, result.stdout
    assert steps(result.stdout) == [], "nothing may run"
    assert checked_out(here / "lib" / "dep") == before


def test_update_to_a_branch_records_it_in_gitmodules(tmp_path):
    # What a dependency follows is recorded where git records it, so the next bare update can follow it.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)

    result = update(here, "dep@main")

    assert result.returncode == 0, result.stdout + result.stderr
    assert git(here, "config", "-f", ".gitmodules", "submodule.lib/dep.branch") == "main"


@pytest.mark.parametrize("version", ["tag", "commit"])
def test_update_to_a_tag_or_commit_drops_the_branch_line_and_pins_it(tmp_path, version):
    # At a tag or a commit the dependency follows no branch, so the line goes, and the bare update that
    # would otherwise have moved it to the branch's tip leaves it where it was put.
    world = following_main(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    pinned = advance(world, "dep")
    publish_tag(world, "dep", "v2")
    advance_again = world.remotes / "dep"
    (advance_again / "src" / "dep.sol").write_text("// dep, past v2\n")
    git(advance_again, "commit", "-qam", "dep: past v2")
    git(advance_again, "push", "-q", str(world.remotes / "dep.git"), "HEAD:main")

    moved = update(here, f"dep@{'v2' if version == 'tag' else pinned}")
    bare = update(here, "dep")

    assert moved.returncode == 0, moved.stdout + moved.stderr
    recorded_branch = subprocess.run(
        ["git", "config", "-f", ".gitmodules", "--get", "submodule.lib/dep.branch"], cwd=here, capture_output=True, text=True
    )
    assert recorded_branch.returncode == 1 and recorded_branch.stdout == "", recorded_branch.stdout
    assert bare.returncode != 0 and "is pinned" in bare.stdout, bare.stdout
    assert checked_out(here / "lib" / "dep") == pinned


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


def test_update_removes_nested_checkouts_no_remapping_uses_beneath_the_dependency_it_moves(tmp_path):
    # update leaves the dependency it moved as sync would: what the build does not read beneath it is taken
    # away. Another dependency is not what it was asked about, so its checkouts stay.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    git(here / "lib" / "dep", "submodule", "update", "--init", "--", "lib/spare")
    git(here / "lib" / "tool", "submodule", "update", "--init", "--", "lib/helper")
    advance(world, "dep")

    result = update(here, "dep@main")

    assert result.returncode == 0, result.stdout + result.stderr
    assert not (here / "lib" / "dep" / "lib" / "spare" / ".git").exists(), result.stdout
    assert (here / "lib" / "tool" / "lib" / "helper" / ".git").exists(), "another dependency is not touched"


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


# ── add: a new dependency ─────────────────────────────────────────────────────────────────────────
#
# `add -b <branch or tag> <url>`, written as `git clone` and `git submodule add` write it, clones a dependency
# into the first libs folder, under the name its url ends in, and lays it out as `git submodule add` does -
# without staging it, which is handed over.


def add(here: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([str(DEP), "add", *arguments], cwd=here, capture_output=True, text=True, env=GIT_ENV)


def published(world: World, name: str) -> str:
    return str(world.remotes / f"{name}.git")


@pytest.mark.parametrize("option", ["-b", "--branch"])
def test_add_a_branch_stands_on_it_and_records_it(tmp_path, option):
    # A dependency added at a branch follows it: HEAD stands on the branch at the remote tip, tracking it, and
    # .gitmodules records the branch, so a later bare update follows it.
    world = empty_world(tmp_path, [])
    tip = git(world.remotes / "helper", "rev-parse", "HEAD")

    result = add(world.project, option, "main", published(world, "helper"))

    assert result.returncode == 0, result.stdout + result.stderr
    helper = world.project / "lib" / "helper"
    assert checked_out(helper) == tip
    assert branch_of(helper) == "main"
    assert git(helper, "rev-parse", "--abbrev-ref", "main@{upstream}") == "origin/main"
    assert git(world.project, "config", "-f", ".gitmodules", "submodule.lib/helper.branch") == "main"


def test_add_a_tag_records_no_branch_and_detaches(tmp_path):
    # A tag names one commit, and there is no branch to follow.
    world = empty_world(tmp_path, [])
    publish_tag(world, "helper", "v1")
    tagged = git(world.remotes / "helper", "rev-parse", "HEAD")
    advance(world, "helper")

    result = add(world.project, "-b", "v1", published(world, "helper"))

    assert result.returncode == 0, result.stdout + result.stderr
    helper = world.project / "lib" / "helper"
    assert checked_out(helper) == tagged
    assert branch_of(helper) is None
    recorded_branch = subprocess.run(
        ["git", "config", "-f", ".gitmodules", "--get", "submodule.lib/helper.branch"],
        cwd=world.project,
        capture_output=True,
        text=True,
    )
    assert recorded_branch.returncode == 1 and recorded_branch.stdout == "", recorded_branch.stdout


@pytest.mark.parametrize("branch", [["-b", "main"], []], ids=["with-b", "without-b"])
def test_add_writes_the_layout_git_submodule_add_writes(tmp_path, branch):
    # Every later git command reads the submodule through this layout, so it must be git's own: what
    # `git submodule add -b main` writes in a copy of the same project. Without -b, add records the remote's
    # default branch, main here, so it writes what -b main writes.
    world = empty_world(tmp_path, [])
    twin = tmp_path / "twin"
    git(tmp_path, "clone", "-q", str(world.project), str(twin))
    git(twin, "submodule", "add", "-q", "-b", "main", published(world, "helper"), "lib/helper")

    result = add(world.project, *branch, published(world, "helper"))

    def layout(here: Path) -> tuple[str, str, str, str]:
        return (
            (here / "lib" / "helper" / ".git").read_text(),
            git(here / "lib" / "helper", "config", "core.worktree"),
            git(here, "config", "--get-regexp", r"^submodule\."),
            (here / ".gitmodules").read_text(),
        )

    assert result.returncode == 0, result.stdout + result.stderr
    assert layout(world.project) == layout(twin)


def test_after_add_the_handed_over_staging_records_a_submodule_silently(tmp_path):
    # add names the staging rather than running it. The command it names records a submodule - a gitlink, not
    # the folder's files - and prints nothing while doing so; what it records is what a fresh clone gets from
    # sync.
    world = empty_world(tmp_path, [])

    result = add(world.project, "-b", "main", published(world, "helper"))

    assert result.returncode == 0, result.stdout + result.stderr
    assert "Next, run: git add --no-warn-embedded-repo .gitmodules lib/helper && git commit" in result.stdout, (
        result.stdout
    )
    staged = subprocess.run(
        ["git", "add", "--no-warn-embedded-repo", ".gitmodules", "lib/helper"],
        cwd=world.project,
        capture_output=True,
        text=True,
        env=GIT_ENV,
    )
    assert staged.returncode == 0 and staged.stdout + staged.stderr == "", staged.stdout + staged.stderr
    assert git(world.project, "ls-files", "-s", "lib/helper").split()[0] == "160000", "a gitlink, not files"
    git(world.project, "commit", "-qm", "helper")
    fresh = clone(world)
    synced_fresh = sync(fresh)
    assert synced_fresh.returncode == 0, synced_fresh.stdout + synced_fresh.stderr
    assert checked_out(fresh / "lib" / "helper") == checked_out(world.project / "lib" / "helper")


@pytest.mark.parametrize("where", ["disk", "gitmodules", "index", "gitdir"])
def test_add_refuses_a_path_already_in_use(tmp_path, where):
    # Each is a place where git already has something at the path, and adding on top of it would mix the new
    # dependency with what is there. So add says which, and runs nothing.
    world = empty_world(tmp_path, [])
    here = world.project
    folder = here / "lib" / "helper"
    if where == "disk":
        folder.mkdir(parents=True)
        (folder / "notes.txt").write_text("mine\n")
        reason = "the folder lib/helper exists"
    elif where == "gitmodules":
        git(here, "config", "-f", ".gitmodules", "submodule.lib/helper.path", "lib/helper")
        git(here, "config", "-f", ".gitmodules", "submodule.lib/helper.url", "/elsewhere/helper.git")
        reason = ".gitmodules lists a submodule at lib/helper"
    elif where == "index":
        folder.mkdir(parents=True)
        (folder / "notes.txt").write_text("staged\n")
        git(here, "add", "lib/helper/notes.txt")
        (folder / "notes.txt").unlink()
        folder.rmdir()
        reason = "git tracks files in lib/helper"
    else:
        (here / ".git" / "modules" / "lib" / "helper").mkdir(parents=True)
        reason = ".git/modules/lib/helper exists"

    result = add(here, "-b", "main", published(world, "helper"))

    assert result.returncode != 0
    assert "Stopped: lib/helper is already in use:" in result.stdout, result.stdout
    assert reason in result.stdout, result.stdout
    assert steps(result.stdout) == [], "nothing may run"
    assert not (folder / ".git").exists()


def test_add_places_the_dependency_in_the_first_libs_directory(tmp_path):
    # forge install puts a dependency in the first of foundry.toml's libs folders, and so does add.
    world = empty_world(tmp_path, [], libs=("deps", "lib"))

    result = add(world.project, "-b", "main", published(world, "helper"))

    assert result.returncode == 0, result.stdout + result.stderr
    assert checked_out(world.project / "deps" / "helper") == git(world.remotes / "helper", "rev-parse", "HEAD")
    assert not (world.project / "lib" / "helper").exists()


def test_add_without_a_branch_takes_the_remote_default_branch_and_records_it(tmp_path):
    # Without -b, add takes the remote's default branch, as git does, and records it in .gitmodules, which git
    # does not: what the dependency follows is then written down, rather than left to whatever the remote's
    # default branch becomes.
    world = empty_world(tmp_path, [])
    tip = make_develop_the_default_branch(world, "helper")

    result = add(world.project, published(world, "helper"))

    assert result.returncode == 0, result.stdout + result.stderr
    helper = world.project / "lib" / "helper"
    assert branch_of(helper) == "develop"
    assert checked_out(helper) == tip
    assert git(world.project, "config", "-f", ".gitmodules", "submodule.lib/helper.branch") == "develop"
    assert "Following branch develop, the remote's default branch. .gitmodules records it." in result.stdout, (
        result.stdout
    )


def test_add_takes_the_url_as_given(tmp_path):
    # The version has its own option, so nothing is read out of the url: an `@` in it, as in an ssh address
    # or one with credentials, is part of the url.
    world = empty_world(tmp_path, [])
    url = str(repository(tmp_path / "user@host", "helper"))

    result = add(world.project, "-b", "main", url)

    assert result.returncode == 0, result.stdout + result.stderr
    assert checked_out(world.project / "lib" / "helper") == git(tmp_path / "user@host" / "helper", "rev-parse", "HEAD")
    assert git(world.project, "config", "-f", ".gitmodules", "submodule.lib/helper.url") == url


@pytest.mark.parametrize("version", ["no-such-branch", "commit"])
def test_add_of_a_version_the_remote_does_not_have_writes_nothing(tmp_path, version):
    # -b goes to `git clone --branch`, which asks the remote before it writes anything and takes a branch or a
    # tag, not a commit. Its refusal is shown in git's words, and no clone, gitdir or .gitmodules is left.
    world = empty_world(tmp_path, [])
    here = world.project
    named = git(world.remotes / "helper", "rev-parse", "HEAD") if version == "commit" else version

    result = add(here, "-b", named, published(world, "helper"))

    assert result.returncode != 0
    assert steps(result.stdout)[-1].startswith("failed (exit 128): git clone"), result.stdout
    assert f"Remote branch {named} not found" in result.stdout, result.stdout
    assert git(here, "status", "--porcelain", "--untracked-files=all") == "", "nothing may be written"
    assert not (here / "lib" / "helper").exists()
    assert not (here / ".git" / "modules" / "lib" / "helper").exists()


def test_add_checks_out_a_nested_path_a_remapping_already_names(tmp_path):
    # A remapping written before the dependency is added already says what the build reads from inside it.
    # That is checked out, and no other nested submodule.
    world = empty_world(tmp_path, ["inner/=lib/dep/lib/inner/src/"])

    result = add(world.project, "-b", "main", published(world, "dep"))

    assert result.returncode == 0, result.stdout + result.stderr
    assert checked_out_paths(world.project) == {"lib/dep", "lib/dep/lib/inner"}


def test_add_leaves_the_index_unchanged(tmp_path):
    world = empty_world(tmp_path, [])
    (world.project / "notes.md").write_text("staged\n")
    git(world.project, "add", "notes.md")
    staged = git(world.project, "ls-files", "--stage")

    result = add(world.project, "-b", "main", published(world, "helper"))

    assert result.returncode == 0, result.stdout + result.stderr
    assert git(world.project, "ls-files", "--stage") == staged


# ── naming a dependency ───────────────────────────────────────────────────────────────────────────


def remove(here: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([str(DEP), "remove", *arguments], cwd=here, capture_output=True, text=True, env=GIT_ENV)


def test_a_dependency_is_named_with_or_without_the_libs_folder(tmp_path):
    # Every dependency is in the first libs folder, so `dep` and `deps/dep` name the same one, for update and
    # remove as for add.
    world = empty_world(tmp_path, ["dep/=deps/dep/src/"], libs=("deps", "lib"))
    here = world.project
    git(here, "submodule", "add", "-q", published(world, "dep"), "deps/dep")
    git(here, "commit", "-qm", "dep")
    tip = advance(world, "dep")

    by_name = update(here, "dep@main")
    moved = checked_out(here / "deps" / "dep")
    with_folder = update(here, "deps/dep@main")
    removed = remove(here, "dep")

    assert by_name.returncode == 0, by_name.stdout + by_name.stderr
    assert moved == tip
    assert with_folder.returncode == 0, with_folder.stdout + with_folder.stderr
    assert removed.returncode == 0, removed.stdout + removed.stderr
    assert not (here / "deps" / "dep" / ".git").exists()


def test_a_nested_submodule_is_named_by_its_path_in_the_libs_folder(tmp_path):
    # A bare name is a dependency, so a dependency's own submodule is named by its path from the libs folder.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    git(here / "lib" / "dep", "submodule", "update", "--init", "--", "lib/spare")

    by_name = remove(here, "spare")
    by_path = remove(here, "dep/lib/spare")

    assert by_name.returncode != 0
    assert "no .gitmodules file lists a submodule at lib/spare" in by_name.stdout, by_name.stdout
    assert by_path.returncode == 0, by_path.stdout + by_path.stderr
    assert not (here / "lib" / "dep" / "lib" / "spare" / ".git").exists()


# ── remove ────────────────────────────────────────────────────────────────────────────────────────


def test_remove_deinitialises_it_and_deletes_the_repository_git_keeps(tmp_path):
    # remove does what git documents: `git submodule deinit` empties the folder, with the submodules checked
    # out inside it, and drops its .git/config entry; the repository git keeps in .git/modules is deleted by
    # hand. .gitmodules is left to the handed-over `git rm`. The other dependency is untouched.
    world = make_world(tmp_path, ["inner/=lib/dep/lib/inner/src/"])
    here = synced(world)
    assert (here / "lib" / "dep" / "lib" / "inner" / ".git").exists(), "a nested checkout must start inside it"
    tool = checked_out(here / "lib" / "tool")
    gitmodules = (here / ".gitmodules").read_text()

    result = remove(here, "dep")

    assert result.returncode == 0, result.stdout + result.stderr
    assert steps(result.stdout) == [
        "ran: git submodule deinit --force --quiet -- lib/dep",
        "ran: rm -rf .git/modules/lib/dep",
    ], result.stdout
    assert list((here / "lib" / "dep").iterdir()) == [], "the folder is empty"
    assert not (here / ".git" / "modules" / "lib" / "dep").exists()
    remaining = git(here, "config", "--get-regexp", r"^submodule\.").splitlines()
    assert remaining and all(line.startswith("submodule.lib/tool.") for line in remaining), remaining
    assert (here / ".gitmodules").read_text() == gitmodules
    assert "Next, run: git rm lib/dep && git commit" in result.stdout, result.stdout
    assert checked_out(here / "lib" / "tool") == tool


def test_remove_of_a_dependency_not_yet_staged_is_refused(tmp_path):
    # git removes a submodule it tracks; one added and not yet staged is not one, so it is staged first.
    world = empty_world(tmp_path, [])
    here = world.project
    added = add(here, "-b", "main", published(world, "helper"))
    assert added.returncode == 0, added.stdout + added.stderr

    result = remove(here, "helper")

    assert result.returncode != 0
    assert "git does not track lib/helper yet" in result.stdout, result.stdout
    assert "git add --no-warn-embedded-repo .gitmodules lib/helper" in result.stdout, result.stdout
    assert steps(result.stdout) == [], "nothing may run"
    assert (here / "lib" / "helper" / ".git").exists()


def test_remove_refuses_work_only_this_computer_has(tmp_path):
    # Removing deletes the folder, so work only this computer has stops it before anything runs. --force is
    # the user's answer once told what is at stake.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    notes = here / "lib" / "dep" / "notes.txt"
    notes.write_text("mine\n")

    refused = remove(here, "dep")
    survived = notes.is_file()
    forced = remove(here, "--force", "dep")

    assert refused.returncode != 0
    assert "lib/dep/notes.txt: not tracked by git" in refused.stdout, refused.stdout
    assert "To continue anyway: yarn dep remove --force dep" in refused.stdout, refused.stdout
    assert steps(refused.stdout) == [], "nothing may run"
    assert survived
    assert forced.returncode == 0, forced.stdout + forced.stderr
    assert list((here / "lib" / "dep").iterdir()) == [], "the folder is emptied, the work with it"


def test_after_remove_the_handed_over_git_rm_records_the_removal(tmp_path):
    # The `git rm` remove names takes the folder and the .gitmodules entry out and stages both, and a fresh
    # clone of the result syncs without the dependency.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)

    result = remove(here, "dep")

    assert result.returncode == 0, result.stdout + result.stderr
    git(here, "rm", "-q", "lib/dep")
    assert not (here / "lib" / "dep").exists()
    assert git(here, "config", "-f", ".gitmodules", "--get-regexp", r"\.path$") == "submodule.lib/tool.path lib/tool"
    git(here, "commit", "-qm", "no dep")
    fresh = tmp_path / "fresh"
    git(tmp_path, "clone", "-q", str(here), str(fresh))
    synced_fresh = sync(fresh)
    assert synced_fresh.returncode == 0, synced_fresh.stdout + synced_fresh.stderr
    assert checked_out_paths(fresh) == {"lib/tool"}


def test_remove_of_a_nested_path_only_deinitialises_it(tmp_path):
    # A dependency's own submodule is listed and recorded by that dependency, so removing it only takes away
    # the checkout. The dependency's .gitmodules and the commit it points to stay as they are, and there is
    # nothing to add or commit.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    dependency = here / "lib" / "dep"
    git(dependency, "submodule", "update", "--init", "--", "lib/spare")
    gitmodules = (dependency / ".gitmodules").read_text()
    gitlink = git(dependency, "ls-files", "-s", "lib/spare")

    result = remove(here, "lib/dep/lib/spare")

    assert result.returncode == 0, result.stdout + result.stderr
    assert steps(result.stdout) == ["ran: git -C lib/dep submodule deinit --force --quiet -- lib/spare"], result.stdout
    assert not (dependency / "lib" / "spare" / ".git").exists()
    assert (dependency / ".gitmodules").read_text() == gitmodules
    assert git(dependency, "ls-files", "-s", "lib/spare") == gitlink
    assert git(here, "status", "--porcelain") == ""
    assert "Next, run" not in result.stdout, result.stdout


def test_remove_leaves_the_index_unchanged(tmp_path):
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    (here / "notes.md").write_text("staged\n")
    git(here, "add", "notes.md")
    staged = git(here, "ls-files", "--stage")

    result = remove(here, "dep")

    assert result.returncode == 0, result.stdout + result.stderr
    assert git(here, "ls-files", "--stage") == staged


# ── status: seeing the set-up ─────────────────────────────────────────────────────────────────────
#
# `status`, after `git submodule status`, shows for each dependency, and each nested path a remapping
# uses, what it follows, what the commit it points to is, what is newer upstream, whether a remote holds
# that commit, and what the folder has. It fetches first, so "newer" is current, and changes nothing else.


def status(here: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([str(DEP), "status", *arguments], cwd=here, capture_output=True, text=True, env=GIT_ENV)


def field(output: str, path: str, label: str) -> str:
    """The text of one field in the block `status` prints for `path`."""
    block = output.split(f"\n  {path}\n", 1)[1].split("\n  lib/", 1)[0]
    return next(line.strip()[len(label) :].strip() for line in block.splitlines() if line.strip().startswith(label))


def test_status_names_what_each_dependency_follows_and_points_to(tmp_path):
    # A dependency follows the branch .gitmodules names; without one it is pinned. The commit pointed to is
    # named by what it is: a tag, the tip of the branch followed, or neither.
    world = following_main(tmp_path, ["dep/=lib/dep/src/"])
    publish_tag(world, "tool", "v1")
    here = synced(world)
    dep, tool = recorded(here, "lib/dep"), recorded(here, "lib/tool")

    result = status(here)

    assert result.returncode == 0, result.stdout + result.stderr
    assert field(result.stdout, "lib/dep", "follows") == "branch main, set in .gitmodules", result.stdout
    assert field(result.stdout, "lib/dep", "points to") == f"{dep[:10]}, the tip of origin/main", result.stdout
    assert field(result.stdout, "lib/dep", "upstream") == "nothing newer on origin/main", result.stdout
    assert field(result.stdout, "lib/tool", "follows") == "nothing: pinned at tag v1", result.stdout
    assert field(result.stdout, "lib/tool", "points to") == f"{tool[:10]}, tag v1", result.stdout


def test_status_says_a_dependency_with_no_branch_and_no_tag_is_pinned_at_a_commit(tmp_path):
    here = synced(make_world(tmp_path, ["dep/=lib/dep/src/"]))

    result = status(here)

    assert result.returncode == 0, result.stdout + result.stderr
    assert field(result.stdout, "lib/dep", "follows") == "nothing: pinned at a commit", result.stdout
    assert field(result.stdout, "lib/dep", "upstream") == "no branch or tag to compare with", result.stdout


def test_status_reports_what_is_newer_upstream(tmp_path):
    # Newer is counted on the branch followed; a dependency pinned at a tag is shown the newest tag.
    world = following_main(tmp_path, ["dep/=lib/dep/src/"])
    publish_tag(world, "tool", "v1")
    here = synced(world)
    advance(world, "dep")
    advance(world, "tool")
    publish_tag(world, "tool", "v2")

    result = status(here)

    assert result.returncode == 0, result.stdout + result.stderr
    assert field(result.stdout, "lib/dep", "upstream") == "1 newer commit on origin/main", result.stdout
    assert field(result.stdout, "lib/tool", "upstream") == "newest tag v2", result.stdout
    assert field(result.stdout, "lib/dep", "points to").endswith(", a commit"), result.stdout


def test_status_ranks_a_release_above_its_pre_releases_and_keeps_to_one_tag_naming(tmp_path):
    # Seen on real repositories: OpenZeppelin's v5.7.0 beside its v5.7.0-rc.0, and chainlink's 1.3.0 beside an
    # older v0.2.1. A pre-release is older than its release, and a tag named in another scheme is not compared.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    publish_tag(world, "tool", "v1.0.0")
    here = synced(world)
    advance(world, "tool")
    publish_tag(world, "tool", "v1.0.0-rc.1")
    work = world.remotes / "tool"
    (work / "src" / "tool.sol").write_text("// tool, moved on again\n")
    git(work, "commit", "-qam", "tool: moved on again")
    git(work, "push", "-q", str(world.remotes / "tool.git"), "HEAD:main")
    publish_tag(world, "tool", "2.0.0")

    result = status(here)

    assert result.returncode == 0, result.stdout + result.stderr
    assert field(result.stdout, "lib/tool", "upstream") == "no newer tag", result.stdout


def test_status_says_when_the_branch_followed_does_not_contain_the_commit(tmp_path):
    # Seen on OpenZeppelin's upgradeable repository, whose releases are generated on their own branches: the
    # default branch does not contain the release, so none of its commits is newer than it.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    work = world.remotes / "tool"
    git(work, "checkout", "-q", "-b", "release")
    (work / "src" / "tool.sol").write_text("// tool, released\n")
    git(work, "commit", "-qam", "tool: release")
    git(work, "tag", "v9")
    git(work, "push", "-q", str(world.remotes / "tool.git"), "release", "--tags")
    git(work, "checkout", "-q", "main")
    here = synced(world)
    git(here / "lib" / "tool", "fetch", "-q", "--tags", "origin")
    git(here / "lib" / "tool", "checkout", "-q", "v9")
    git(here, "add", "lib/tool")
    git(here, "config", "-f", ".gitmodules", "submodule.lib/tool.branch", "main")

    result = status(here)

    assert result.returncode == 0, result.stdout + result.stderr
    assert field(result.stdout, "lib/tool", "upstream") == "origin/main does not contain it", result.stdout
    assert field(result.stdout, "lib/tool", "remote") == "a remote holds it", result.stdout


@pytest.mark.parametrize(
    ("state", "expected"),
    [
        ("same", "the commit it points to"),
        ("behind", "1 commit behind it"),
        ("ahead", "1 commit ahead of it; 1 commit not pushed"),
        ("uncommitted", "the commit it points to; 1 change not committed"),
    ],
)
def test_status_reports_the_folder_against_the_pointed_commit(tmp_path, state, expected):
    # What the folder has, against the commit this repository points to, and any work only this computer has.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    dependency = here / "lib" / "dep"
    if state == "behind":
        git(dependency, "checkout", "-q", "HEAD~1")
    elif state == "ahead":
        (dependency / "src" / "Mine.sol").write_text("// mine\n")
        git(dependency, "add", "-A")
        git(dependency, "commit", "-qm", "mine")
    elif state == "uncommitted":
        (dependency / "src" / "dep.sol").write_text("// edited\n")

    result = status(here)

    assert result.returncode == 0, result.stdout + result.stderr
    assert field(result.stdout, "lib/dep", "folder").endswith(expected), result.stdout


def test_status_reports_a_pointed_commit_no_remote_holds(tmp_path):
    # A commit only this computer has cannot be fetched by anyone who clones this repository.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    dependency = here / "lib" / "dep"
    (dependency / "src" / "Mine.sol").write_text("// mine\n")
    git(dependency, "add", "-A")
    git(dependency, "commit", "-qm", "mine")
    git(here, "add", "lib/dep")

    result = status(here)

    assert result.returncode == 0, result.stdout + result.stderr
    assert field(result.stdout, "lib/dep", "remote") == "no remote holds it", result.stdout
    assert field(result.stdout, "lib/tool", "remote") == "a remote holds it", result.stdout


def test_status_changes_no_checkout_and_no_index(tmp_path):
    # status fetches, which moves only what each clone knows of its remote; checkouts, branches and the
    # index are as they were.
    world = following_main(tmp_path, ["inner/=lib/dep/lib/inner/src/"])
    here = synced(world)
    advance(world, "dep")
    before = ({path: checked_out(here / path) for path in checked_out_paths(here)}, git(here, "ls-files", "--stage"))

    result = status(here)

    assert result.returncode == 0, result.stdout + result.stderr
    assert ({path: checked_out(here / path) for path in checked_out_paths(here)}, git(here, "ls-files", "--stage")) == before
    ran = steps(result.stdout)
    assert ran and all(re.fullmatch(r"ran: git -C \S+ fetch --tags --quiet --no-recurse-submodules origin", step) for step in ran), ran


def test_status_without_fetch_reads_what_the_last_fetch_left(tmp_path):
    # --no-fetch reads only what each clone already knows of its remote, so a newer commit published since
    # the last fetch is not seen until status fetches.
    world = following_main(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    advance(world, "dep")

    offline = status(here, "--no-fetch")
    fetched = status(here)

    assert offline.returncode == 0, offline.stdout + offline.stderr
    assert steps(offline.stdout) == [], "nothing may run"
    assert field(offline.stdout, "lib/dep", "upstream") == "nothing newer on origin/main", offline.stdout
    assert field(fetched.stdout, "lib/dep", "upstream") == "1 newer commit on origin/main", fetched.stdout


# ── doctor: commits this repository points to that no remote holds ────────────────────────────────


def test_doctor_finds_nothing_when_every_pointed_commit_is_on_a_remote(tmp_path):
    here = synced(make_world(tmp_path, ["inner/=lib/dep/lib/inner/src/"]))

    assert doctor.unpublished_commit_problems(here, ["inner/=lib/dep/lib/inner/src/"]) == []


def test_doctor_reports_each_pointed_commit_no_remote_holds(tmp_path):
    # The version check passes when the folder has the commit this repository points to, even when only this
    # computer has that commit. This check is for that case: for each dependency, and each nested path a
    # remapping uses, judged against the repository that points to it.
    remappings = ["inner/=lib/dep/lib/inner/src/"]
    here = synced(make_world(tmp_path, remappings))
    for checkout, parent, path in ((here / "lib" / "dep" / "lib" / "inner", here / "lib" / "dep", "lib/inner"), (here / "lib" / "dep", here, "lib/dep")):
        (checkout / "src" / "Mine.sol").write_text("// mine\n")
        git(checkout, "add", "-A")
        git(checkout, "commit", "-qm", "mine")
        git(parent, "add", path)

    problems = doctor.unpublished_commit_problems(here, remappings)

    assert [problem.splitlines()[0] for problem in problems] == [
        f"lib/dep: no remote holds {recorded(here, 'lib/dep')[:10]}, the commit {here.name} points to",
        f"lib/dep/lib/inner: no remote holds {recorded(here, 'lib/dep/lib/inner')[:10]}, the commit lib/dep points to",
    ], problems
    assert "Repair: push it (git -C lib/dep push)" in problems[0], problems[0]
    assert "Repair: push it (git -C lib/dep/lib/inner push)" in problems[1], problems[1]
    assert [p for p in sum(doctor.submodule_problems(here, remappings), []) if p.startswith("lib/dep:")] == [], (
        "the version check sees nothing wrong here"
    )


# ── repairs name yarn dep where dep does the job ──────────────────────────────────────────────────


def test_sync_repairs_a_folder_git_cannot_read(tmp_path):
    # Doctor names `yarn dep sync` for a folder git cannot read, so sync must mend it.
    here = synced(make_world(tmp_path, ["dep/=lib/dep/src/"]))
    git(here, "config", "-f", str(here / ".git" / "modules" / "lib" / "dep" / "config"), "core.worktree", "../../../../nowhere/lib/dep")
    unreadable = subprocess.run(["git", "rev-parse", "HEAD"], cwd=here / "lib" / "dep", capture_output=True, text=True)
    assert unreadable.returncode != 0, "the folder must start unreadable"

    result = sync(here)

    assert result.returncode == 0, result.stdout + result.stderr
    assert checked_out(here / "lib" / "dep") == recorded(here, "lib/dep")


def test_update_checklist_names_yarn_dep_for_the_move(tmp_path):
    # When the move is not made, the checklist names the dep command that makes it, not the git steps inside it.
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    git(here / "lib" / "dep", "remote", "set-url", "origin", str(tmp_path / "nowhere.git"))

    result = update(here, "dep@main")

    assert result.returncode != 0
    assert "yarn dep update lib/dep@main" in result.stdout, result.stdout
    assert "git -C lib/dep checkout" not in result.stdout, result.stdout


# ── a pristine build tree: sync removes what the build does not read ─────────────────────────────────
#
# `sync` leaves the directory it is run in ready to build and holding nothing else: inside each dependency,
# only what a remapping uses is checked out, and no leftover repository remains. Anything holding work only
# this computer has is kept and named. Run inside a submodule, sync sets that submodule up for building in;
# run again in the main directory, it takes that set-up away.

INNER_REMAPPED = ["inner/=lib/dep/lib/inner/src/"]


def check_out_unused(here: Path) -> None:
    """Check out three nested submodules no remapping in INNER_REMAPPED uses, at two depths."""
    git(here / "lib" / "dep", "submodule", "update", "--init", "--", "lib/spare")
    git(here / "lib" / "dep" / "lib" / "inner", "submodule", "update", "--init", "--", "lib/deepest")
    git(here / "lib" / "tool", "submodule", "update", "--init", "--", "lib/helper")


UNUSED = ["lib/dep/lib/inner/lib/deepest", "lib/dep/lib/spare", "lib/tool/lib/helper"]


def test_status_lists_nested_checkouts_no_remapping_uses(tmp_path):
    # status is where the set-up is seen, so it names them too, with the command that removes each.
    here = synced(make_world(tmp_path, INNER_REMAPPED))
    none = status(here, "--no-fetch")
    check_out_unused(here)

    several = status(here, "--no-fetch")

    assert none.returncode == 0 and several.returncode == 0, none.stdout + several.stdout
    assert "no remapping uses it" not in none.stdout, none.stdout
    reported = [line.strip() for line in several.stdout.splitlines() if "no remapping uses it" in line]
    assert reported == [unused_checkout_line(path) for path in UNUSED], several.stdout


def test_sync_removes_nested_checkouts_no_remapping_uses(tmp_path):
    # Each one's checkout is taken away, as `yarn dep remove` does for a nested path; the one a remapping uses
    # stays.
    here = synced(make_world(tmp_path, INNER_REMAPPED))
    check_out_unused(here)

    result = sync(here)

    assert result.returncode == 0, result.stdout + result.stderr
    assert not any((here / path / ".git").exists() for path in UNUSED), result.stdout
    assert (here / "lib" / "dep" / "lib" / "inner" / ".git").exists(), "the remapped one stays"
    assert "ran: git -C lib/dep submodule deinit --force --quiet -- lib/spare" in steps(result.stdout), result.stdout
    assert "no remapping uses it" not in result.stdout, result.stdout


def test_sync_keeps_and_names_a_nested_checkout_holding_work_only_this_computer_has(tmp_path):
    # Removing a checkout deletes its folder, so one holding work only this computer has is named and kept,
    # and the others are still removed.
    here = synced(make_world(tmp_path, INNER_REMAPPED))
    check_out_unused(here)
    (here / "lib" / "dep" / "lib" / "spare" / "notes.txt").write_text("mine\n")

    result = sync(here)

    assert result.returncode == 0, result.stdout + result.stderr
    assert "Skipping lib/dep/lib/spare, because it holds work." in result.stdout, result.stdout
    assert "lib/dep/lib/spare/notes.txt: not tracked by git" in result.stdout, result.stdout
    assert (here / "lib" / "dep" / "lib" / "spare" / "notes.txt").is_file()
    assert not (here / "lib" / "tool" / "lib" / "helper" / ".git").exists(), "the others are removed"


def leave_a_repository_behind(world: World, here: Path) -> Path:
    """A git repository inside lib/dep that nothing tracks: what a version that stops declaring a checked-out
    submodule leaves. Returns its folder."""
    stranded = here / "lib" / "dep" / "stranded"
    git(here, "clone", "-q", str(world.remotes / "helper.git"), str(stranded))
    return stranded


def test_sync_removes_a_leftover_repository_inside_a_dependency(tmp_path):
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    stranded = leave_a_repository_behind(world, here)

    result = sync(here)

    assert result.returncode == 0, result.stdout + result.stderr
    assert not stranded.exists()
    assert "ran: rm -rf lib/dep/stranded" in steps(result.stdout), result.stdout


def test_sync_keeps_and_names_a_leftover_repository_holding_work(tmp_path):
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    stranded = leave_a_repository_behind(world, here)
    (stranded / "src" / "Mine.sol").write_text("// a day of work\n")
    git(stranded, "add", "-A")
    git(stranded, "commit", "-qm", "unpushed")

    result = sync(here)

    assert result.returncode == 0, result.stdout + result.stderr
    assert "Skipping lib/dep/stranded, because it holds work." in result.stdout, result.stdout
    assert (stranded / "src" / "Mine.sol").is_file()
    assert "lib/dep/stranded" in result.stdout and "is not pushed" in result.stdout, result.stdout


def sync_inside(checkout: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run([str(DEP), "sync"], cwd=checkout, capture_output=True, text=True, env=GIT_ENV)


def test_sync_inside_a_submodule_sets_it_up_for_building_in(tmp_path):
    # Run inside a dependency, sync checks out what that dependency's own build reads. It changes nothing in
    # the main directory.
    here = synced(make_world(tmp_path, ["dep/=lib/dep/src/"]))
    config = git(here, "config", "--local", "--list")

    result = sync_inside(here / "lib" / "dep")

    assert result.returncode == 0, result.stdout + result.stderr
    assert (here / "lib" / "dep" / "lib" / "inner" / ".git").exists(), "its own dependencies are checked out"
    assert (here / "lib" / "dep" / "lib" / "spare" / ".git").exists(), "its own dependencies are checked out"
    assert git(here, "config", "--local", "--list") == config, "the main directory's .git/config is unchanged"


def test_sync_in_the_main_directory_takes_away_what_a_sync_inside_set_up(tmp_path):
    # Stopping work in a submodule: sync in the main directory leaves it pristine again.
    here = synced(make_world(tmp_path, ["dep/=lib/dep/src/"]))
    sync_inside(here / "lib" / "dep")
    assert (here / "lib" / "dep" / "lib" / "spare" / ".git").exists(), "the submodule must start set up"

    result = sync(here)

    assert result.returncode == 0, result.stdout + result.stderr
    assert not (here / "lib" / "dep" / "lib" / "inner" / ".git").exists()
    assert not (here / "lib" / "dep" / "lib" / "spare" / ".git").exists()


def test_doctor_reports_nested_checkouts_no_remapping_uses(tmp_path):
    # Doctor names them, with the command that removes them.
    here = synced(make_world(tmp_path, INNER_REMAPPED))
    clean = doctor.unused_checkout_problems(here, INNER_REMAPPED)
    check_out_unused(here)

    found = doctor.unused_checkout_problems(here, INNER_REMAPPED)

    assert clean == []
    assert len(found) == 1, found
    assert [line.strip() for line in found[0].splitlines()[1:4]] == UNUSED, found[0]
    assert "Repair: yarn dep sync" in found[0], found[0]
    assert "--prune" not in found[0], found[0]


def test_doctor_names_yarn_dep_sync_for_a_leftover_repository(tmp_path):
    world = make_world(tmp_path, ["dep/=lib/dep/src/"])
    here = synced(world)
    leave_a_repository_behind(world, here)

    leftovers = [p for p in doctor.submodule_problems(here, ["dep/=lib/dep/src/"])[1] if p.startswith("lib/dep:")]

    assert len(leftovers) == 1, leftovers
    assert "Repair: yarn dep sync" in leftovers[0], leftovers[0]
