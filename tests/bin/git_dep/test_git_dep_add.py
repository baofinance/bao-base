"""`git dep add`: a new dependency, checked out at every depth and staged, with the settings written.

It is the cookbook's "Add a dependency". It leaves the remappings and the commit to the person."""

from __future__ import annotations

import pytest
from git_dep_world import (
    THE_THREE,
    WRITING_THE_SETTINGS,
    branch,
    git,
    head,
    own_setting,
    printed,
    recorded,
    state,
    subject,
    typed,
)


def test_add_checks_out_the_dependency_at_every_depth_and_stages_it(ready):
    # The folder is named from the url. It and the folders beneath it are checked out, the dependency is staged,
    # and no commit is made. The commands are the cookbook's, in its order.
    project = ready.project
    kit = ready.remote("kit")
    before = head(project)

    done = typed(project, f"git dep add {kit}")

    assert done.returncode == 0, done.stderr
    assert [subject(project / folder) for folder in ("lib/kit", "lib/kit/lib/bao-base", "lib/kit/lib/deep")] == [
        "kit k2",
        "base b2",
        "deep d2",
    ]
    assert git(project, "status", "--porcelain").splitlines() == ["M  .gitmodules", "A  lib/kit"]
    assert recorded(project, "lib/kit") == head(project / "lib" / "kit")
    assert head(project) == before
    assert printed(done)[: -len(WRITING_THE_SETTINGS)] == [
        f"$ git submodule add {kit} lib/kit",
        "$ git -C lib/kit switch --detach",
        "$ git -C lib/kit submodule update --init --recursive",
        "$ git add lib/kit",
    ]


def test_add_names_the_folder_from_the_url(ready):
    # The name is the last part of the url, without `.git`: for a url with slashes, for the `host:path` form,
    # and with a slash at the end. Each of these urls gives `tool`, which is a dependency already: git refuses
    # the folder before it looks at the url, so the command it was given shows the name.
    project = ready.project

    for url in (
        "https://example.invalid/owner/tool.git",
        "https://example.invalid/owner/tool",
        "https://example.invalid/owner/tool.git/",
        "git@example.invalid:owner/tool.git",
        "git@example.invalid:tool.git",
    ):
        refused = typed(project, f"git dep add {url}")

        assert printed(refused) == [f"$ git submodule add {url} lib/tool"], url
        assert refused.returncode == 128, url

    # A url with nothing to take a name from is refused before git is run.
    no_name = typed(project, "git dep add /")
    assert (no_name.returncode, printed(no_name)) == (2, [])
    assert no_name.stderr.strip() == "git dep add: / gives no name for the folder. Give one: git dep add <url> <name>"


def test_add_takes_a_name_for_the_folder(ready):
    # The folder is lib/<name>, whether the name is typed with `lib/` in front or not. One repository can be
    # added under several names.
    project = ready.project
    kit = ready.remote("kit")

    for name, folder in (("other", "lib/other"), ("lib/second", "lib/second"), ("lib/third/", "lib/third")):
        done = typed(project, f"git dep add {kit} {name}")

        assert done.returncode == 0, done.stderr
        assert subject(project / folder) == "kit k2"
        assert git(project, "config", "--file", ".gitmodules", "--get", f"submodule.{folder}.path") == folder
    assert not (project / "lib" / "kit").exists()


def test_add_with_a_branch_records_the_branch_it_follows(ready):
    # `--branch` is for a repository of your own. .gitmodules gains its `branch` line, which `upgrade` typed
    # with no version follows.
    project = ready.project
    kit = ready.remote("kit")

    done = typed(project, f"git dep add {kit} --branch main")

    assert done.returncode == 0, done.stderr
    assert git(project, "config", "--file", ".gitmodules", "--get", "submodule.lib/kit.branch") == "main"
    assert subject(project / "lib" / "kit") == "kit k2"
    assert printed(done)[0] == f"$ git submodule add -b main {kit} lib/kit"


