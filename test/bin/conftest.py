"""Pytest configuration and the shared temp-git-repo harness for the bin regression-system tests."""

import subprocess
import sys
from pathlib import Path

import pytest

# Put the bin directory on the path at conftest import time - BEFORE test modules are collected - so a
# test can `import ratchet` (etc.) at module top, not only inside a function where a fixture has run.
_BIN_DIR = Path(__file__).parent.parent.parent / "bin"
if str(_BIN_DIR) not in sys.path:
    sys.path.insert(0, str(_BIN_DIR))


class GitRepo:
    """A throwaway git repo for driving a regression file into each state the ratchet distinguishes.

    `file` is the regression file's repo-relative path. The state is set by the combination of HEAD,
    the index (`git show :file`), and the working-tree copy - which is what the tools read to tell a
    present baseline from a working-copy deletion, a staged deletion, or a never-tracked file.
    """

    def __init__(self, root: Path, file: str = "regression/f.txt"):
        self.root = root
        self.file = file
        self._path = root / file

    def _git(self, *args):
        subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True)

    def init(self):
        self._git("init", "-q")
        self._git("config", "user.email", "test@example.com")
        self._git("config", "user.name", "test")

    def write(self, text: str):
        """Write the working-tree copy (an unstaged edit); the index is untouched."""
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._path.write_text(text)

    def commit(self, text: str):
        """Commit `text` as the baseline: present in HEAD, the index, and the working tree."""
        self.write(text)
        self._git("add", "-A")
        self._git("commit", "-qm", "baseline")

    def stage(self, text: str):
        """Stage `text` without committing: it becomes the index (`git show :file`) baseline."""
        self.write(text)
        self._git("add", self.file)

    def stage_deletion(self):
        """Delete the working copy AND stage the deletion: the index has no version, HEAD still does."""
        self._path.unlink()
        self._git("add", self.file)

    def delete_worktree(self):
        """Delete only the working copy; the index still holds it (an unstaged deletion)."""
        self._path.unlink()

    def read(self) -> str:
        return self._path.read_text()

    def exists(self) -> bool:
        return self._path.exists()


@pytest.fixture
def repo(tmp_path, monkeypatch):
    """An initialised throwaway git repo with the process CWD moved into it.

    The tools resolve the baseline and the working-tree file relative to the CWD (they run from the
    repo root in production), so the fixture chdirs there and tests address the file by its
    repo-relative path. `regression/` is pre-created because the wrappers `mkdir -p` it before the
    ratchet runs.
    """
    repo = GitRepo(tmp_path)
    repo.init()
    (tmp_path / "regression").mkdir()
    monkeypatch.chdir(tmp_path)
    return repo
