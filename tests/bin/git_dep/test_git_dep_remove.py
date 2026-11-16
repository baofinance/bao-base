"""`git dep remove`: a dependency removed, after a look for work that only this computer has.

It is the cookbook's "Remove a dependency". git's own removal does not look at branches or stashes, and the
repository git keeps for the dependency is deleted with every one of them. It leaves the remappings and the
commit to the person."""

from __future__ import annotations

import pytest
from git_dep_world import a_commit_in, git, head, printed, state, typed

NOT_REMOVED = "lib/tool is not removed: that work would be deleted with it."


def sections(project) -> set[str]:
    """The dependencies that the repository's own settings hold lines for, by name."""
    names = git(project, "config", "--local", "--list", "--name-only").splitlines()
    return {name.rsplit(".", 1)[0][len("submodule.") :] for name in names if name.startswith("submodule.lib/")}


def test_remove_deletes_the_folder_its_entry_and_what_git_keeps_for_it(ready):
    # The cookbook's three commands, in its order: the folder and its entry in .gitmodules, the repository git
    # keeps for the dependency, and the lines git leaves in the repository's settings. The removal is staged,
    # and no commit is made.
    project = ready.project
    before = head(project)

    done = typed(project, "git dep remove tool")

    assert done.returncode == 0, done.stderr
    assert not (project / "lib" / "tool").exists()
    assert typed(project, "git config --file .gitmodules --get submodule.lib/tool.path").returncode == 1
    assert not (project / ".git" / "modules" / "lib" / "tool").exists()
    assert sections(project) == {"lib/bao-base", "lib/dep", "lib/shared"}
    assert git(project, "status", "--porcelain").splitlines() == ["M  .gitmodules", "D  lib/tool"]
    assert head(project) == before
    assert printed(done) == [
        "$ git rm lib/tool",
        "$ rm -rf .git/modules/lib/tool",
        "$ git config --remove-section submodule.lib/tool",
    ]


def test_remove_says_what_is_left_to_do(ready):
    # It makes no commit, and it does not know the dependency's remappings. Its last line says both are left.
    done = typed(ready.project, "git dep remove tool")

    assert done.stdout.splitlines()[-1] == (
        "lib/tool is removed, and the removal is staged. Left to do: take its remappings out, then commit. "
        'See "Remove a dependency" in the cookbook: git dep cookbook'
    )


@pytest.mark.parametrize(
    ("where", "file"), [("lib/tool", "tool.txt"), ("lib/tool/lib/deep", "a-file-git-does-not-track.txt")]
)
def test_remove_stops_at_uncommitted_changes(ready, where, file):
    # In the folder: an edit to a file git tracks. In a folder beneath it: a file git does not track. Nothing
    # is removed, and the change is as it was.
    project = ready.project
    with (project / where / file).open("a") as changed:
        changed.write("not committed\n")
    before = state(project)

    stopped = typed(project, "git dep remove tool")

    assert stopped.returncode == 1
    assert stopped.stderr.splitlines() == [
        f"{where}: uncommitted changes. To list: git -C {where} status --short",
        NOT_REMOVED,
    ]
    assert printed(stopped) == []
    assert state(project) == before
    assert (project / where / file).read_text().endswith("not committed\n")


@pytest.mark.parametrize("case", ["on the branch the folder is on", "on another branch", "beneath"])
def test_remove_stops_at_commits_no_remote_has(ready, case):
    # git's own removal does not look at branches. One commit on the branch the folder is on; two on a branch
    # it is not on; one in a folder beneath it. Nothing is removed.
    project = ready.project
    where = "lib/tool/lib/deep" if case == "beneath" else "lib/tool"
    folder = project / where
    at = head(folder)
    git(folder, "switch", "-q", "-c", "work")
    a_commit_in(folder, "work one")
    if case == "on another branch":
        a_commit_in(folder, "work two")
        git(folder, "switch", "-q", "--detach", at)
    counted = "2 commits" if case == "on another branch" else "1 commit"

    stopped = typed(project, "git dep remove tool")

    assert stopped.returncode == 1
    assert stopped.stderr.splitlines() == [
        f"{where}: {counted} that no remote has. To list: git -C {where} log HEAD --branches --not --remotes --oneline",
        NOT_REMOVED,
    ]
    assert printed(stopped) == []
    assert git(folder, "rev-parse", "work") != at
    assert (project / ".git" / "modules" / "lib" / "tool").exists()


def test_remove_stops_at_a_stash(ready):
    # git's own removal does not look at stashes, and a stash leaves nothing uncommitted behind. Two stashes
    # in the folder, and one in a folder beneath it. Nothing is removed.
    project = ready.project
    tool, deep = project / "lib" / "tool", project / "lib" / "tool" / "lib" / "deep"
    # Each stash holds a text of its own: git lists two stashes made alike within one second as one.
    for folder, file, text in ((tool, "tool.txt", "first"), (tool, "tool.txt", "second"), (deep, "deep.txt", "third")):
        with (folder / file).open("a") as changed:
            changed.write(f"put aside {text}\n")
        git(folder, "stash", "-q")

    stopped = typed(project, "git dep remove tool")

    assert stopped.returncode == 1
    assert stopped.stderr.splitlines() == [
        "lib/tool: 2 stashes. To list: git -C lib/tool stash list",
        "lib/tool/lib/deep: 1 stash. To list: git -C lib/tool/lib/deep stash list",
        NOT_REMOVED,
    ]
    assert printed(stopped) == []
    assert len(git(tool, "stash", "list").splitlines()) == 2


