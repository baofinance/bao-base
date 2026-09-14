"""What `forge build` does to the repository a scratch tree was made from. Measured on forge 1.8.1.

A recovery build compiles an old commit in a throwaway directory. `forge build` settles the
project's dependencies BEFORE compiling: finding one it judges missing it installs recursively,
unbidden - nothing here asks it to. Where that throwaway directory is a linked git worktree, its
submodules share the real repository's `.git/modules`, and the install re-points every shared
gitdir's `core.worktree` at the throwaway. Delete the throwaway and every dependency of the real
checkout is unreadable: `fatal: cannot chdir`.

That is not hypothetical - it is what happened to harbor on 2026-09-13, to all 29 of its submodule
gitdirs, from one `yarn verify-audit --write` run.

So `deployment_recovery.export_tree` gives the build FILES and no git at all. These tests pin both
halves: that forge really does install into a repository it finds a gap in, and that an exported
tree gives it nothing to install into and nothing to reach back through. The first is what makes the
second more than a tautology - if forge stopped auto-installing, the first test fails and says so.
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

BAO_BASE = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(BAO_BASE / "bin"))

from deployment_recovery import export_tree  # noqa: E402

FOUNDRY_TOML = '[profile.default]\nsrc = "src"\nlibs = ["lib"]\nauto_detect_remappings = false\n'
SOURCE = "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.0;\n"


def git(where: Path, *arguments: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", "-c", "protocol.file.allow=always", *arguments],
        cwd=where,
        capture_output=True,
        text=True,
        check=True,
    )


def forge_build(where: Path) -> str:
    """`forge build` as a recovery runs it: every FOUNDRY_* variable scrubbed but the install location.

    The fixtures' remotes are local paths, which git refuses for submodules unless told otherwise. A
    real dependency is an https remote and needs no such permission, so this only removes a
    restriction the fixture would otherwise hit - it grants forge nothing it lacks in production.
    """
    environment = {k: v for k, v in os.environ.items() if not k.startswith("FOUNDRY_") or k == "FOUNDRY_DIR"}
    environment.update(
        {"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "protocol.file.allow", "GIT_CONFIG_VALUE_0": "always"}
    )
    done = subprocess.run(
        ["forge", "build", "src/A.sol"], cwd=where, capture_output=True, text=True, env=environment, timeout=600
    )
    return done.stdout + done.stderr


def dependency(root: Path, name: str) -> Path:
    at = root / name
    (at / "src").mkdir(parents=True)
    git(root, "init", "-q", "-b", "main", name)
    git(at, "config", "user.email", "t@t")
    git(at, "config", "user.name", "test")
    (at / "src" / f"{name}.sol").write_text(SOURCE)
    git(at, "add", "-A")
    git(at, "commit", "-qm", name)
    return at


def project_with(root: Path, names: list[str]) -> Path:
    """A foundry project depending on each of `names`, every one checked out."""
    sources = [dependency(root, name) for name in names]
    project = root / "project"
    (project / "src").mkdir(parents=True)
    git(root, "init", "-q", "-b", "main", "project")
    git(project, "config", "user.email", "t@t")
    git(project, "config", "user.name", "test")
    (project / "foundry.toml").write_text(FOUNDRY_TOML)
    (project / "src" / "A.sol").write_text(SOURCE)
    for source, name in zip(sources, names):
        git(project, "submodule", "--quiet", "add", str(source), f"lib/{name}")
    git(project, "add", "-A")
    git(project, "commit", "-qm", "project")
    return project


def worktrees_of(project: Path) -> dict[str, str]:
    """Every `core.worktree` the project's submodule gitdirs record, by gitdir."""
    found = {}
    for config in sorted((project / ".git" / "modules").rglob("config")):
        for line in config.read_text().splitlines():
            if line.strip().startswith("worktree ="):
                found[str(config.parent.relative_to(project))] = line.split("=", 1)[1].strip()
    return found


def readable(project: Path, name: str) -> bool:
    done = subprocess.run(["git", "status", "--short"], cwd=project / "lib" / name, capture_output=True, text=True)
    return done.returncode == 0


