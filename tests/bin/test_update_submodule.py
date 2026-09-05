"""Tests for bin/update-submodule - naming a dependency with a ref, `<dependency>@<ref>`.

A ref re-pins a dependency: `forge update lib/bao-base@main` rewrites foundry.lock's entry for it
from whatever it held (a tag, say) to that ref. `forge update` is the only command that can do this
- neither it nor `forge install` takes a flag for it - so the wrapper has to pass the form through.

That imposes two requirements, which the tests below hold apart:

  - the submodule is located from the PATH part alone, so the ref does not make the lookup fail;
  - forge receives the ref attached to the RESOLVED, lib/-prefixed path. forge does not split a ref
    off a bare name: given `dep@main` it looks for the whole string at `lib/dep@main` and reports
    the dependency missing. Only `lib/dep@main` re-pins.

`--check` stops before forge is invoked, so the resolution tests use it; the tests that pin the
forge invocation put a recording stub on PATH instead of running the real thing.
"""

import os
import subprocess
from pathlib import Path

import pytest

BAO_BASE = Path(__file__).resolve().parents[2]
UPDATE_SUBMODULE = BAO_BASE / "bin" / "update-submodule"

# Cloning a submodule from a path on disk is refused by default (CVE-2022-39253). Allowing it for
# the fixture's git calls only keeps the user's own git config untouched.
GIT_ENV = {
    **os.environ,
    "GIT_CONFIG_COUNT": "1",
    "GIT_CONFIG_KEY_0": "protocol.file.allow",
    "GIT_CONFIG_VALUE_0": "always",
}


def git(*args: str, cwd: Path):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, env=GIT_ENV)


def make_dependency(root: Path, name: str) -> Path:
    """A committed repo plus the bare clone a submodule can be added from."""
    source = root / name
    source.mkdir()
    git("init", "-q", "-b", "main", ".", cwd=source)
    git("config", "user.email", "test@example.com", cwd=source)
    git("config", "user.name", "test", cwd=source)
    (source / "README.md").write_text(f"{name}\n")
    git("add", "-A", cwd=source)
    git("commit", "-qm", "initial", cwd=source)

    bare = root / f"{name}.git"
    git("clone", "-q", "--bare", str(source), str(bare), cwd=root)
    return bare


@pytest.fixture
def project(tmp_path, monkeypatch):
    """A throwaway superproject with two submodules under lib/, both clean and fully pushed.

    Two, not one, so the argument loop is exercised at more than a single iteration - and so a test
    can name one dependency and confirm the other is left out of the report.
    """
    root = tmp_path / "root"
    root.mkdir()
    first = make_dependency(root, "dep")
    second = make_dependency(root, "other")

    project = root / "project"
    project.mkdir()
    git("init", "-q", "-b", "main", ".", cwd=project)
    git("config", "user.email", "test@example.com", cwd=project)
    git("config", "user.name", "test", cwd=project)
    (project / "foundry.toml").write_text('[profile.default]\nlibs = ["lib"]\n')
    git("add", "-A", cwd=project)
    git("commit", "-qm", "initial", cwd=project)
    git("submodule", "add", "-q", str(first), "lib/dep", cwd=project)
    git("submodule", "add", "-q", str(second), "lib/other", cwd=project)
    git("commit", "-qm", "add submodules", cwd=project)

    monkeypatch.chdir(project)
    return project


def update_submodule(*args: str, path_prefix: Path | None = None) -> subprocess.CompletedProcess:
    """Run bin/update-submodule in the current directory.

    Invoked as bash directly rather than through `run`, which would resolve BAO_BASE_DIR against the
    throwaway project. `path_prefix` puts a directory at the front of PATH, which is how the forge
    stub is installed.
    """
    env = dict(GIT_ENV)
    if path_prefix is not None:
        env["PATH"] = f"{path_prefix}{os.pathsep}{env['PATH']}"
    return subprocess.run(
        ["bash", str(UPDATE_SUBMODULE), *args],
        capture_output=True,
        text=True,
        env=env,
    )


@pytest.fixture
def forge_stub(tmp_path):
    """A `forge` on PATH that records its arguments instead of updating anything.

    Returns (directory to prepend to PATH, a reader for the recorded argument list). The real forge
    would reach the network and move the submodule; what these tests need to know is only which
    arguments it was handed.
    """
    bin_dir = tmp_path / "stub-bin"
    bin_dir.mkdir()
    record = tmp_path / "forge-args"
    stub = bin_dir / "forge"
    stub.write_text(f'#!/usr/bin/env bash\nprintf "%s\\n" "$@" > "{record}"\n')
    stub.chmod(0o755)

    def recorded_arguments() -> list[str]:
        return record.read_text().splitlines() if record.exists() else []

    return bin_dir, recorded_arguments


