"""`git dep`: how git finds the script, and what holds for every one of its commands."""

from __future__ import annotations

import shutil

import pytest
from git_dep_world import (
    BY_PATH,
    COOKBOOK,
    EARLIER_COOKBOOK,
    FOLDERS,
    SCRIPT,
    WRITING_THE_SETTINGS,
    git,
    own_setting,
    printed,
    setting,
    state,
    typed,
)

# The Pythons before 3.13 that this computer has. The script runs on the `python3` of whoever types it, from
# 3.9 on, and the tests run it on one Python only.
OLDER_PYTHONS = [python for python in ("python3.9", "python3.10", "python3.11", "python3.12") if shutil.which(python)]


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
    # `help`, no command and `-h` print the same list: for each command, the way it is typed, then a line saying
    # what it does. It needs no repository.
    project = ready.project

    by_help = typed(project, "git dep help")
    with_no_command = typed(project, "git dep")
    by_h = typed(project, "git dep -h")
    outside = typed(ready.root, f"{project / BY_PATH} help")

    listed = by_help.stdout.split("\n\n", 1)[1].splitlines()
    assert listed[0::2] == [
        "  setup",
        "  update",
        "  status",
        "  add <url> [<name>] [--branch <branch> | --tag <tag>]",
        "  upgrade <name> [<version>]",
        "  remove <name>",
        "  cookbook",
        "  help",
    ]
    assert all(line.startswith("      ") and len(line.split()) > 2 for line in listed[1::2]), "what each does"
    assert with_no_command.stdout == by_h.stdout == outside.stdout == by_help.stdout
    assert [by_help.returncode, with_no_command.returncode, by_h.returncode, outside.returncode] == [0, 0, 0, 0]


def test_a_command_typed_with_h_says_how_it_is_typed_and_what_it_takes(tmp_path):
    # `-h` after a command: the way the command is typed, what it does, and a line for each thing it takes. It
    # needs no repository.
    answered = typed(tmp_path, f"{SCRIPT} add -h")

    lines = [line.strip() for line in answered.stdout.splitlines()]
    assert answered.returncode == 0, answered.stderr
    assert lines[0] == "usage: git dep add <url> [<name>] [--branch <branch> | --tag <tag>]"
    for taken in ("<url>", "<name>", "--branch <branch>", "--tag <tag>"):
        said = [line[len(taken) :].split() for line in lines if line.startswith(f"{taken}  ")]
        assert len(said) == 1 and len(said[0]) > 2, f"one line says what {taken} is: {answered.stdout}"


@pytest.mark.parametrize(
    ("typed_after_git_dep", "form", "said"),
    [
        ("status now", "status", "unrecognized arguments: now"),
        ("setup now", "setup", "unrecognized arguments: now"),
        ("update tool", "update", "unrecognized arguments: tool"),
        ("add", "add <url> [<name>] [--branch <branch> | --tag <tag>]", "the following arguments are required: <url>"),
        (
            "add url --branch main --tag v1",
            "add <url> [<name>] [--branch <branch> | --tag <tag>]",
            "argument --tag: not allowed with argument --branch",
        ),
        (
            "add url name more",
            "add <url> [<name>] [--branch <branch> | --tag <tag>]",
            "unrecognized arguments: more",
        ),
        ("upgrade", "upgrade <name> [<version>]", "the following arguments are required: <name>"),
        ("upgrade tool v1 v2", "upgrade <name> [<version>]", "unrecognized arguments: v2"),
        ("remove", "remove <name>", "the following arguments are required: <name>"),
        ("remove tool deep", "remove <name>", "unrecognized arguments: deep"),
    ],
)
def test_a_command_typed_with_arguments_it_does_not_take_is_refused_with_how_it_is_typed(
    tmp_path, typed_after_git_dep, form, said
):
    # Too many arguments, too few, or two that exclude each other: the answer is the way the command is typed,
    # and status 2. It is checked before anything else, so it holds outside a repository too. `update` takes no
    # name: it is refused like any other, and the answer does not send the person to `upgrade`.
    command = typed_after_git_dep.split()[0]

    refused = typed(tmp_path, f"{SCRIPT} {typed_after_git_dep}")

    assert refused.returncode == 2
    assert refused.stderr.splitlines() == [f"usage: git dep {form}", f"git dep {command}: error: {said}"]
    assert refused.stdout == ""


@pytest.mark.parametrize("python", ["python3", *OLDER_PYTHONS])
@pytest.mark.parametrize(
    "typed_after_git_dep", ["add --tag v1 url name", "add url --tag v1 name", "add url name --tag v1"]
)
def test_an_option_is_taken_wherever_it_is_typed(tmp_path, python, typed_after_git_dep):
    # Before, between and after the other arguments. Outside a repository, a command whose arguments are
    # accepted goes on to look for the repository, and ends with git's message for there being none. A Python
    # before 3.13 refuses an option between the other arguments unless the script reads them in any order, so
    # this runs on each older Python that is installed, as well as on the one the tests run the script on.
    accepted = typed(tmp_path, f"{python} {SCRIPT} {typed_after_git_dep}")

    assert accepted.returncode == 128, accepted.stderr
    assert "not a git repository" in accepted.stderr, accepted.stderr


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
        "git dep: frobnicate is not one of its commands. "
        "They are: setup, update, status, add, upgrade, remove, cookbook, help"
    )
    assert no_such_argument.returncode == 2
    assert no_such_argument.stderr.splitlines()[-1] == "git dep status: error: unrecognized arguments: now"
    assert no_such_command.stdout == no_such_argument.stdout == ""
    assert state(project) == before


