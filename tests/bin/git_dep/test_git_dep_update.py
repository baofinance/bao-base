"""`git dep update`: every folder at the commit recorded for it, at every depth, with the checks that keep work.

It is the cookbook's procedure for after a pull, a merge or a branch switch. It ends by writing the settings,
because a folder it checked out for the first time holds none."""

from __future__ import annotations

import pytest
from git_dep_world import (
    BY_PATH,
    FOLDERS,
    THE_THREE,
    WRITING_THE_SETTINGS,
    a_commit_in,
    branch,
    commit,
    git,
    head,
    own_setting,
    point,
    printed,
    setting,
    subject,
    typed,
)


def a_teammate_moves_shared(world) -> str:
    """A teammate commits in shared, makes the project record it, and pushes. Returns shared's new commit."""
    newer = commit(world.seed("shared"), "shared s2")
    point(world.seed("proj"), "lib/shared", newer)
    commit(world.seed("proj"), "proj p2")
    return newer


def test_update_checks_out_every_folder_that_is_missing(world):
    # A clone made without its dependencies, with only lib/bao-base checked out so that the script is there:
    # every other folder is checked out, at every depth, at the commit recorded for it.
    second = world.root / "second"
    git(world.root, "clone", "-q", str(world.remote("proj")), str(second))
    git(second, "submodule", "--quiet", "update", "--init", "lib/bao-base")

    done = typed(second, f"{BY_PATH} update")

    assert done.returncode == 0, done.stderr
    assert {folder: subject(second / folder) for folder in FOLDERS if (second / folder / ".git").exists()} == {
        folder: subject(world.project / folder) for folder in FOLDERS
    }
    # Each folder it checked out holds the settings: they are written last.
    assert {folder: {key: setting(second / folder, key) for key in THE_THREE} for folder in FOLDERS} == {
        folder: THE_THREE for folder in FOLDERS
    }


def test_update_in_a_repository_with_no_dependency_succeeds(world):
    # Nothing to move: git's update is not run, and the repository's own settings are written.
    alone = world.root / "base-alone"
    git(world.root, "clone", "-q", str(world.remote("base")), str(alone))

    done = typed(alone, "bin/git-dep update")

    assert done.returncode == 0, done.stderr
    assert not [line for line in printed(done) if "submodule update" in line]
    assert {key: own_setting(alone, key) for key in THE_THREE} == THE_THREE


def test_update_moves_a_folder_to_the_commit_its_parent_records(ready):
    # After a pull that moved a record at the top, and one beneath a dependency.
    project = ready.project
    newer = commit(ready.seed("shared"), "shared s2")
    point(ready.seed("dep"), "lib/shared", newer)
    moved_dep = commit(ready.seed("dep"), "dep c2")
    point(ready.seed("proj"), "lib/dep", moved_dep)
    point(ready.seed("proj"), "lib/shared", newer)
    commit(ready.seed("proj"), "proj p2")
    git(project, "pull", "-q")

    done = typed(project, "git dep update")

    assert done.returncode == 0, done.stderr
    assert [subject(project / folder) for folder in ("lib/dep", "lib/dep/lib/shared", "lib/shared")] == [
        "dep c2",
        "shared s2",
        "shared s2",
    ]


def test_update_runs_gits_one_recursive_command_when_no_folder_is_on_a_branch(world):
    # The cookbook's one command, then the commands that write the settings and the alias, in that order.
    done = typed(world.project, f"{BY_PATH} update")

    assert done.returncode == 0, done.stderr
    assert printed(done) == ["$ git submodule update --init --recursive", *WRITING_THE_SETTINGS]


def test_update_leaves_a_folder_that_is_on_a_branch_and_names_it(ready):
    # At the top, and beneath a dependency. git's own update would put each back at the recorded commit, on no
    # branch, and the build would then use the older commit. The other folders are still moved: git's command
    # is run for them by name, and one command per level on the way down to a folder that is left.
    project = ready.project
    tool, nested = project / "lib" / "tool", project / "lib" / "dep" / "lib" / "shared"
    git(tool, "switch", "-q", "-c", "work")
    git(nested, "switch", "-q", "-c", "side")
    work, side = a_commit_in(tool, "tool work"), a_commit_in(nested, "shared side")
    a_teammate_moves_shared(ready)
    git(project, "pull", "-q")

    done = typed(project, "git dep update")

    assert done.returncode == 0, done.stderr
    assert (branch(tool), head(tool)) == ("work", work)
    assert (branch(nested), head(nested)) == ("side", side)
    assert subject(project / "lib" / "shared") == "shared s2"
    assert "lib/tool: left on its branch work" in done.stdout.splitlines()
    assert "lib/dep/lib/shared: left on its branch side" in done.stdout.splitlines()
    assert printed(done)[: -len(WRITING_THE_SETTINGS)] == [
        "$ git submodule update --init --recursive -- lib/bao-base lib/shared",
        "$ git submodule update --init -- lib/dep",
        "$ git -C lib/dep submodule update --init --recursive -- lib/bao-base",
        "$ git -C lib/tool submodule update --init --recursive",
    ]


