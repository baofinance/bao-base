"""The scratch repositories the `git dep` tests run in, and how a test types a command.

Each test gets its own remotes and its own clone, built with real git and served from paths on disk:

    shared, deep   no dependencies
    base           stands for bao-base: it holds the `bin/git-dep` under test and a `doc/dependencies.md`
    dep            has lib/shared and lib/bao-base, at an earlier commit of base whose cookbook differs
    tool           has lib/deep, and the tags v1 and v2
    proj           has lib/bao-base, lib/dep (following main), lib/shared and lib/tool (at v1)

The remotes are bare, so a push works. A seed is a work clone of a remote that stands for a teammate: a
change is committed there and pushed. `world.project` is the clone under test, with everything checked out.

A test types `git dep ...` through git once a first `setup` by path has written the alias. The tests of
that first run type the path. The fixtures that build a world are in conftest.py.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path
from typing import NamedTuple

BAO_BASE = Path(__file__).resolve().parents[3]
SCRIPT = BAO_BASE / "bin" / "git-dep"
COOKBOOK = BAO_BASE / "doc" / "dependencies.md"
EARLIER_COOKBOOK = "# Dependencies: a cookbook\n\nThe cookbook as an earlier bao-base had it.\n"

# Every dependency folder of the clone, at every depth, as typed from its top folder.
FOLDERS = (
    "lib/bao-base",
    "lib/dep",
    "lib/dep/lib/bao-base",
    "lib/dep/lib/shared",
    "lib/shared",
    "lib/tool",
    "lib/tool/lib/deep",
)
# The command that runs the script by its path, typed in the clone's top folder.
BY_PATH = "lib/bao-base/bin/git-dep"

# The last commands a run prints when it writes the settings, typed in the clone's top folder: the cookbook's
# three settings and the alias, for the repository and then for every dependency folder.
FOREACH = (
    "git config push.recurseSubmodules check; git config diff.submodule log; "
    "git config status.submoduleSummary true; "
    'if [ -e bin/git-dep ]; then git config alias.dep "!bin/git-dep"; '
    'elif [ -e lib/bao-base/bin/git-dep ]; then git config alias.dep "!lib/bao-base/bin/git-dep"; fi'
)
WRITING_THE_SETTINGS = [
    "$ git config push.recurseSubmodules check",
    "$ git config diff.submodule log",
    "$ git config status.submoduleSummary true",
    "$ git config alias.dep '!lib/bao-base/bin/git-dep'",
    f"$ git submodule foreach --quiet --recursive '{FOREACH}'",
]


# The three settings of the cookbook, which every clone holds in the repository and in each dependency folder.
THE_THREE = {"push.recurseSubmodules": "check", "diff.submodule": "log", "status.submoduleSummary": "true"}


def printed(done: subprocess.CompletedProcess[str]) -> list[str]:
    """The git commands a run printed before it ran them."""
    return [line for line in done.stdout.splitlines() if line.startswith("$ ")]


def git(where: Path, *arguments: str) -> str:
    """What git prints for a command that must succeed, run in `where`."""
    return subprocess.run(["git", *arguments], cwd=where, check=True, capture_output=True, text=True).stdout.strip()


def typed(where: Path, command: str) -> subprocess.CompletedProcess[str]:
    """Run a command line exactly as a person types it, in the folder `where`."""
    return subprocess.run(command, shell=True, cwd=where, capture_output=True, text=True)


def commit(seed: Path, subject: str) -> str:
    """Change the seed's own file, commit everything in the seed, and push. Returns the commit."""
    with (seed / f"{seed.name}.txt").open("a") as file:
        file.write(f"{subject}\n")
    git(seed, "add", "-A")
    git(seed, "commit", "-qm", subject)
    git(seed, "push", "-q", "origin", "HEAD")
    return git(seed, "rev-parse", "HEAD")


def point(seed: Path, path: str, commit_id: str) -> None:
    """Put the seed's folder `path` at the commit, for the seed's next commit to record."""
    git(seed / path, "fetch", "-q", "origin")
    git(seed / path, "checkout", "-q", commit_id)