def test_add_with_a_tag_stages_the_tagged_commit(ready):
    # `--tag` is for a library at a release. The folder is put at the tag before the folders beneath it are
    # checked out, so they are at the commits the tagged version records. The tagged commit is what is staged,
    # and .gitmodules gains no `branch` line.
    project = ready.project
    kit = ready.remote("kit")

    done = typed(project, f"git dep add {kit} --tag v1")

    tagged = git(ready.seed("kit"), "rev-parse", "v1")
    assert done.returncode == 0, done.stderr
    assert (head(project / "lib" / "kit"), recorded(project, "lib/kit")) == (tagged, tagged)
    assert subject(project / "lib" / "kit" / "lib" / "deep") == "deep d1"
    assert typed(project, "git config --file .gitmodules --get submodule.lib/kit.branch").returncode == 1
    assert printed(done)[:3] == [
        f"$ git submodule add {kit} lib/kit",
        "$ git -C lib/kit checkout v1",
        "$ git -C lib/kit submodule update --init --recursive",
    ]


@pytest.mark.parametrize("option", ["", " --branch main"])
def test_add_leaves_the_new_folder_on_no_branch(ready, option):
    # git's own add leaves the new folder on a branch, where every folder from a clone is on none. A folder on
    # a branch is one somebody works in, and `update` leaves it where it is. So the new folder is taken off its
    # branch, at the same commit.
    project = ready.project

    done = typed(project, f"git dep add {ready.remote('kit')}{option}")

    assert done.returncode == 0, done.stderr
    assert branch(project / "lib" / "kit") is None
    assert subject(project / "lib" / "kit") == "kit k2"
    assert "lib/kit" not in typed(project, "git dep status").stdout


def test_add_gives_the_new_folders_the_settings_and_the_alias(ready):
    # A folder that is checked out for the first time holds none of the settings. The new folder and the ones
    # beneath it get the three, and the alias where a folder holds the script.
    project = ready.project
    new = ("lib/kit", "lib/kit/lib/bao-base", "lib/kit/lib/deep")

    done = typed(project, f"git dep add {ready.remote('kit')}")

    assert done.returncode == 0, done.stderr
    assert {folder: {key: own_setting(project / folder, key) for key in THE_THREE} for folder in new} == {
        folder: THE_THREE for folder in new
    }
    assert {folder: own_setting(project / folder, "alias.dep") for folder in new} == {
        "lib/kit": "!lib/bao-base/bin/git-dep",
        "lib/kit/lib/bao-base": "!bin/git-dep",
        "lib/kit/lib/deep": None,
    }


def test_add_says_what_is_left_to_do(ready):
    # It makes no commit, and it does not know the dependency's remappings. Its last line says both are left.
    project = ready.project

    done = typed(project, f"git dep add {ready.remote('kit')}")

    assert done.stdout.splitlines()[-1] == (
        f"lib/kit is added at {head(project / 'lib' / 'kit')[:10]}, and staged. "
        'Left to do: add its remappings, then commit. See "Add a dependency" in the cookbook: git dep cookbook'
    )


def test_add_stops_with_gits_error_when_the_folder_exists(ready):
    # git refuses, and its own message and status are what the run ends with. Nothing is changed.
    project = ready.project
    before = state(project)

    stopped = typed(project, f"git dep add {ready.remote('tool')}")

    assert stopped.returncode == 128
    assert "'lib/tool' already exists in the index" in stopped.stderr, stopped.stderr
    assert state(project) == before


@pytest.mark.parametrize(("option", "what"), [("--branch nosuch", "branch nosuch"), ("--tag v9", "tag v9")])
def test_add_stops_before_changing_anything_for_a_branch_or_a_tag_the_remote_does_not_have(ready, option, what):
    # git's own add finds a missing branch only after it has cloned: it leaves the cloned folder and the
    # repository it keeps for it behind, and typed again it stages a folder with no file in it. A missing tag
    # is found after the dependency is staged. So the remote is asked first, and nothing is cloned or kept.
    project = ready.project
    kit = ready.remote("kit")
    before = state(project)

    stopped = typed(project, f"git dep add {kit} {option}")

    assert stopped.returncode == 1
    assert stopped.stderr.strip() == f"{kit} has no {what}"
    assert printed(stopped) == []
    assert state(project) == before
    assert not (project / "lib" / "kit").exists()
    assert not ready.kept("lib/kit").exists()


def test_add_takes_a_url_relative_to_this_repositorys_own_remote(ready):
    # git reads a url that starts with `../` from the repository's own remote, not from the folder the command
    # is typed in. The remote is not asked about the branch first for such a url, and git adds it.
    project = ready.project

    done = typed(project, "git dep add ../kit.git --branch main")

    assert done.returncode == 0, done.stderr
    assert subject(project / "lib" / "kit") == "kit k2"
    assert git(project, "config", "--file", ".gitmodules", "--get", "submodule.lib/kit.url") == "../kit.git"