def test_a_dependency_is_named_with_or_without_lib_in_front(ready):
    # `tool`, `lib/tool` and `lib/tool/` name the same dependency: each run types its git commands for
    # lib/tool.
    project = ready.project

    for name in ("tool", "lib/tool", "lib/tool/"):
        done = typed(project, f"git dep upgrade {name} v1")

        assert done.returncode == 0, done.stderr
        assert printed(done)[:2] == ["$ git -C lib/tool fetch --tags", "$ git -C lib/tool checkout --detach v1"], name


def test_a_name_that_is_not_a_dependency_is_refused_and_the_dependencies_are_named(ready):
    # A name no dependency has, and a dependency's own dependency: neither is a dependency of the repository
    # the command is typed in. The run ends with status 2, and nothing is changed.
    project = ready.project
    before = state(project)

    for command in ("upgrade nosuch v2", "remove nosuch", "remove lib/dep/lib/shared"):
        refused = typed(project, f"git dep {command}")

        assert refused.returncode == 2, command
        assert refused.stderr.strip() == (
            f"git dep: {command.split()[1]} is not a dependency of this repository. "
            "They are: lib/bao-base, lib/dep, lib/shared, lib/tool"
        )
        assert refused.stdout == ""
    assert state(project) == before


def test_a_name_git_refuses_is_no_dependency(ready):
    # git ignores an entry of .gitmodules whose name has `..` in it. The repository git would keep under such a
    # name is outside the folder it keeps dependencies in. So the entry is no dependency here either, and a
    # removal deletes nothing outside.
    project = ready.project
    outside = ready.root / "outside"
    outside.mkdir()
    (outside / "kept.txt").write_text("kept\n")
    with (project / ".gitmodules").open("a") as file:
        file.write(f'[submodule "../../../outside"]\n\tpath = lib/evil\n\turl = {ready.remote("deep")}\n')
    commit_of_deep = git(project / "lib" / "tool" / "lib" / "deep", "rev-parse", "HEAD")
    git(project, "update-index", "--add", "--cacheinfo", f"160000,{commit_of_deep},lib/evil")
    git(project, "add", ".gitmodules")
    git(project, "commit", "-qm", "an entry whose name leads outside")

    refused = typed(project, "git dep remove evil")

    assert refused.returncode == 2
    assert refused.stderr.strip() == (
        "git dep: evil is not a dependency of this repository. They are: lib/bao-base, lib/dep, lib/shared, lib/tool"
    )
    assert (outside / "kept.txt").read_text() == "kept\n"


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


@pytest.mark.parametrize("value", ["true", "false"])
@pytest.mark.parametrize("where", ["the repository's config", "the person's own config"])
def test_a_command_stops_when_submodule_recurse_is_set_whatever_its_value_and_wherever(
    world, own_git_config, value, where
):
    # With `true`, a branch switch discards an unstaged edit beneath lib/. With `false`, git can stop making the
    # push check. So the command stops first, naming the file that sets it and the command that takes it out.
    # Typed as printed, that command lets the next run through.
    project = world.project
    file = ".git/config" if where == "the repository's config" else str(own_git_config)
    git(project, "config", "--file", file, "submodule.recurse", value)
    git(project / "lib" / "tool", "checkout", "-q", "v2")

    stopped = typed(project, f"{BY_PATH} update")

    taking_it_out = f"git config --file {file} --unset submodule.recurse"
    assert stopped.returncode == 1
    assert stopped.stderr.strip() == (
        f"submodule.recurse is set to {value} in {file}. To take it out: {taking_it_out}"
    ), stopped.stderr
    assert setting(project, "push.recurseSubmodules") is None, "no setting was written"
    assert git(project / "lib" / "tool", "log", "-1", "--format=%s") == "tool t2", "no folder was moved"
    assert typed(project, taking_it_out).returncode == 0
    assert typed(project, f"{BY_PATH} update").returncode == 0


@pytest.mark.parametrize("command", ["setup", "update", "add {kit}", "upgrade tool v2", "remove shared"])
def test_each_command_that_changes_something_first_checks_that_submodule_recurse_is_not_set(world, command):
    # The check comes before the command's first change: no git command is run, and nothing is changed.
    project = world.project
    git(project, "config", "submodule.recurse", "true")
    before = state(project)

    stopped = typed(project, f"{BY_PATH} {command.format(kit=world.remote('kit'))}")

    assert stopped.returncode == 1
    assert stopped.stderr.strip() == (
        "submodule.recurse is set to true in .git/config. "
        "To take it out: git config --file .git/config --unset submodule.recurse"
    ), stopped.stderr
    assert printed(stopped) == []
    assert state(project) == before
    assert setting(project, "push.recurseSubmodules") is None, "no setting was written"


@pytest.mark.parametrize("command", ["update", "add {kit}", "upgrade tool v2"])
def test_a_command_that_can_check_a_folder_out_ends_by_writing_the_settings(world, command):
    # A folder that is checked out for the first time holds none of the settings, so every command that can
    # check one out writes them last, in the repository and in every dependency folder.
    done = typed(world.project, f"{BY_PATH} {command.format(kit=world.remote('kit'))}")

    assert done.returncode == 0, done.stderr
    assert printed(done)[-len(WRITING_THE_SETTINGS) :] == WRITING_THE_SETTINGS
