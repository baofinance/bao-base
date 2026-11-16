"""`git dep status`: each thing it names about a dependency folder, and that it changes nothing."""

from __future__ import annotations

import os
from pathlib import Path

from git_dep_world import BY_PATH, commit, git, head, typed


def report(where: Path, command: str = "git dep status") -> list[str]:
    """The lines `status` prints, which must end with status 0: it is a report, not a check."""
    done = typed(where, command)
    assert done.returncode == 0, done.stderr
    return done.stdout.splitlines()


def every_file(top: Path) -> dict[str, tuple[int, int]]:
    """Each file under `top`, git's own included, with its size and the time it was last written."""
    found = {}
    for folder, _, names in os.walk(top):
        for name in names:
            path = Path(folder) / name
            stat = path.lstat()
            found[str(path)] = (stat.st_size, stat.st_mtime_ns)
    return found


def a_commit_in(folder: Path, subject: str) -> str:
    """A commit made in the folder as it stands, with a file of its own. Returns the commit."""
    (folder / f"{subject.replace(' ', '-')}.txt").write_text(f"{subject}\n")
    git(folder, "add", "-A")
    git(folder, "commit", "-qm", subject)
    return head(folder)


def test_status_counts_the_folders_and_names_none_when_all_is_as_recorded(ready):
    # A repository with no dependency, with one, and with several at two depths: each folder at the commit
    # recorded for it, on no branch, holding nothing of this computer's alone.
    project = ready.project
    with_none, with_one = ready.root / "base-alone", ready.root / "tool-alone"
    git(ready.root, "clone", "-q", str(ready.remote("base")), str(with_none))
    git(ready.root, "clone", "-q", "--recurse-submodules", str(ready.remote("tool")), str(with_one))

    assert report(with_none, "bin/git-dep status") == ["no dependency folders"]
    assert report(with_one, f"{project / BY_PATH} status") == ["1 dependency folder: nothing to report"]
    assert report(project) == ["7 dependency folders: nothing to report"]


def test_status_names_a_folder_that_is_not_checked_out(ready):
    project = ready.project
    git(project, "submodule", "deinit", "-q", "--force", "--", "lib/shared")

    assert report(project) == ["lib/shared: not checked out", "7 dependency folders: 1 named above"]


def test_status_names_a_folder_not_at_the_commit_its_parent_records(ready):
    # At the top, and beneath a dependency: both commits are shown, and the repository that records one is named.
    project = ready.project
    recorded = head(project / "lib" / "shared")
    newer = commit(ready.seed("shared"), "shared s2")
    for folder in (project / "lib" / "shared", project / "lib" / "dep" / "lib" / "shared"):
        git(folder, "fetch", "-q", "origin")
        git(folder, "checkout", "-q", newer)

    assert report(project) == [
        f"lib/dep/lib/shared: at {newer[:10]}, and lib/dep records {recorded[:10]}",
        f"lib/shared: at {newer[:10]}, and this repository records {recorded[:10]}",
        "7 dependency folders: 2 named above",
    ]


def test_status_names_a_folder_on_a_branch(ready):
    project = ready.project
    git(project / "lib" / "dep", "switch", "-q", "-c", "work")

    assert report(project) == ["lib/dep: on branch work", "7 dependency folders: 1 named above"]


def test_status_names_a_commit_on_no_branch_that_no_remote_has(ready):
    # An update would leave such a commit behind, reachable from git's reflog alone. status gives the command
    # that puts it on a branch, and typed as printed that command does.
    project = ready.project
    shared = project / "lib" / "shared"
    recorded = head(shared)
    made = a_commit_in(shared, "made on no branch")

    found = report(project)
    typed(project, "git -C lib/shared switch -c kept")
    afterwards = report(project)

    assert found == [
        f"lib/shared: at {made[:10]}, and this repository records {recorded[:10]}",
        "lib/shared: its commit is on no branch and on no remote. "
        "To put it on a branch: git -C lib/shared switch -c <branch>",
        "lib/shared: 1 commit that no remote has",
        "7 dependency folders: 1 named above",
    ]
    assert afterwards == [
        "lib/shared: on branch kept",
        f"lib/shared: at {made[:10]}, and this repository records {recorded[:10]}",
        "lib/shared: 1 commit that no remote has",
        "7 dependency folders: 1 named above",
    ]


def test_status_counts_the_commits_only_this_computer_has(ready):
    # Counted over every branch of the folder, not only the one checked out.
    project = ready.project
    dep = project / "lib" / "dep"
    recorded = head(dep)
    git(dep, "switch", "-q", "-c", "work")
    a_commit_in(dep, "work one")
    a_commit_in(dep, "work two")
    git(dep, "switch", "-q", "-c", "other", recorded)
    now = a_commit_in(dep, "other one")

    assert report(project) == [
        "lib/dep: on branch other",
        f"lib/dep: at {now[:10]}, and this repository records {recorded[:10]}",
        "lib/dep: 3 commits that no remote has",
        "7 dependency folders: 1 named above",
    ]


def test_status_names_uncommitted_changes_in_the_folder_that_holds_them(ready):
    # Named once, for the folder that holds the change, and not again for the folder above it.
    project = ready.project
    with (project / "lib" / "dep" / "lib" / "shared" / "shared.txt").open("a") as file:
        file.write("an edit\n")

    assert report(project) == [
        "lib/dep/lib/shared: uncommitted changes",
        "7 dependency folders: 1 named above",
    ]


def test_status_changes_nothing_and_fetches_nothing(ready):
    # A report never fetches, and never writes: a remote that has moved on is not consulted, and no file of
    # the clone, git's own included, is written.
    project = ready.project
    commit(ready.seed("shared"), "shared s2")
    known_of_the_remote = git(project / "lib" / "shared", "rev-parse", "origin/main")
    before = every_file(project)

    found = report(project)

    assert found == ["7 dependency folders: nothing to report"]
    assert git(project / "lib" / "shared", "rev-parse", "origin/main") == known_of_the_remote
    assert every_file(project) == before