def test_remove_works_on_a_folder_that_is_not_checked_out(ready):
    # The repository git keeps for it still holds its branches, so it is still examined: a commit that only it
    # holds stops the removal. Once a remote has the commit, the removal deletes the kept repository. git took
    # the lines out of the settings when the folder was emptied, so that command is not run.
    project = ready.project
    tool, kept = project / "lib" / "tool", project / ".git" / "modules" / "lib" / "tool"
    git(tool, "switch", "-q", "-c", "work")
    a_commit_in(tool, "tool work")
    git(tool, "switch", "-q", "--detach", "v1")
    git(project, "submodule", "deinit", "-q", "--", "lib/tool")

    stopped = typed(project, "git dep remove tool")

    listing = "git --git-dir .git/modules/lib/tool --work-tree . log HEAD --branches --not --remotes --oneline"
    assert stopped.returncode == 1
    assert stopped.stderr.splitlines() == [
        f".git/modules/lib/tool: 1 commit that no remote has. To list: {listing}",
        NOT_REMOVED,
    ]
    assert typed(project, listing).stdout.split(maxsplit=1)[1].strip() == "tool work"
    assert kept.exists()

    git(project, "--git-dir", ".git/modules/lib/tool", "--work-tree", ".", "push", "-q", "origin", "work")
    done = typed(project, "git dep remove tool")

    assert done.returncode == 0, done.stderr
    assert printed(done) == ["$ git rm lib/tool", "$ rm -rf .git/modules/lib/tool"]
    assert not tool.exists()
    assert not kept.exists()


def test_remove_stops_at_work_in_a_repository_git_keeps_for_a_folder_that_is_gone(ready):
    # An upgrade to a version that no longer has one of its dependencies leaves that folder behind, and
    # deleting the folder leaves the repository git keeps for it. That repository is deleted with the
    # dependency, so a commit that only it holds stops the removal.
    project = ready.project
    tool = project / "lib" / "tool"
    assert typed(project, "git dep upgrade tool v2").returncode == 0
    git(tool / "lib" / "shared", "switch", "-q", "-c", "work")
    a_commit_in(tool / "lib" / "shared", "shared work")
    assert typed(project, "git dep upgrade tool v1").returncode == 0
    git(tool, "clean", "-ffdq", "--", "lib/shared")

    stopped = typed(project, "git dep remove tool")

    kept = ".git/modules/lib/tool/modules/lib/shared"
    assert stopped.returncode == 1
    assert stopped.stderr.splitlines() == [
        f"{kept}: 1 commit that no remote has. "
        f"To list: git --git-dir {kept} --work-tree . log HEAD --branches --not --remotes --oneline",
        NOT_REMOVED,
    ]
    assert printed(stopped) == []
    assert (project / kept).exists()


def test_remove_finds_what_git_keeps_when_the_name_differs_from_the_folder(ready):
    # After `git mv`, .gitmodules still names the dependency by its first folder, and so do the repository git
    # keeps and the lines in the settings. The folder is removed by its path, and the other two by the name.
    project = ready.project
    git(project, "mv", "lib/tool", "lib/moved")
    git(project, "commit", "-qm", "tool moved")

    done = typed(project, "git dep remove moved")

    assert done.returncode == 0, done.stderr
    assert printed(done) == [
        "$ git rm lib/moved",
        "$ rm -rf .git/modules/lib/tool",
        "$ git config --remove-section submodule.lib/tool",
    ]
    assert not (project / "lib" / "moved").exists()
    assert not (project / ".git" / "modules" / "lib" / "tool").exists()
    assert sections(project) == {"lib/bao-base", "lib/dep", "lib/shared"}


def test_remove_deletes_nothing_when_git_refuses_the_removal(ready):
    # git refuses to remove a folder that is not at the commit recorded for it. Its own message and status are
    # what the run ends with. The folder and the repository git keeps for it are still there.
    project = ready.project
    git(project / "lib" / "tool", "checkout", "-q", "v2")

    stopped = typed(project, "git dep remove tool")

    assert stopped.returncode == 1
    assert "the following file has local modifications" in stopped.stderr, stopped.stderr
    assert printed(stopped) == ["$ git rm lib/tool"]
    assert (project / "lib" / "tool" / ".git").exists()
    assert (project / ".git" / "modules" / "lib" / "tool" / "HEAD").exists()
    assert sections(project) == {"lib/bao-base", "lib/dep", "lib/shared", "lib/tool"}