def head(folder: Path) -> str:
    """The commit a folder is at."""
    return git(folder, "rev-parse", "HEAD")


def subject(folder: Path) -> str:
    """The subject of the commit a folder is at, which says which commit of the scratch world it is."""
    return git(folder, "log", "-1", "--format=%s")


def branch(folder: Path) -> str | None:
    """The branch a folder is on, or None when it is on none."""
    found = subprocess.run(
        ["git", "symbolic-ref", "--quiet", "--short", "HEAD"], cwd=folder, capture_output=True, text=True
    )
    return found.stdout.strip() if found.returncode == 0 else None


def setting(folder: Path, key: str) -> str | None:
    """The value git uses for a setting in `folder`, or None when nothing sets it."""
    found = subprocess.run(["git", "config", "--get", key], cwd=folder, capture_output=True, text=True)
    return found.stdout.strip() if found.returncode == 0 else None


def own_setting(folder: Path, key: str) -> str | None:
    """The value the folder's own config holds for a setting, or None when it holds none."""
    found = subprocess.run(["git", "config", "--local", "--get", key], cwd=folder, capture_output=True, text=True)
    return found.stdout.strip() if found.returncode == 0 else None


class World(NamedTuple):
    """One test's remotes, seeds and clone."""

    root: Path
    project: Path

    def remote(self, name: str) -> Path:
        return self.root / "remotes" / f"{name}.git"

    def seed(self, name: str) -> Path:
        return self.root / "seeds" / name


def build_world(root: Path) -> World:
    remotes, seeds = root / "remotes", root / "seeds"
    remotes.mkdir()
    seeds.mkdir()
    for name in ("shared", "deep", "base", "dep", "tool", "proj"):
        git(root, "init", "-q", "--bare", str(remotes / f"{name}.git"))
        git(root, "clone", "-q", str(remotes / f"{name}.git"), str(seeds / name))
    commit(seeds / "shared", "shared s1")
    commit(seeds / "deep", "deep d1")

    base = seeds / "base"
    (base / "bin").mkdir()
    shutil.copy(SCRIPT, base / "bin" / "git-dep")
    (base / "doc").mkdir()
    (base / "doc" / "dependencies.md").write_text(EARLIER_COOKBOOK)
    commit(base, "base b1")

    dep = seeds / "dep"
    git(dep, "submodule", "--quiet", "add", str(remotes / "shared.git"), "lib/shared")
    git(dep, "submodule", "--quiet", "add", str(remotes / "base.git"), "lib/bao-base")
    commit(dep, "dep c1")

    shutil.copy(COOKBOOK, base / "doc" / "dependencies.md")
    commit(base, "base b2")

    tool = seeds / "tool"
    git(tool, "submodule", "--quiet", "add", str(remotes / "deep.git"), "lib/deep")
    commit(tool, "tool t1")
    git(tool, "tag", "v1")
    point(tool, "lib/deep", commit(seeds / "deep", "deep d2"))
    commit(tool, "tool t2")
    git(tool, "tag", "v2")
    git(tool, "push", "-q", "origin", "--tags")

    proj = seeds / "proj"
    git(proj, "submodule", "--quiet", "add", str(remotes / "base.git"), "lib/bao-base")
    git(proj, "submodule", "--quiet", "add", "-b", "main", str(remotes / "dep.git"), "lib/dep")
    git(proj, "submodule", "--quiet", "add", str(remotes / "shared.git"), "lib/shared")
    git(proj, "submodule", "--quiet", "add", str(remotes / "tool.git"), "lib/tool")
    git(proj / "lib" / "tool", "checkout", "-q", "v1")
    (proj / "src").mkdir()
    (proj / "src" / "p.txt").write_text("p\n")
    commit(proj, "proj p1")

    project = root / "project"
    git(root, "clone", "-q", "--recurse-submodules", str(remotes / "proj.git"), str(project))
    return World(root, project)
