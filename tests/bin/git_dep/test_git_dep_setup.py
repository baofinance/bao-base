"""`git dep setup`: the settings and the alias written, in the repository and in every dependency folder.

It is what lets git run `git dep`, and it moves no folder: it is safe at any time."""

from __future__ import annotations

import json

from git_dep_world import (
    BAO_BASE,
    BY_PATH,
    FOLDERS,
    THE_THREE,
    WRITING_THE_SETTINGS,
    git,
    own_setting,
    printed,
    setting,
    subject,
    typed,
)


def test_the_setup_script_runs_git_dep_setup_in_the_clone_it_is_typed_in(world):
    # `bin/setup` is what `yarn setup` runs: what a clone needs once before it is worked in. It runs
    # `git dep setup` by the script's path, for the repository it is typed in: a repository that uses
    # bao-base, and bao-base itself. Each gets the alias for the copy of the script it holds.
    project = world.project
    alone = world.root / "base-alone"
    git(world.root, "clone", "-q", str(world.remote("base")), str(alone))

    in_the_project = typed(project, str(BAO_BASE / "bin" / "setup"))
    in_bao_base = typed(alone, str(BAO_BASE / "bin" / "setup"))

    assert in_the_project.returncode == 0, in_the_project.stderr
    assert printed(in_the_project) == WRITING_THE_SETTINGS
    assert own_setting(project, "alias.dep") == "!lib/bao-base/bin/git-dep"
    assert typed(project, "git dep help").returncode == 0
    assert in_bao_base.returncode == 0, in_bao_base.stderr
    assert own_setting(alone, "alias.dep") == "!bin/git-dep"


def test_yarn_setup_reaches_the_setup_script_through_run(world):
    # bao-base's package.json gives `yarn setup` the line `./run setup`: every yarn script goes through `run`.
    # Typed in a clone, `run setup` writes the settings and the alias there.
    project = world.project
    scripts = json.loads((BAO_BASE / "package.json").read_text())["scripts"]

    done = typed(project, f"{BAO_BASE / 'run'} setup")

    assert scripts.get("setup") == "./run setup"
    assert done.returncode == 0, done.stdout + done.stderr
    assert own_setting(project, "alias.dep") == "!lib/bao-base/bin/git-dep"
    assert {key: own_setting(project, key) for key in THE_THREE} == THE_THREE


def test_setup_moves_no_folder(world):
    # A folder moved on purpose and not staged, and a folder that is not checked out: each is as it was after
    # the run. The only commands it runs are the ones that write the settings and the alias.
    project = world.project
    git(project / "lib" / "tool", "checkout", "-q", "v2")
    git(project, "submodule", "deinit", "-q", "--force", "--", "lib/shared")

    done = typed(project, f"{BY_PATH} setup")

    assert done.returncode == 0, done.stderr
    assert printed(done) == WRITING_THE_SETTINGS
    assert subject(project / "lib" / "tool") == "tool t2"
    assert not (project / "lib" / "shared" / ".git").exists()


def test_setup_writes_the_three_settings_in_the_repository_and_in_every_folder(ready):
    # The values git uses, in the repository and in each folder at every depth.
    project = ready.project

    assert {folder: {key: setting(project / folder, key) for key in THE_THREE} for folder in (".", *FOLDERS)} == {
        folder: THE_THREE for folder in (".", *FOLDERS)
    }


def test_setup_gives_the_settings_to_a_folder_that_arrived_since_the_last_run(ready):
    # A dependency added with plain git holds none of the settings, and neither do the folders beneath it. The
    # next run writes them there, with the alias where a folder holds the script, and changes no other folder.
    project = ready.project
    arrived = ("lib/second", "lib/second/lib/bao-base", "lib/second/lib/shared")
    git(project, "submodule", "--quiet", "add", str(ready.remote("dep")), "lib/second")
    git(project / "lib" / "second", "submodule", "--quiet", "update", "--init", "--recursive")
    own = [*THE_THREE, "alias.dep"]
    before = {folder: {key: own_setting(project / folder, key) for key in own} for folder in (*FOLDERS, *arrived)}

    done = typed(project, "git dep setup")

    after = {folder: {key: own_setting(project / folder, key) for key in own} for folder in (*FOLDERS, *arrived)}
    assert done.returncode == 0, done.stderr
    assert all(before[folder] == dict.fromkeys(own) for folder in arrived), before
    assert after["lib/second"] == {**THE_THREE, "alias.dep": "!lib/bao-base/bin/git-dep"}
    assert after["lib/second/lib/bao-base"] == {**THE_THREE, "alias.dep": "!bin/git-dep"}
    assert after["lib/second/lib/shared"] == {**THE_THREE, "alias.dep": None}
    assert {folder: after[folder] for folder in FOLDERS} == {folder: before[folder] for folder in FOLDERS}


def test_setup_sets_no_submodule_recurse(ready):
    # Not `true`, and not `false` either: with either, git's behavior changes in a way the cookbook rules out.
    project = ready.project

    assert [setting(project / folder, "submodule.recurse") for folder in (".", *FOLDERS)] == [None] * 8


def test_setup_in_a_repository_with_no_dependency_succeeds(world):
    # bao-base cloned on its own: its settings and its alias are written, and there is no folder to write to.
    alone = world.root / "base-alone"
    git(world.root, "clone", "-q", str(world.remote("base")), str(alone))

    done = typed(alone, "bin/git-dep setup")

    assert done.returncode == 0, done.stderr
    assert {key: own_setting(alone, key) for key in THE_THREE} == THE_THREE
    assert own_setting(alone, "alias.dep") == "!bin/git-dep"