# ── locating the submodule when a ref is attached ─────────────────────────────────────────────────


def test_bare_name_with_a_ref_is_located(project):
    # `yarn update bao-base@main` - the name is not a path, and the ref is not part of it
    result = update_submodule("--check", "dep@main")
    assert result.returncode == 0, result.stderr
    assert "lib/dep" in result.stdout


def test_path_with_a_ref_is_located(project):
    result = update_submodule("--check", "lib/dep@main")
    assert result.returncode == 0, result.stderr
    assert "lib/dep" in result.stdout


def test_a_ref_containing_a_slash_is_located(project):
    # a tag or branch name may itself contain a slash - deploy/harbor-1.2, feature/x
    result = update_submodule("--check", "dep@deploy/harbor-1.2")
    assert result.returncode == 0, result.stderr
    assert "lib/dep" in result.stdout


def test_name_without_a_ref_is_still_located(project):
    result = update_submodule("--check", "dep")
    assert result.returncode == 0, result.stderr
    assert "lib/dep" in result.stdout


def test_several_dependencies_with_refs_are_all_located(project):
    result = update_submodule("--check", "dep@main", "other@main")
    assert result.returncode == 0, result.stderr
    assert "lib/dep" in result.stdout
    assert "lib/other" in result.stdout


def test_only_the_named_dependency_is_checked(project):
    # the report must describe what was actually inspected, not claim the whole project
    result = update_submodule("--check", "dep@main")
    assert result.returncode == 0, result.stderr
    assert "lib/other" not in result.stdout


def test_an_unknown_dependency_with_a_ref_is_reported_by_its_path(project):
    # the ref is not what was missing, so the message names the path that was looked for
    result = update_submodule("--check", "nosuch@main")
    assert result.returncode != 0
    assert "nosuch" in result.stderr
    assert "no submodule" in result.stderr


# ── what forge is handed ──────────────────────────────────────────────────────────────────────────


def test_forge_receives_the_ref_on_the_resolved_path(project, forge_stub):
    # forge does not split a ref off a bare name: `dep@main` sends it looking in `lib/dep@main`
    path_prefix, recorded_arguments = forge_stub
    result = update_submodule("dep@main", path_prefix=path_prefix)
    assert result.returncode == 0, result.stderr
    assert recorded_arguments() == ["update", "lib/dep@main"]


def test_forge_receives_a_path_argument_unchanged(project, forge_stub):
    path_prefix, recorded_arguments = forge_stub
    result = update_submodule("lib/dep@main", path_prefix=path_prefix)
    assert result.returncode == 0, result.stderr
    assert recorded_arguments() == ["update", "lib/dep@main"]


def test_forge_receives_the_resolved_path_when_no_ref_is_given(project, forge_stub):
    path_prefix, recorded_arguments = forge_stub
    result = update_submodule("dep", path_prefix=path_prefix)
    assert result.returncode == 0, result.stderr
    assert recorded_arguments() == ["update", "lib/dep"]


def test_forge_receives_every_named_dependency(project, forge_stub):
    path_prefix, recorded_arguments = forge_stub
    result = update_submodule("dep@main", "other", path_prefix=path_prefix)
    assert result.returncode == 0, result.stderr
    assert recorded_arguments() == ["update", "lib/dep@main", "lib/other"]


def test_forge_is_given_no_dependencies_when_none_are_named(project, forge_stub):
    # naming none means ALL, which forge expresses by receiving no dependency arguments
    path_prefix, recorded_arguments = forge_stub
    result = update_submodule(path_prefix=path_prefix)
    assert result.returncode == 0, result.stderr
    assert recorded_arguments() == ["update"]


def test_forge_is_not_reached_when_a_dependency_is_dirty(project, forge_stub):
    # the guard's whole purpose: a destructive update must not run over uncommitted work
    path_prefix, recorded_arguments = forge_stub
    (project / "lib" / "dep" / "README.md").write_text("edited\n")
    result = update_submodule("dep@main", path_prefix=path_prefix)
    assert result.returncode != 0
    assert recorded_arguments() == []


def test_forge_is_not_reached_with_check(project, forge_stub):
    path_prefix, recorded_arguments = forge_stub
    result = update_submodule("--check", "dep@main", path_prefix=path_prefix)
    assert result.returncode == 0, result.stderr
    assert recorded_arguments() == []
