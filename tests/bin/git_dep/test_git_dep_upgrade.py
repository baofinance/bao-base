"""`git dep upgrade`: a dependency moved to a version, or to the newest commit of the branch it follows, and staged.

It is the cookbook's "Upgrade a dependency", with the checks that keep work. It leaves the commit to the person."""

from __future__ import annotations

import pytest
from git_dep_world import (
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
    recorded,
    state,
    subject,
    typed,
)


def test_upgrade_to_a_tag_moves_the_folder_and_stages_it(ready):
    # The cookbook's commands for a release tag, in its order. The new commit is staged, no commit is made, and
    # the last line says that the commit is left to do.
    project = ready.project
    tool = project / "lib" / "tool"
    before = head(project)

    done = typed(project, "git dep upgrade tool v2")

    assert done.returncode == 0, done.stderr
    assert subject(tool) == "tool t2"
    assert recorded(project, "lib/tool") == head(tool)
    assert git(project, "status", "--porcelain") == "M  lib/tool"
    assert head(project) == before
    assert printed(done)[: -len(WRITING_THE_SETTINGS)] == [
        "$ git -C lib/tool fetch --tags",
        "$ git -C lib/tool checkout --detach v2",
        "$ git -C lib/tool submodule update --init --recursive",
        "$ git add lib/tool",
    ]
    assert done.stdout.splitlines()[-1] == f"lib/tool is at {head(tool)[:10]}, and staged. Left to do: commit."


def test_upgrade_refuses_a_version_that_names_a_branch_of_the_folders_own(ready):
    # A folder from a clone has a branch `main` of its own, left at the remote's newest commit of the day of the
    # clone. Typed as the version, it would move the folder there, and not to the remote's newest commit. So
    # the run stops before it fetches, and names the command for the remote's branch. Typed as printed, that
    # command moves the folder to the remote's newest commit, and leaves it on no branch.
    project = ready.project
    tool = project / "lib" / "tool"
    stale = git(tool, "rev-parse", "main")
    newest = commit(ready.seed("tool"), "tool t3")
    before = state(project)

    stopped = typed(project, "git dep upgrade tool main")

    for_the_remotes = "git dep upgrade lib/tool origin/main"
    assert stopped.returncode == 1
    assert stopped.stderr.strip() == (
        f"lib/tool has a branch of its own named main, at {stale[:10]}. A version is a tag or a commit. "
        f"For the newest commit of the remote's branch: {for_the_remotes}"
    )
    assert printed(stopped) == []
    assert state(project) == before
    assert typed(project, for_the_remotes).returncode == 0
    assert (head(tool), branch(tool)) == (newest, None)


def test_upgrade_to_the_version_already_recorded_says_that_nothing_is_left_to_do(ready):
    # Nothing is staged, because the folder is at the commit the repository records. The last line says so.
    project = ready.project

    done = typed(project, "git dep upgrade tool v1")

    assert done.returncode == 0, done.stderr
    assert git(project, "status", "--porcelain") == ""
    assert done.stdout.splitlines()[-1] == (
        f"lib/tool is at {head(project / 'lib' / 'tool')[:10]}, the commit already recorded. Nothing is left to do."
    )


def test_upgrade_brings_the_folders_beneath_to_the_new_versions_records(ready):
    # The new version records a newer commit of one folder beneath it, and has a dependency that the old one
    # lacks. The first is moved. The second is checked out, and gets the settings a new folder lacks.
    project = ready.project
    tool = project / "lib" / "tool"

    done = typed(project, "git dep upgrade tool v2")

    assert done.returncode == 0, done.stderr
    assert subject(tool / "lib" / "deep") == "deep d2"
    assert subject(tool / "lib" / "shared") == "shared s1"
    assert {key: own_setting(tool / "lib" / "shared", key) for key in THE_THREE} == THE_THREE


def test_upgrade_leaves_a_folder_beneath_that_is_on_a_branch_and_names_it(ready):
    # A folder on a branch is one somebody works in. git's own update would put it at the commit the new
    # version records, on no branch. It stays on its branch, at its commit, and the run names it. The other
    # folder beneath the dependency is still checked out.
    project = ready.project
    tool, deep = project / "lib" / "tool", project / "lib" / "tool" / "lib" / "deep"
    git(deep, "switch", "-q", "-c", "side")
    work = a_commit_in(deep, "deep side")

    done = typed(project, "git dep upgrade tool v2")

    assert done.returncode == 0, done.stderr
    assert (branch(deep), head(deep)) == ("side", work)
    assert "lib/tool/lib/deep: left on its branch side" in done.stdout.splitlines()
    assert subject(tool / "lib" / "shared") == "shared s1"
    assert (subject(tool), recorded(project, "lib/tool")) == ("tool t2", head(tool))


def test_upgrade_with_no_version_moves_to_the_tip_of_the_branch_it_follows(ready):
    # lib/dep follows main. A teammate's newer commit there, which also records a newer commit of a folder
    # beneath it, is what the folder ends at, staged. The commands are the cookbook's, in its order.
    project = ready.project
    newer_shared = commit(ready.seed("shared"), "shared s2")
    point(ready.seed("dep"), "lib/shared", newer_shared)
    tip = commit(ready.seed("dep"), "dep c2")

    done = typed(project, "git dep upgrade dep")

    assert done.returncode == 0, done.stderr
    assert (head(project / "lib" / "dep"), recorded(project, "lib/dep")) == (tip, tip)
    assert head(project / "lib" / "dep" / "lib" / "shared") == newer_shared
    assert printed(done)[: -len(WRITING_THE_SETTINGS)] == [
        "$ git submodule update --remote lib/dep",
        "$ git -C lib/dep submodule update --init --recursive",
        "$ git add lib/dep",
    ]


