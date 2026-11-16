"""`yarn setup`: what a clone needs once, before it is worked in.

`yarn setup` goes through `run` to `bin/setup`. That script runs `git dep setup` by the script's path. Then,
where the repository has a Python environment of its own, it runs `uv sync --locked` in the top folder.

uv is stood in for in all but the last test: a real one would download what the environment needs."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import NamedTuple

import pytest
from git_dep_world import BAO_BASE, THE_THREE, WRITING_THE_SETTINGS, git, own_setting, printed, typed

SETUP = BAO_BASE / "bin" / "setup"
# A repository's own Python environment, as uv reads it: the smallest one, which needs nothing downloaded.
PYPROJECT = (
    '[project]\nname = "scratch"\nversion = "0.1.0"\nrequires-python = ">=3.12"\ndependencies = []\n\n'
    "[tool.uv]\npackage = false\n"
)
STAND_IN = """#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path

here = Path(__file__).parent
alias = subprocess.run(["git", "config", "--get", "alias.dep"], capture_output=True, text=True).stdout.strip()
ran = {"arguments": sys.argv[1:], "folder": os.getcwd(), "VIRTUAL_ENV": os.environ.get("VIRTUAL_ENV"), "alias": alias}
(here / "ran.json").write_text(json.dumps(ran))
sys.exit(int((here / "status").read_text()))
"""


class StandIn(NamedTuple):
    """A stand-in for uv. It writes down how it was run, and ends with the status it was told to."""

    folder: Path

    def will_end_with(self, status: int) -> None:
        (self.folder / "status").write_text(str(status))

    def ran(self) -> dict | None:
        """How it was run: its arguments, the folder it was run in, the `VIRTUAL_ENV` it was given, and the
        alias git had for `dep` at that moment. None when it was not run."""
        written = self.folder / "ran.json"
        return json.loads(written.read_text()) if written.exists() else None


@pytest.fixture
def uv(tmp_path, monkeypatch) -> StandIn:
    """A stand-in for uv, found as `run` hands the real one over: by its path in `UV`. `VIRTUAL_ENV` names the
    environment of another project, as it does where `run` starts a script."""
    folder = tmp_path / "stand-in"
    folder.mkdir()
    (folder / "uv").write_text(STAND_IN)
    (folder / "uv").chmod(0o755)
    stand_in = StandIn(folder)
    stand_in.will_end_with(0)
    monkeypatch.setenv("UV", str(folder / "uv"))
    monkeypatch.setenv("VIRTUAL_ENV", str(tmp_path / "the-environment-of-another-project"))
    return stand_in


def test_the_setup_script_runs_git_dep_setup_in_the_clone_it_is_typed_in(world):
    # `bin/setup` is what `yarn setup` runs: what a clone needs once before it is worked in. It runs
    # `git dep setup` by the script's path, for the repository it is typed in: a repository that uses
    # bao-base, and bao-base itself. Each gets the alias for the copy of the script it holds.
    project = world.project
    alone = world.root / "base-alone"
    git(world.root, "clone", "-q", str(world.remote("base")), str(alone))

    in_the_project = typed(project, str(SETUP))
    in_bao_base = typed(alone, str(SETUP))

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


def test_setup_brings_the_repositorys_own_environment_up_to_date(world, uv):
    # A pyproject.toml in the top folder means the repository has a Python environment of its own. After the
    # `git dep` step, `uv sync --locked` is run in the top folder, wherever setup is typed, with the uv that
    # `run` hands over. The environment `run` started the script in is another project's, and is not handed on:
    # uv would warn that it is not this project's.
    project = world.project
    (project / "pyproject.toml").write_text(PYPROJECT)

    done = typed(project / "src", str(SETUP))

    assert done.returncode == 0, done.stderr
    assert uv.ran() == {
        "arguments": ["sync", "--locked"],
        "folder": str(project),
        "VIRTUAL_ENV": None,
        "alias": "!lib/bao-base/bin/git-dep",
    }
    assert printed(done) == [*WRITING_THE_SETTINGS, "$ uv sync --locked"]


def test_setup_runs_no_uv_where_the_repository_has_no_environment_of_its_own(world, uv):
    # No pyproject.toml in the top folder: the `git dep` step is all there is to do.
    done = typed(world.project, str(SETUP))

    assert done.returncode == 0, done.stderr
    assert uv.ran() is None
    assert printed(done) == WRITING_THE_SETTINGS


@pytest.mark.parametrize("status", [1, 2])
def test_setup_ends_with_uvs_status_when_uv_fails(world, uv, status):
    # uv ends with 1 where the lock does not match pyproject.toml, and with 2 where there is no lock. Its
    # status is the run's. The `git dep` step is done by then: it does not wait for a download.
    project = world.project
    (project / "pyproject.toml").write_text(PYPROJECT)
    uv.will_end_with(status)

    done = typed(project, str(SETUP))

    assert done.returncode == status
    assert uv.ran() is not None
    assert own_setting(project, "alias.dep") == "!lib/bao-base/bin/git-dep"


def test_setup_runs_no_uv_when_the_git_dep_step_stops(world, uv):
    # `git dep setup` stops where `submodule.recurse` is set. Its status is the run's, and nothing more is done
    # in a clone whose set-up did not go through.
    project = world.project
    (project / "pyproject.toml").write_text(PYPROJECT)
    git(project, "config", "submodule.recurse", "true")

    stopped = typed(project, str(SETUP))

    assert stopped.returncode == 1
    assert f"submodule.recurse is set to true in {world.git_folder}/config" in stopped.stderr, stopped.stderr
    assert uv.ran() is None


def test_setup_says_so_where_no_uv_was_handed_to_it(world, monkeypatch):
    # `run` starts the script through uv, and uv hands its own path over in `UV`. Typed by its path, the script
    # has none. In a repository that has an environment of its own it says so, after the `git dep` step, and
    # names the command that goes through `run`.
    project = world.project
    (project / "pyproject.toml").write_text(PYPROJECT)
    monkeypatch.delenv("UV", raising=False)

    stopped = typed(project, str(SETUP))

    assert stopped.returncode == 1
    assert stopped.stderr.strip() == (
        "setup: UV is not set, so there is no uv to run `uv sync --locked` with. "
        "`yarn setup` starts this script through `run`, which sets it."
    )
    assert own_setting(project, "alias.dep") == "!lib/bao-base/bin/git-dep"


@pytest.mark.skipif("UV" not in os.environ, reason="the tests were not started through `run`, so no uv is handed over")
def test_run_setup_builds_the_environment_from_the_lock_with_the_real_uv(world):
    # The whole chain, with nothing stood in for: `run setup`, typed in a repository that has a pyproject.toml
    # and the lock that matches it, builds the environment in the top folder. The lock is as it was, and uv
    # has no warning about the environment `run` itself works in.
    project = world.project
    (project / "pyproject.toml").write_text(PYPROJECT)
    locked = typed(project, f"{os.environ['UV']} lock --quiet")
    assert locked.returncode == 0, locked.stderr
    lock = (project / "uv.lock").read_text()

    done = typed(project, f"{BAO_BASE / 'run'} setup")

    assert done.returncode == 0, done.stdout + done.stderr
    assert (project / ".venv" / "pyvenv.cfg").exists()
    assert (project / "uv.lock").read_text() == lock
    assert "does not match the project environment" not in done.stdout + done.stderr
