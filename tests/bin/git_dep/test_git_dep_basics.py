"""`git dep`: how git finds the script, and what holds for every one of its commands."""

from __future__ import annotations

import pytest
from git_dep_world import (
    BY_PATH,
    COOKBOOK,
    EARLIER_COOKBOOK,
    FOLDERS,
    WRITING_THE_SETTINGS,
    git,
    own_setting,
    setting,
    typed,
)


def state(project) -> tuple[str, str]:
    """Where every folder is, and what git reports as changed: enough to see that a command changed nothing."""
    return git(project, "submodule", "status", "--recursive"), git(project, "status", "--porcelain")


def test_the_script_runs_by_its_path_before_any_alias_exists(world):
    # A clone does not copy git's config, so a new clone has no alias and git does not know `dep`. The script
    # runs by its path, from the top folder and from a subfolder.
    project = world.project

    unknown = typed(project, "git dep help")
    from_the_top = typed(project, f"{BY_PATH} help")
    from_a_subfolder = typed(project / "src", f"../{BY_PATH} help")

    assert unknown.returncode != 0 and "'dep' is not a git command" in unknown.stderr, unknown.stderr
    assert from_the_top.returncode == 0, from_the_top.stderr
    assert from_the_top.stdout.startswith("git dep <command>"), from_the_top.stdout
    assert from_a_subfolder.stdout == from_the_top.stdout


def test_setup_writes_the_alias_and_git_then_runs_git_dep(ready):
    # After the first run by path, git runs the script as `git dep`, from the top folder and from a subfolder.
    project = ready.project

    by_path = typed(project, f"{BY_PATH} help")
    from_the_top = typed(project, "git dep help")
    from_a_subfolder = typed(project / "src", "git dep help")

    assert from_the_top.returncode == 0, from_the_top.stderr
    assert from_a_subfolder.returncode == 0, from_a_subfolder.stderr
    assert from_the_top.stdout == from_a_subfolder.stdout == by_path.stdout


def test_each_folder_gets_the_alias_for_the_copy_it_holds(ready):
    # git runs a shell alias in the top folder of the repository it is typed in, so the alias names the script
    # from there: in a repository that uses bao-base, in bao-base itself, and nowhere else. bao-base is a
    # dependency folder here, and its own clone further down.
    project = ready.project
    alone = ready.root / "base-alone"
    git(ready.root, "clone", "-q", str(ready.remote("base")), str(alone))

    first_run_alone = typed(alone, "bin/git-dep setup")

    assert {folder: own_setting(project / folder, "alias.dep") for folder in (".", *FOLDERS)} == {
        ".": "!lib/bao-base/bin/git-dep",
        "lib/bao-base": "!bin/git-dep",
        "lib/dep": "!lib/bao-base/bin/git-dep",
        "lib/dep/lib/bao-base": "!bin/git-dep",
        "lib/dep/lib/shared": None,
        "lib/shared": None,
        "lib/tool": None,
        "lib/tool/lib/deep": None,
    }
    assert first_run_alone.returncode == 0, first_run_alone.stderr
    assert own_setting(alone, "alias.dep") == "!bin/git-dep"
    assert typed(alone, "git dep help").returncode == 0


def test_typed_inside_a_dependency_it_runs_that_dependencys_copy_and_acts_on_it(ready):
    # Inside lib/dep, the alias names lib/dep's own copy of the script, and the command acts on lib/dep. git
    # gives an alias typed there the dependency's GIT_DIR. The folder beneath is still read as itself.
    dependency = ready.project / "lib" / "dep"
    git(dependency / "lib" / "shared", "switch", "-q", "-c", "side")

    cookbook = typed(dependency, "git dep cookbook")
    status = typed(dependency, "git dep status")

    # dep records an earlier bao-base, whose cookbook is the earlier one: its own copy ran.
    assert cookbook.stdout == EARLIER_COOKBOOK
    assert status.returncode == 0, status.stderr
    assert status.stdout.splitlines() == ["lib/shared: on branch side", "2 dependency folders: 1 named above"]


def test_help_lists_every_command_with_what_it_does(ready):
    # `help`, no command and `-h` print the same list: one line a command, saying what it does. It needs no
    # repository.
    project = ready.project

    by_help = typed(project, "git dep help")
    with_no_command = typed(project, "git dep")
    by_h = typed(project, "git dep -h")
    outside = typed(ready.root, f"{project / BY_PATH} help")

    lines = [line.split() for line in by_help.stdout.splitlines() if line.startswith("  ")]
    assert [line[0] for line in lines] == ["setup", "update", "status", "cookbook", "help"]
    assert all(len(line) > 3 for line in lines), "each line says what the command does"
    assert with_no_command.stdout == by_h.stdout == outside.stdout == by_help.stdout
    assert [by_help.returncode, with_no_command.returncode, by_h.returncode, outside.returncode] == [0, 0, 0, 0]


