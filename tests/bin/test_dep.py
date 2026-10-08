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
from pathlib import Path
from typing import NamedTuple

import pytest

BAO_BASE = Path(__file__).resolve().parents[2]
DEP = BAO_BASE / "bin" / "dep"

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
    assert "! ds-test/=lib/dep/lib/ds-test/src/ - no submodule provides lib/dep/lib/ds-test/src" in result.stdout
    assert "! @uniswap/v3-core/=lib/v3-core/ - no submodule provides lib/v3-core" in result.stdout
    assert checked_out_paths(here) == TOP_LEVEL


def test_sync_refuses_work_that_exists_nowhere_else(tmp_path):
    # Moving a checkout is what would put a developer's files at risk, so anything under a dependency sync
    # would move that exists on no remote stops it before any step runs.
    here = clone(make_world(tmp_path, ["dep/=lib/dep/src/"]))
    sync(here)
    dependency = here / "lib" / "dep"
    git(dependency, "checkout", "-q", "HEAD~1")
    (dependency / "notes.txt").write_text("mine\n")
    stale = checked_out(dependency)

    result = sync(here)

    assert result.returncode != 0
    assert "lib/dep/notes.txt" in result.stdout and "exists nowhere else" in result.stdout, result.stdout
    assert steps(result.stdout) == [], "nothing may run"
    assert checked_out(dependency) == stale


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


def record_an_unpushed_nested_commit(world: World) -> str:
    """Commit inside dep's own checkout of inner without publishing it, record that in dep and then in the
    project, and return the commit - which no remote holds."""
    dep_work = world.remotes / "dep"
    nested = dep_work / "lib" / "inner"
    (nested / "src" / "Local.sol").write_text("// never published\n")
    git(nested, "add", "-A")
    git(nested, "commit", "-qm", "never published")
    commit = git(nested, "rev-parse", "HEAD")
    git(dep_work, "add", "lib/inner")
    git(dep_work, "commit", "-qm", "dep records it")
    git(dep_work, "push", "-q", str(world.remotes / "dep.git"), "HEAD:main")
    project_dep = world.project / "lib" / "dep"
    git(project_dep, "fetch", "-q", "origin")
    git(project_dep, "checkout", "-q", "origin/main")
    git(world.project, "add", "lib/dep")
    git(world.project, "commit", "-qm", "project records it")
    return commit


def test_a_sync_failure_reports_gits_error_the_steps_run_and_where_things_stand(tmp_path):
    # The shape that stranded lib/harbor, on a path a remapping does name: dep records a nested commit its
    # remote never received. sync stops there and undoes nothing, printing every step it ran in order, git's
    # own error, and where each dependency now stands - enough to unpick by hand.
    world = make_world(tmp_path, ["inner/=lib/dep/lib/inner/src/"])
    unpushed = record_an_unpushed_nested_commit(world)
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
    assert "[ ] lib/dep/lib/inner - recorded " in result.stdout, result.stdout
    # inner does provide the remapped path; it is the checkout that failed, and the row above says so
    assert "no submodule provides" not in result.stdout, result.stdout
