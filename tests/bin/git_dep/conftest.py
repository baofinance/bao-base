"""The fixtures of the `git dep` tests: git kept apart from the person's own config, and a scratch world."""

from __future__ import annotations

from pathlib import Path

import pytest
from git_dep_world import BY_PATH, World, build_world, typed


@pytest.fixture(autouse=True)
def own_git_config(tmp_path, monkeypatch) -> Path:
    """git reads none of the person's own config in a test: the global config is a file of the test's own. It holds
    an identity, the leave to clone from a path on disk, and `main` as the first branch. Returns the file, which
    stands for the person's own config where a test needs to write one."""
    config = tmp_path / "global.gitconfig"
    config.write_text(
        "[user]\n\tname = test\n\temail = test@example.invalid\n"
        '[protocol "file"]\n\tallow = always\n'
        "[init]\n\tdefaultBranch = main\n"
        "[advice]\n\tdetachedHead = false\n"
    )
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", str(config))
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")
    for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_PREFIX", "GIT_INDEX_FILE"):
        monkeypatch.delenv(name, raising=False)
    return config


@pytest.fixture
def world(tmp_path) -> World:
    """A new clone of the project, with everything checked out and nothing else done to it."""
    return build_world(tmp_path)


@pytest.fixture
def ready(world) -> World:
    """The clone after its first `setup`, run by path: `git dep` works in it from then on."""
    first = typed(world.project, f"{BY_PATH} setup")
    assert first.returncode == 0, first.stdout + first.stderr
    return world