def test_update_moves_the_folders_beneath_a_folder_that_is_on_a_branch(ready):
    # lib/tool stays on its branch. The folder beneath it is put at the commit that branch records.
    project = ready.project
    tool, deep = project / "lib" / "tool", project / "lib" / "tool" / "lib" / "deep"
    older = head(deep)
    git(tool, "switch", "-q", "-c", "work")
    git(deep, "checkout", "-q", "origin/main")
    git(tool, "add", "lib/deep")
    git(tool, "commit", "-qm", "tool: deep moved on")
    git(deep, "checkout", "-q", older)

    done = typed(project, "git dep update")

    assert done.returncode == 0, done.stderr
    assert branch(tool) == "work"
    assert subject(deep) == "deep d2"


@pytest.mark.parametrize("where", ["lib/shared", "lib/dep/lib/shared"])
def test_update_stops_before_moving_anything_at_a_commit_on_no_branch_that_no_remote_has(ready, where):
    # At the top, and beneath a dependency. Moving such a folder would leave its commit reachable from git's
    # reflog alone. So nothing is moved: every folder is where it was. Typed as printed, the command named puts
    # the commit on a branch, and the next run goes through and leaves that folder on it.
    project = ready.project
    made = a_commit_in(project / where, "made on no branch")
    git(project / "lib" / "tool", "checkout", "-q", "v2")

    stopped = typed(project, "git dep update")

    assert stopped.returncode == 1
    assert stopped.stderr.strip() == (
        f"{where}: its commit {made[:10]} is on no branch and on no remote. "
        f"To put it on a branch: git -C {where} switch -c <branch>"
    )
    assert printed(stopped) == []
    assert subject(project / "lib" / "tool") == "tool t2"
    assert typed(project, f"git -C {where} switch -c kept").returncode == 0
    assert typed(project, "git dep update").returncode == 0
    assert subject(project / "lib" / "tool") == "tool t1"
    assert (branch(project / where), head(project / where)) == ("kept", made)


def test_update_stops_with_gits_error_when_a_move_would_overwrite_an_edit(ready):
    # git refuses the move, and its own message and status are what the run ends with. The edit is intact.
    project = ready.project
    edited = project / "lib" / "shared" / "shared.txt"
    with edited.open("a") as file:
        file.write("an edit\n")
    a_teammate_moves_shared(ready)
    git(project, "pull", "-q")

    stopped = typed(project, "git dep update")

    assert stopped.returncode == 1
    assert "would be overwritten by checkout" in stopped.stderr, stopped.stderr
    assert edited.read_text().endswith("an edit\n")
    assert subject(project / "lib" / "shared") == "shared s1"


def test_update_names_the_cookbooks_section_once_for_the_folders_git_skipped(ready):
    # git skips a folder whose update setting is none, and says so in a line that is easy to miss. The run
    # names each such folder, at the top and beneath a dependency. It names once the cookbook's section whose
    # one command takes every such setting out, in every config file. That command, typed as the cookbook
    # has it, lets the next run check the folders out.
    project = ready.project
    git(project, "submodule", "deinit", "-q", "--force", "--", "lib/shared")
    git(project, "config", "submodule.lib/shared.update", "none")
    git(project / "lib" / "dep", "submodule", "deinit", "-q", "--force", "--", "lib/shared")
    git(project / "lib" / "dep", "config", "submodule.lib/shared.update", "none")

    left = typed(project, "git dep update")

    assert left.returncode == 1
    section = "A clone that `yarn dep` managed"
    assert left.stderr.splitlines()[-3:] == [
        "lib/dep/lib/shared: not checked out. git skips it, because its update setting is none.",
        "lib/shared: not checked out. git skips it, because its update setting is none.",
        f'To take every such setting out, see "{section}" in the cookbook: git dep cookbook',
    ]
    in_the_cookbook = typed(project, "git dep cookbook").stdout.partition(f"## {section}\n")[2].partition("\n## ")[0]
    command = in_the_cookbook.partition("```\n")[2].partition("\n```")[0]
    assert command.startswith("find "), "the section's first block is the command that takes the settings out"
    assert typed(project, command).returncode == 0
    assert typed(project, "git dep update").returncode == 0
    assert (project / "lib" / "shared" / ".git").exists()
    assert (project / "lib" / "dep" / "lib" / "shared" / ".git").exists()