def test_a_declared_vyper_compiler_must_exist_even_to_build_solidity(tmp_path):
    """Why an export has to carry a toolchain, not just sources.

    A solidity file cannot import a vyper one, so nothing here needs vyper to compile - but forge
    resolves the whole project before compiling anything, and refuses when the vyper compiler the
    project declares is not there. harbor names one by a RELATIVE path into an untracked `.venv`,
    which reaches no export and no checkout, so one vyper TEST MOCK failed every recovery build.

    Skipping does not avoid it - `--skip` is measured here, and a `skip` setting and a profile
    carrying one were measured the same way. Forge resolves the compiler before any filter applies.
    """
    project = tmp_path / "project"
    (project / "src").mkdir(parents=True)
    (project / "foundry.toml").write_text(f"{FOUNDRY_TOML}[vyper]\npath = '.venv/bin/vyper'\n")
    (project / "src" / "A.sol").write_text(SOURCE)
    (project / "src" / "Mock.vy").write_text("@external\ndef value() -> uint256:\n    return 1\n")

    plain = forge_build(project)
    assert "vyper" in plain, plain

    environment = {k: v for k, v in os.environ.items() if not k.startswith("FOUNDRY_") or k == "FOUNDRY_DIR"}
    skipped = subprocess.run(
        ["forge", "build", "src/A.sol", "--skip", ".vy"],
        cwd=project,
        capture_output=True,
        text=True,
        env=environment,
        timeout=600,
    )
    assert skipped.returncode != 0, "--skip does not avoid needing the compiler"
    assert "vyper" in skipped.stdout + skipped.stderr, skipped.stdout + skipped.stderr


def test_forge_build_installs_a_dependency_it_finds_missing(tmp_path):
    # Unbidden: the command is `forge build`, and settling dependencies is something it does on the
    # way. This is the behaviour the export exists to keep away from a real repository, so if forge
    # ever stops doing it, the guarantee below stops being a guarantee about anything.
    project = project_with(tmp_path, ["present", "absent"])
    # An empty directory is what forge reads as missing, and what a checkout that could not be
    # placed leaves behind.
    shutil.rmtree(project / "lib" / "absent")
    (project / "lib" / "absent").mkdir()

    output = forge_build(project)

    assert "Missing dependencies found" in output, output


def test_the_install_repoints_a_shared_gitdir_when_the_build_runs_in_a_linked_worktree(tmp_path):
    # Why the export cannot be a worktree. A linked worktree's submodules share the REAL repository's
    # .git/modules, so forge settling a dependency inside the worktree rewrites where the real
    # checkout believes its own dependencies live.
    project = project_with(tmp_path, ["present", "absent"])
    before = worktrees_of(project)

    at = tmp_path / "wt"
    git(project, "worktree", "add", "--detach", "--quiet", str(at), "HEAD")
    (at / "lib" / "present").rmdir()
    git(project / "lib" / "present", "worktree", "add", "--detach", "--quiet", str(at / "lib" / "present"), "HEAD")

    forge_build(at)

    after = worktrees_of(project)
    assert after[".git/modules/lib/present"] != before[".git/modules/lib/present"], (
        "forge's install re-pointed the real repository's gitdir at the worktree"
    )
    # Relative, as git writes it, and as the observed damage carried it - so the tail is what names
    # where it now points.
    assert after[".git/modules/lib/present"].endswith(f"{at.name}/lib/present"), after[".git/modules/lib/present"]


def test_a_build_in_an_exported_tree_leaves_the_repository_it_came_from_untouched(tmp_path):
    # The guarantee. Same gap, same forge, no git in the tree - so there is nothing to install into
    # and nothing shared to reach back through.
    project = project_with(tmp_path, ["present", "absent"])
    subprocess.run(["rm", "-rf", str(project / "lib" / "absent")], check=True)
    before = worktrees_of(project)

    at = tmp_path / "exported"
    failures = export_tree(project, "HEAD", at)
    assert any(failure.startswith("lib/absent@") for failure in failures), failures

    forge_build(at)

    assert worktrees_of(project) == before, "no gitdir of the real repository was touched"
    assert readable(project, "present"), "the real dependency is still readable"
    assert list(at.rglob(".git")) == [], "the export never held a repository to install into"