def test_cookbook_prints_the_cookbook_beside_the_script_that_ran(ready):
    # The cookbook printed is the one of the same bao-base as the script, so the text matches the commands:
    # the project's in the project, the dependency's inside the dependency. It needs no repository.
    project = ready.project

    in_the_project = typed(project, "git dep cookbook")
    in_the_dependency = typed(project / "lib" / "dep", "git dep cookbook")
    outside = typed(ready.root, f"{project / BY_PATH} cookbook")

    assert in_the_project.stdout == COOKBOOK.read_text()
    assert in_the_dependency.stdout == EARLIER_COOKBOOK
    assert outside.stdout == COOKBOOK.read_text()
    assert [in_the_project.returncode, in_the_dependency.returncode, outside.returncode] == [0, 0, 0]


def test_an_unknown_command_is_refused_and_the_known_ones_are_named(ready):
    # A command or an argument it does not know ends with status 2, and nothing is changed.
    project = ready.project
    before = state(project)

    no_such_command = typed(project, "git dep frobnicate")
    no_such_argument = typed(project, "git dep status now")

    assert no_such_command.returncode == 2
    assert no_such_command.stderr.strip() == (
        "git dep: frobnicate is not one of its commands. They are: setup, update, status, cookbook, help"
    )
    assert no_such_argument.returncode == 2
    assert no_such_argument.stderr.strip() == "git dep status takes no argument: now"
    assert no_such_command.stdout == no_such_argument.stdout == ""
    assert state(project) == before


def test_outside_a_git_repository_a_command_that_needs_one_stops_with_gits_message(ready):
    # Typed by path where there is no repository: git's own error is what is shown, with git's status.
    outside = typed(ready.root, f"{ready.project / BY_PATH} status")

    assert outside.returncode == 128
    assert "not a git repository" in outside.stderr, outside.stderr
    assert outside.stdout == ""


def test_a_command_typed_in_a_subfolder_acts_on_the_whole_repository(ready):
    # Through the alias git starts the script in the top folder. By path the script finds the top folder itself.
    project = ready.project
    git(project / "lib" / "shared", "switch", "-q", "-c", "side")

    from_the_top = typed(project, "git dep status")
    through_the_alias = typed(project / "src", "git dep status")
    by_path = typed(project / "src", f"../{BY_PATH} status")

    assert from_the_top.stdout.splitlines() == ["lib/shared: on branch side", "7 dependency folders: 1 named above"]
    assert through_the_alias.stdout == by_path.stdout == from_the_top.stdout


@pytest.mark.parametrize("command", ["setup", "update"])
@pytest.mark.parametrize("value", ["true", "false"])
@pytest.mark.parametrize("where", ["the repository's config", "the person's own config"])
def test_a_command_that_changes_something_stops_when_submodule_recurse_is_set(
    world, own_git_config, command, value, where
):
    # With `true`, a branch switch discards an unstaged edit beneath lib/. With `false`, git can stop making the
    # push check. So a command that changes something stops first, naming the file that sets it and the command
    # that takes it out. Typed as printed, that command lets the next run through.
    project = world.project
    file = ".git/config" if where == "the repository's config" else str(own_git_config)
    git(project, "config", "--file", file, "submodule.recurse", value)
    git(project / "lib" / "tool", "checkout", "-q", "v2")

    stopped = typed(project, f"{BY_PATH} {command}")

    taking_it_out = f"git config --file {file} --unset submodule.recurse"
    assert stopped.returncode == 1
    assert stopped.stderr.strip() == (
        f"submodule.recurse is set to {value} in {file}. To take it out: {taking_it_out}"
    ), stopped.stderr
    assert setting(project, "push.recurseSubmodules") is None, "no setting was written"
    assert git(project / "lib" / "tool", "log", "-1", "--format=%s") == "tool t2", "no folder was moved"
    assert typed(project, taking_it_out).returncode == 0
    assert typed(project, f"{BY_PATH} {command}").returncode == 0


@pytest.mark.parametrize("command", ["update"])
def test_a_command_that_can_check_a_folder_out_ends_by_writing_the_settings(world, command):
    # A folder that is checked out for the first time holds none of the settings, so every command that can
    # check one out writes them last, in the repository and in every dependency folder.
    done = typed(world.project, f"{BY_PATH} {command}")

    printed = [line for line in done.stdout.splitlines() if line.startswith("$ ")]
    assert done.returncode == 0, done.stderr
    assert printed[-len(WRITING_THE_SETTINGS) :] == WRITING_THE_SETTINGS