def test_upgrade_with_no_version_refuses_a_dependency_that_follows_no_branch(ready):
    # git alone would move such a dependency to the newest commit of its remote's default branch. Nothing is
    # fetched and nothing is moved.
    project = ready.project
    before = state(project)

    stopped = typed(project, "git dep upgrade tool")

    assert stopped.returncode == 1
    assert stopped.stderr.strip() == (
        "lib/tool follows no branch: .gitmodules has no branch line for it. "
        "To move it to a version: git dep upgrade lib/tool <version>"
    )
    assert printed(stopped) == []
    assert state(project) == before


@pytest.mark.parametrize("where", ["lib/tool", "lib/tool/lib/deep"])
def test_upgrade_stops_at_a_commit_on_no_branch_that_no_remote_has(ready, where):
    # In the folder, and in a folder beneath it. The upgrade would move both, and leave such a commit reachable
    # from git's reflog alone. Nothing is fetched and nothing is moved.
    project = ready.project
    made = a_commit_in(project / where, "made on no branch")
    before = state(project)

    stopped = typed(project, "git dep upgrade tool v2")

    assert stopped.returncode == 1
    assert stopped.stderr.strip() == (
        f"{where}: its commit {made[:10]} is on no branch and on no remote. "
        f"To put it on a branch: git -C {where} switch -c <branch>"
    )
    assert printed(stopped) == []
    assert state(project) == before


def test_upgrade_goes_through_with_a_commit_on_no_branch_in_another_dependency(ready):
    # The check is on the folders the upgrade moves. Another dependency is not moved, and keeps its commit.
    project = ready.project
    made = a_commit_in(project / "lib" / "shared", "made on no branch")

    done = typed(project, "git dep upgrade tool v2")

    assert done.returncode == 0, done.stderr
    assert subject(project / "lib" / "tool") == "tool t2"
    assert head(project / "lib" / "shared") == made


def test_upgrade_stops_for_a_version_the_remote_does_not_have(ready):
    # After the fetch the folder has no tag and no commit of that name. git's own answer to the checkout is
    # `--detach does not take a path argument`, so the run stops before it, and says what is missing. The
    # folder is where it was, and nothing is staged.
    project = ready.project
    before = state(project)

    stopped = typed(project, "git dep upgrade tool v9")

    assert stopped.returncode == 1
    assert stopped.stderr.splitlines()[-1] == "lib/tool has no tag or commit named v9, after the fetch from its remote."
    assert printed(stopped) == ["$ git -C lib/tool fetch --tags"]
    assert state(project) == before


def test_upgrade_refuses_a_folder_that_is_not_checked_out(ready):
    # A git command typed for an empty folder acts on the repository around it. So none is typed for a folder
    # that is not checked out: the run names the command that checks it out. Typed as printed, that command
    # lets the next run through.
    project = ready.project
    git(project, "submodule", "deinit", "-q", "--", "lib/tool")
    before = state(project)

    stopped = typed(project, "git dep upgrade tool v2")

    checking_it_out = "git submodule update --init --recursive -- lib/tool"
    assert stopped.returncode == 1
    assert stopped.stderr.strip() == f"lib/tool: not checked out. To check it out: {checking_it_out}"
    assert printed(stopped) == []
    assert state(project) == before
    assert typed(project, checking_it_out).returncode == 0
    assert typed(project, "git dep upgrade tool v2").returncode == 0
    assert subject(project / "lib" / "tool") == "tool t2"


def test_upgrade_names_a_folder_beneath_that_git_skipped_for_an_update_none_setting(ready):
    # git skips a folder whose update setting is none, in a line that is easy to miss. The upgrade is done and
    # staged, and the run then names the folder beneath the dependency that is still not checked out, with the
    # command that takes the setting out. A folder elsewhere that is not checked out is not its concern.
    project = ready.project
    tool = project / "lib" / "tool"
    git(tool, "submodule", "deinit", "-q", "--", "lib/deep")
    git(tool, "config", "submodule.lib/deep.update", "none")
    git(project, "submodule", "deinit", "-q", "--", "lib/shared")

    left = typed(project, "git dep upgrade tool v2")

    assert left.returncode == 1
    assert left.stderr.splitlines()[-1] == (
        "lib/tool/lib/deep: not checked out. git skips it, because its update setting is none. "
        "To take the setting out: git -C lib/tool config --unset submodule.lib/deep.update"
    )
    assert not [line for line in left.stderr.splitlines() if line.startswith("lib/shared:")]
    assert (subject(tool), recorded(project, "lib/tool")) == ("tool t2", head(tool))


def test_upgrade_of_bao_base_itself_finishes_with_the_copy_that_started(ready):
    # The upgrade replaces the script's own file while it runs. The run goes on with the copy it started with,
    # to its last command. The file in the folder is then the new version's: the next `git dep` runs it.
    project = ready.project
    base = ready.seed("base")
    (base / "bin" / "git-dep").write_text("#!/bin/sh\necho the newer copy ran\nexit 3\n")
    newer = commit(base, "base b3")
    git(base, "tag", "b3")
    git(base, "push", "-q", "origin", "--tags")

    done = typed(project, "git dep upgrade bao-base b3")

    assert done.returncode == 0, done.stderr
    assert (head(project / "lib" / "bao-base"), recorded(project, "lib/bao-base")) == (newer, newer)
    assert printed(done)[-len(WRITING_THE_SETTINGS) :] == WRITING_THE_SETTINGS
    assert "the newer copy ran" not in done.stdout
    the_next = typed(project, "git dep help")
    assert (the_next.returncode, the_next.stdout.strip()) == (3, "the newer copy ran")
