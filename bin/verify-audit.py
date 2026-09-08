#!/usr/bin/env python3
"""Usage: verify-audit [revision-or-pattern ...]

Defaults to `audit*` and `deploy*`. Fails if a deployed contract's creation bytecode has drifted
since a resolved revision (new files are OK).

An argument holding a glob metacharacter is a PATTERN, expanded via `git tag -l` (so `deploy-*`
works - quote it to avoid shell globbing); matching no tags is information, not a failure. Any other
argument is an EXPLICIT name and must resolve, or the run fails: a tag, a branch, or a commit SHA -
so a repo that cuts no tags can still compare against the commit its deploy was built from. A name
that is both a tag and a branch resolves as the tag, and says so.

A changed file is auto-cleared when it is meaning-neutral: its version at that revision and in the
current tree compile to the same metadata-stripped creation bytecode. Both sides are compiled with
the current toolchain (FOUNDRY_BYTECODE_HASH=none, FOUNDRY_CBOR_METADATA=false) in a throwaway git
worktree taken from a snapshot of the current tree - staged, unstaged and untracked content included
- so the revision compiles under the configuration and dependencies the tree actually has rather
than the last commit's; only the changed files and their import closure are built, and a guard fails
loudly if those switches stop disabling metadata. This clears renames, comment/NatSpec, and
formatting changes that do not alter bytecode. Rename detection is forced on (git -M -l0) so a
repo's diff.renames / diff.renameLimit config cannot mis-report a rename as drift. Deletions, and
any change that alters bytecode, are reported. Requires `forge` on PATH.

A `.verify-audit-ignore` file in the current directory controls what is skipped. Each non-comment,
non-blank line has the form:

  rev                          - ignore the whole revision
  rev file1 file2 ...          - ignore specific files within the revision only; other drifting
                                 files in it still fail
  rev {dir1 dir2} [file ...]   - restrict the revision's checks to those directories (the deploy
                                 only covered them); files outside the dirs are not checked, and any
                                 file entry outside them is an error
  rev {path.json:field} [file] - scope to the contracts a deployment manifest records: the named
                                 JSON field's values (read at that revision), each taken up to its
                                 ":" suffix. This is complete by construction. Dirs and manifests
                                 may be mixed inside { }.

`rev` is the argument as written on the command line - a tag, branch or commit. `#` begins a comment.
Ignored revisions/files are reported but do not contribute to the exit status - unless an entry is
stale: a file entry that matches no changed file, whose change would now clear
(bytecode-equivalent), or that lies outside the revision's declared scope. All are reported as
errors ("remove it") so the ignore file stays minimal.
"""

from __future__ import annotations

import fnmatch
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# Where audited source may live. Rename detection pairs only among the paths that survive the
# pathspec, so any location a source file can legitimately move TO must be listed here: otherwise
# the move looks like an unpaired deletion inside src, and git pairs it with whatever unrelated new
# file scores above its similarity threshold - reporting that new file as drift while hiding the
# real move.
_AUDIT_PATHSPEC = ["src", "deprecated/src"]

_MISSING = "__MISSING__"

# The metadata-disabling switches, applied to every compile so both sides of a comparison are built
# the same way.
_METADATA_OFF = {"FOUNDRY_BYTECODE_HASH": "none", "FOUNDRY_CBOR_METADATA": "false"}

# Where the toolchain is installed, as opposed to how it compiles. It survives the scrub below
# because dropping it would send forge looking for its own installation in the default location.
_FOUNDRY_INSTALL_VARS = {"FOUNDRY_DIR"}


def _out(text: str) -> None:
    """Write to stdout unbuffered, so it interleaves with subprocess output in the order written."""
    sys.stdout.write(text)
    sys.stdout.flush()


def _err(text: str) -> None:
    sys.stderr.write(text)
    sys.stderr.flush()


def _log(message: str) -> None:
    """The INFO line the bash `log` printed, mirrored: level 0, gated on verbosity, on stderr."""
    if int(os.environ.get("BAO_BASE_VERBOSITY") or "0") >= 0:
        _err(f"\033[0;32mINFO  \033[0m{message}\n")


def _forge_env(**overrides: str) -> dict[str, str]:
    """The environment every forge invocation runs in.

    Every FOUNDRY_* variable the caller had is dropped, apart from where the toolchain is installed:
    the rest steer the build - optimizer, via_ir, remappings, artefact and cache locations - so
    letting them through would make a verdict depend on the shell the run was started from, and would
    silently give a FOUNDRY_* variable added by some future Foundry the same power. Only what this
    function sets survives. Nothing outside that namespace is touched, because forge still needs PATH,
    HOME, and the solc store they lead to.

    FOUNDRY_PROFILE is not scrubbed here but refused outright at startup: selecting a profile changes
    which foundry.toml section applies, and there is no value that means "no profile", so it can be
    neither honoured nor neutralised.
    """
    env = {k: v for k, v in os.environ.items() if not k.startswith("FOUNDRY_") or k in _FOUNDRY_INSTALL_VARS}
    env.update(_METADATA_OFF)
    env.update(overrides)
    return env


def _git(*args: str, cwd: Path | None = None) -> subprocess.CompletedProcess:
    """Run git capturing both streams; the caller decides what a non-zero status means."""
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)


# An identity for the snapshot commit, so taking it never depends on the caller having configured
# one. The commit is thrown away when the run ends and is never pushed anywhere.
_SNAPSHOT_IDENTITY = {
    "GIT_AUTHOR_NAME": "verify-audit",
    "GIT_AUTHOR_EMAIL": "verify-audit@localhost",
    "GIT_COMMITTER_NAME": "verify-audit",
    "GIT_COMMITTER_EMAIL": "verify-audit@localhost",
}


def _snapshot_commit() -> str | None:
    """A commit holding the current tree - staged, unstaged and untracked - or None if it cannot be.

    This is what both sides of every comparison are built from, so the revision is compiled under the
    configuration and dependencies the tree actually HAS rather than the last commit's. Compiling the
    two sides under different configurations is not merely a build failure waiting to happen: a
    remapping that resolves a base contract elsewhere would silently manufacture or mask drift. It has
    to be a commit because that is what `git worktree add` and `git restore --source` accept.

    Built through a private index OUTSIDE the repository, so the repository's own index is neither
    locked nor rewritten: a concurrent git command can neither be disturbed by this nor make it fail.
    (`git stash create` does both, and when the index lock is held it exits 1 printing nothing at all
    - indistinguishable from the empty output it gives for a clean tree.) The index has to live
    outside the working tree or `git add -A` would snapshot the index file itself. Ignored files stay
    out, because `git add` leaves them out.
    """
    with tempfile.TemporaryDirectory(prefix="verify-audit-index-") as directory:
        env = {**os.environ, **_SNAPSHOT_IDENTITY, "GIT_INDEX_FILE": str(Path(directory) / "index")}

        def snapshot_git(*args: str) -> subprocess.CompletedProcess:
            return subprocess.run(["git", *args], capture_output=True, text=True, env=env)

        for args in (("read-tree", "HEAD"), ("add", "-A", "."), ("write-tree",)):
            done = snapshot_git(*args)
            if done.returncode != 0:
                _err(f"\033[31mERROR: could not snapshot the current tree: `git {args[0]}` failed\033[0m\n")
                _err(done.stderr)
                return None
            tree = done.stdout.strip()

        done = snapshot_git("commit-tree", tree, "-p", "HEAD", "-m", "verify-audit snapshot of the current tree")
        if done.returncode != 0:
            _err("\033[31mERROR: could not snapshot the current tree: `git commit-tree` failed\033[0m\n")
            _err(done.stderr)
            return None
        return done.stdout.strip()


def _git_lines(*args: str, cwd: Path | None = None) -> list[str]:
    """The command's stdout as lines, empty when it failed or printed nothing."""
    done = _git(*args, cwd=cwd)
    if done.returncode != 0:
        return []
    return done.stdout.splitlines()


def _git_value(*args: str) -> str | None:
    """The command's single-line stdout, or None when it failed - `rev-parse --verify --quiet`."""
    done = _git(*args)
    if done.returncode != 0:
        return None
    return done.stdout.strip()


def _submodules(base: str) -> dict[str, str]:
    """Every submodule the snapshot records, at any depth: path -> the commit recorded for it.

    Walked one level at a time because a nested submodule's commit is recorded in its parent's tree
    and `git ls-tree` cannot see through a gitlink. Each level is read from that submodule's own
    checkout in this working tree, which is where its objects already are.
    """
    found: dict[str, str] = {}
    frontier = [("", Path("."), base)]
    while frontier:
        prefix, repo, commit = frontier.pop()
        for line in _git_lines("ls-tree", "-r", commit, cwd=repo):
            info, _, path = line.partition("\t")
            fields = info.split()
            if len(fields) != 3 or fields[1] != "commit":
                continue
            full = f"{prefix}{path}"
            found[full] = fields[2]
            frontier.append((f"{full}/", Path(full), fields[2]))
    return found


def _needed_submodules(worktree: Path, submodules: dict[str, str]) -> dict[str, str] | None:
    """The submodules the build can reach, from the remappings it will compile with; None on failure.

    With auto_detect_remappings off, a remapping target is the only way a path inside a submodule can
    be reached, so one that no target points into is never read and need not be placed at all - 8 of
    harbor's 29. With auto-detection on forge may resolve through any of them, so all are placed.

    The set is a superset of what the build imports rather than exactly it, which is the safe
    direction: a path that resolves outside every remapping fails as an unresolved import naming the
    file, which is actionable, where guessing too small a set silently changes what compiles.
    """
    done = subprocess.run(["forge", "config", "--json"], cwd=worktree, capture_output=True, text=True, env=_forge_env())
    if done.returncode != 0:
        _err("\033[31m  `forge config --json` failed, so the submodules to place cannot be worked out:\033[0m\n")
        _err(done.stderr)
        return None
    try:
        config = json.loads(done.stdout)
    except json.JSONDecodeError:
        _err(
            "\033[31m  `forge config --json` did not return JSON, so the submodules to place cannot be worked out\033[0m\n"
        )
        return None
    if config.get("auto_detect_remappings"):
        return dict(submodules)
    targets = [remapping.partition("=")[2] for remapping in config.get("remappings") or []]
    return {
        path: commit
        for path, commit in submodules.items()
        if any(target == path or target.startswith(path + "/") for target in targets)
    }


def _locate_moved(rev: str, path: str) -> str:
    """Where a deleted file went, if it is still on disk.

    Git pairs a rename only among paths it tracks that survive the pathspec, so a move whose
    destination is untracked, or outside _AUDIT_PATHSPEC, reaches the report as a plain deletion.
    Matching is by exact blob identity, never similarity: an identical blob elsewhere IS the moved
    file. Returns a note, or "" when the deletion is genuine.
    """
    blob = _git_value("rev-parse", f"{rev}:{path}")
    if blob is None:
        return ""
    base = path.rsplit("/", 1)[-1]
    for candidate in _git_lines("ls-files", "--cached", "--others", "--exclude-standard"):
        if candidate.rsplit("/", 1)[-1] != base or not Path(candidate).is_file():
            continue
        if _git_value("hash-object", candidate) != blob:
            continue
        if _git("ls-files", "--error-unmatch", candidate).returncode == 0:
            return (
                f"identical content at {candidate} (tracked, outside the audit pathspec"
                " - add its directory to _AUDIT_PATHSPEC)"
            )
        return f"identical content at {candidate} (untracked - git add it so the move is seen as a rename)"
    return ""


def _assert_metadata_disabled() -> bool:
    """Confirm the metadata-disabling env switches actually take effect; else fail loudly.

    Guards against a future Foundry renaming/ignoring these switches, which would otherwise leave
    metadata in the bytecode and produce false fails/clears.
    """
    done = subprocess.run(["forge", "config"], capture_output=True, text=True, env=_forge_env())
    cfg = done.stdout + done.stderr
    if done.returncode != 0:
        _err(f"\033[31mERROR: `forge config` failed; cannot verify metadata disabled:\n{cfg}\033[0m\n")
        return False
    if 'bytecode_hash = "none"' not in cfg or "cbor_metadata = false" not in cfg:
        reported = "\n".join(line for line in cfg.splitlines() if "bytecode_hash" in line or "cbor_metadata" in line)
        _err(f"\033[31mERROR: metadata not disabled; forge config reports:\n{reported}\033[0m\n")
        return False
    return True


def _forge_build(out: Path, cache: Path, paths: list[str], cwd: Path | None = None) -> tuple[bool, str]:
    """Compile the given source paths and their import closure into `out`, metadata off.

    Returns whether it succeeded and what forge said, because a failure here is reported to the
    reader: a build that stopped is the one thing a bytecode comparison cannot work around, and
    discarding forge's account of why leaves them nothing to act on.

    The cache is named explicitly, and never the project's. Sharing the project's cache damages it -
    its entries would point at an `out` this run deletes on exit, so the next ordinary build
    recompiles - and makes this run's result depend on state a concurrent forge command may be
    rewriting.
    """
    out.mkdir(parents=True, exist_ok=True)
    cache.mkdir(parents=True, exist_ok=True)
    done = subprocess.run(
        ["forge", "build", "--deny=never", *paths],
        cwd=cwd,
        capture_output=True,
        text=True,
        env=_forge_env(FOUNDRY_OUT=str(out), FOUNDRY_CACHE_PATH=str(cache)),
    )
    return done.returncode == 0, done.stdout + done.stderr


def _file_signature(out_dir: Path, sol_path: str) -> str:
    """Sorted concat of the creation bytecode of every contract compiled from one .sol file.

    forge writes artifacts to <out>/<basename>.sol/<Contract>.json. Names are not used, so this is
    robust to renames; a multi-contract file compares its whole set. "__MISSING__" if the file
    produced no artifacts (e.g. deleted/uncompiled).
    """
    directory = out_dir / sol_path.rsplit("/", 1)[-1]
    if not directory.is_dir():
        return _MISSING
    objects = []
    for artifact in directory.glob("*.json"):
        try:
            data = json.loads(artifact.read_text())
        except json.JSONDecodeError:
            # An unreadable artifact contributes nothing, as it did when this read it through jq.
            continue
        objects.append((data.get("bytecode") or {}).get("object") or "")
    return "".join(sorted(objects))


def _signature_identifies(signature: str) -> bool:
    """Whether a signature identifies a file at all.

    A file holding only abstract contracts or interfaces compiles to an empty creation object, and
    EVERY such file shares that value - so pairing on it would match unrelated files to each other.
    "__MISSING__" means nothing compiled.
    """
    return signature != _MISSING and signature.replace("0x", "") != ""


def _signature_matches(signature: str, head_out: Path, candidates: list[str]) -> list[str]:
    """Every candidate whose signature in the current tree equals `signature`.

    Used both to find where a vanished file went and to detect a second claimant on a pairing git
    already made.
    """
    return [c for c in candidates if _file_signature(head_out, c) == signature]


class _Builds:
    """The throwaway build directories and worktree a run compiles in.

    One worktree checked out at `base` - the snapshot of the current tree, so its foundry.toml, lib
    and settings are the ones the tree actually has - with a persistent forge cache, so the import
    closure compiles once and is reused across every revision. Created lazily on the first revision
    that needs a build.
    """

    def __init__(self, base: str) -> None:
        self.base = base  # the snapshot commit every comparison is made against
        self.root: Path | None = None  # everything this run compiles into, created on first use
        self.head_out: Path | None = None  # reused build dir for the current tree
        self.head_cache: Path | None = None
        self.wt: Path | None = None  # shared worktree of the current tree, the revision's source in it
        self.nested: list[tuple[Path, Path]] = []  # (submodule checkout, its worktree in self.wt)
        self.wt_out: Path | None = None
        self.wt_cache: Path | None = None  # persistent forge cache for the worktree

    def _in_root(self, name: str) -> Path:
        """A path under this run's throwaway root, which is created on the first request."""
        if self.root is None:
            self.root = Path(tempfile.mkdtemp(prefix="verify-audit-"))
        return self.root / name

    def ensure_head_out(self) -> bool:
        if self.head_out is not None:
            return True
        if not _assert_metadata_disabled():
            return False
        self.head_out = self._in_root("current-out")
        self.head_cache = self._in_root("current-cache")
        return True

    def ensure_worktree(self) -> bool:
        if self.wt is not None:
            return True
        wt = self._in_root("worktree")  # `git worktree add` creates it; it must not pre-exist
        done = _git("worktree", "add", "--detach", "--quiet", str(wt), self.base)
        if done.returncode != 0:
            _err(f"\033[31m  `git worktree add` failed:\033[0m\n{done.stderr}")
            return False
        # Recorded before the submodules are placed, so that a failure there still leaves cleanup
        # something to remove: the registration exists from this point on, whatever happens next.
        self.wt = wt

        # Each submodule is placed as a worktree of its OWN checkout here, not cloned from its
        # remote. That is what makes a run local: the objects are already in this clone, so a
        # submodule sitting at an unpushed commit - the normal state while one is being worked on -
        # is readable, where a clone would ask a remote that has never heard of it. It is also what
        # keeps the run cheap, since a worktree shares the object store instead of copying it, and
        # what keeps it safe: the submodule gets its own checkout, so the one being worked in is not
        # touched.
        needed = _needed_submodules(wt, _submodules(self.base))
        if needed is None:
            return False
        for path in sorted(needed, key=lambda p: p.count("/")):  # parents before their children
            repo = Path(path)
            if not (repo / ".git").exists():
                _err(f'\033[31m  submodule "{path}" is not checked out here, so it cannot be read\033[0m\n')
                _err(f"       run `git submodule update --init {path}` and try again\n")
                return False
            done = _git("worktree", "add", "--detach", "--quiet", str(wt / path), needed[path], cwd=repo)
            if done.returncode != 0:
                _err(f'\033[31m  could not place submodule "{path}" in the worktree:\033[0m\n{done.stderr}')
                return False
            self.nested.append((repo, wt / path))
        self.wt_out = self._in_root("revision-out")
        self.wt_cache = self._in_root("revision-cache")
        return True

    def overlay_and_build_revision(self, rev: str, overlay: list[str], build: list[str]) -> tuple[bool, str]:
        """Overlay the revision's source into the shared worktree and build the requested contracts.

        The overlay set is the WHOLE changed cascade (so a built contract's renamed dependencies
        resolve to the files they had at that revision); only the build set is compiled and later
        compared. `git restore --source` only touches working-tree files - never HEAD.
        """
        assert self.wt is not None and self.wt_out is not None and self.wt_cache is not None
        done = _git("restore", f"--source={rev}", "--worktree", "--", *overlay, cwd=self.wt)
        if done.returncode != 0:
            return False, done.stderr
        return _forge_build(self.wt_out, self.wt_cache, build, cwd=self.wt)

    def restore_overlay(self, paths: list[str]) -> None:
        """Restore overlaid paths back to the snapshot so an overlaid dependency cannot leak into a
        later revision's build. A path absent from the snapshot (a rename's old path) is removed."""
        assert self.wt is not None
        for path in paths:
            if _git("cat-file", "-e", f"{self.base}:{path}").returncode == 0:
                _git("restore", f"--source={self.base}", "--worktree", "--", path, cwd=self.wt)
            else:
                (self.wt / path).unlink(missing_ok=True)

    def cleanup(self) -> None:
        """Remove the worktree and build dirs. Idempotent.

        `git worktree remove` can fail on a submodule-populated worktree, so follow it with a
        removal and a prune to guarantee the registration is cleared. The prune needs
        `--expire=now`: a bare `git worktree prune` honours gc.worktreePruneExpire, three months by
        default, so it leaves the registration this run just made listed as prunable.
        """
        # Each submodule's registration lives in that submodule's own gitdir, so it has to be cleared
        # there. Deepest first, and before the worktree they sit inside is removed from under them.
        for repo, target in reversed(self.nested):
            _git("worktree", "remove", "--force", str(target), cwd=repo)
            _git("worktree", "prune", "--expire=now", cwd=repo)
        self.nested = []
        if self.wt is not None:
            _git("worktree", "remove", "--force", str(self.wt))
            shutil.rmtree(self.wt, ignore_errors=True)
            _git("worktree", "prune", "--expire=now")
            self.wt = None
        if self.root is not None:
            shutil.rmtree(self.root, ignore_errors=True)
            self.root = None
        self.head_out = self.head_cache = self.wt_out = self.wt_cache = None


def _in_scope(path: str, scope_dirs: list[str], deployed: set[str], rename_src: dict[str, str]) -> bool:
    """Whether a (current-tree-layout) path is within the current revision's scope.

    Either under one of the scope directories, or - mapped to its path at that revision via the
    rename map - among its deployed contracts.
    """
    for directory in scope_dirs:
        if path == directory or path.startswith(directory + "/"):
            return True
    return rename_src.get(path, path) in deployed


def _manifest_paths(manifest: str, field: str) -> list[str]:
    """Every value of `field` anywhere in the JSON document, in document order.

    The deployment manifest records a contract per entry; the field is harvested wherever it occurs
    rather than at a fixed depth, because the manifest's shape is the deploy's business, not ours.
    """
    found: list[str] = []

    def walk(node) -> None:
        if isinstance(node, dict):
            if field in node and node[field] is not None:
                value = node[field]
                found.append(value if isinstance(value, str) else json.dumps(value, separators=(",", ":")))
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    try:
        walk(json.loads(manifest))
    except json.JSONDecodeError:
        # An unparseable manifest yields no paths, which the caller reports as such.
        return []
    return found


def _parse_ignore_file() -> tuple[dict[str, str], dict[str, str]]:
    """Parse .verify-audit-ignore, keyed by the revision name as written on the command line.

    Returns (ignores, scopes). ignores[rev] is a space-separated file list, empty for a
    whole-revision ignore, and absent when the revision has no entry at all - the three states are
    distinct. scopes[rev] is the space-separated directory/manifest pathspecs the revision applies
    to; absent means all of src/.
    """
    ignores: dict[str, str] = {}
    scopes: dict[str, str] = {}
    path = Path(".verify-audit-ignore")
    if not path.is_file():
        return ignores, scopes
    for raw in path.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split(None, 1)
        rev = parts[0]
        rest = parts[1] if len(parts) > 1 else ""
        if rest.startswith("{"):  # optional scope: rev {dir1 dir2} ...
            scope, _, rest = rest[1:].partition("}")
            scopes[rev] = " ".join(scope.split())  # normalise internal whitespace
            rest = rest.lstrip()
        if not rest:
            if rev not in scopes:
                ignores[rev] = ""  # whole-revision ignore
            # else: scope-only declaration; no file ignores
        elif rev in ignores and ignores[rev] == "":
            pass  # already whole-revision; file entries don't narrow it
        else:
            ignores[rev] = f"{ignores[rev]} {rest}" if ignores.get(rev) else rest
    return ignores, scopes


def _resolve_revisions(args: list[str]) -> tuple[list[str], dict[str, str], bool]:
    """Resolve each argument to the revision it names; returns (names, name -> sha, failed).

    An argument containing a glob metacharacter is a PATTERN: it is expanded with `git tag -l`, and
    matching nothing is a legitimate answer. Anything else is an EXPLICIT name and must resolve, or
    the run fails - a typo that exits 0 reports everything is fine having compared against nothing,
    the same silent pass as a repo with no tags.

    Every name is pinned to a commit SHA here, and only the SHA is used for git operations
    afterwards. Git does not resolve an ambiguous name consistently: with a tag and a branch both
    called `x`, `git diff x` takes the tag while `git restore --source=x` takes the branch - so the
    two sides of the comparison would come from different commits and their difference would
    silently clear. The tag wins, and the collision is reported so the caller can see which was used.
    """
    failed = False
    revisions: list[str] = []
    rev_sha: dict[str, str] = {}
    for arg in args:
        if any(metacharacter in arg for metacharacter in "*?["):
            matches = _git_lines("tag", "-l", arg)
            if not matches:
                _out(f"INFO: No tags match '{arg}' (fetch first if one was cut recently: git fetch --tags)\n")
                continue
            _out(f"INFO: pattern '{arg}' matched {len(matches)} tag{'' if len(matches) == 1 else 's'}\n")
            for tag in matches:
                revisions.append(tag)
                rev_sha[tag] = _git_value("rev-parse", "--verify", "--quiet", f"refs/tags/{tag}^{{commit}}") or ""
            continue
        sha = _git_value("rev-parse", "--verify", "--quiet", f"refs/tags/{arg}^{{commit}}")
        if sha:
            if _git("show-ref", "--verify", "--quiet", f"refs/heads/{arg}").returncode == 0:
                _out(f'NOTE: "{arg}" is both a tag and a branch; using the tag\n')
        else:
            sha = _git_value("rev-parse", "--verify", "--quiet", f"{arg}^{{commit}}")
            if not sha:
                _err(f'\033[31mERROR: "{arg}" is not a tag, branch or commit in this repository\033[0m\n')
                _err("       if it is a tag this clone has not seen, run `git fetch --tags` and try again\n")
                failed = True
                continue
        revisions.append(arg)
        rev_sha[arg] = sha

    # Process revisions oldest-first: consecutive overlays then share the most source, so forge's
    # content-addressed cache rebuilds the least between them.
    if len(revisions) > 1:
        revisions.sort(key=lambda name: int(_git_value("log", "-1", "--format=%ct", rev_sha[name]) or "0"))
    return revisions, rev_sha, failed


def _resolve_scope(revision: str, sha: str, scope: str) -> tuple[list[str], set[str], bool]:
    """Resolve a revision's scope into directories and a deployed-contract set.

    A scope token of the form path.json:field is a deployment manifest read at that revision: the
    named JSON field is harvested wherever it occurs and each value is taken up to any ":" (so
    "src/X.sol:X" and "src/X.sol" both yield "src/X.sol") - the exact deployed contracts at the
    paths they had there. Other tokens are directories.
    """
    scope_dirs: list[str] = []
    deployed: set[str] = set()
    failed = False
    for token in scope.split():
        if ".json:" in token:
            manifest_path, _, field = token.rpartition(":")
            done = _git("show", f"{sha}:{manifest_path}")
            if done.returncode != 0:
                _out(f'\033[31m  ERROR: scope manifest "{manifest_path}" not found at revision "{revision}"\033[0m\n')
                failed = True
                continue
            paths = [p for p in _manifest_paths(done.stdout, field) if p]
            for contract_path in paths:
                deployed.add(contract_path.split(":", 1)[0])
            if not paths:
                _out(
                    f'\033[31m  ERROR: scope manifest "{manifest_path}" field "{field}"'
                    f' for revision "{revision}" yielded no paths\033[0m\n'
                )
                failed = True
        elif token.endswith(".json"):
            _out(
                f'\033[31m  ERROR: manifest scope "{token}" for revision "{revision}"'
                f' needs a field, e.g. "{token}:contractPath"\033[0m\n'
            )
            failed = True
        else:
            scope_dirs.append(token)
    return scope_dirs, deployed, failed


def _changed_since(sha: str) -> tuple[dict[str, str], dict[str, str], list[str]]:
    """The rename map and the changed files, from two diffs over the same pathspec.

    Returns (rename_src: new -> old, status: path -> single-letter status, changed paths in order).
    -M -l0 forces rename detection regardless of repo diff.renames config. Both diffs MUST use the
    same pathspec: they are separate git invocations, and rename detection pairs only among the
    paths that survive the pathspec, so differing specs would produce disagreeing rename maps.
    Status is captured from THIS diff, not re-queried per file: a per-file diff has no partner in
    its pathspec, so rename detection cannot run and a rename would be misreported as a deletion.
    """
    rename_src: dict[str, str] = {}
    for line in _git_lines("diff", "-M", "-l0", "--name-status", "--diff-filter=R", sha, "--", *_AUDIT_PATHSPEC):
        _status, old, new = line.split("\t")
        rename_src[new] = old

    status: dict[str, str] = {}
    changed: list[str] = []
    for line in _git_lines("diff", "-M", "-l0", "--name-status", "--diff-filter=DMRT", sha, "--", *_AUDIT_PATHSPEC):
        fields = line.split("\t")
        if fields[0].startswith("R"):
            status[fields[2]] = "R"
            changed.append(fields[2])
        else:
            status[fields[1]] = fields[0][:1]
            changed.append(fields[1])
    return rename_src, status, changed


def _print_diff(sha: str, path: str, rename_src: dict[str, str]) -> None:
    """The file's diff since the revision, truncated to 20 lines.

    A renamed file needs BOTH paths in the pathspec and -M -l0: rename detection pairs only among
    the paths that survive the pathspec, so asking for the new path alone leaves the old one out,
    git sees an addition, --diff-filter=DMRT drops it, and the entry prints bare with no diff at all.
    """
    diff_paths = [path]
    old = rename_src.get(path)
    if old and old != path:
        diff_paths = [old, path]
    done = subprocess.run(
        [
            "git",
            "diff",
            "--minimal",
            "--color=always",
            "-M",
            "-l0",
            "--diff-filter=DMRT",
            sha,
            "--",
            *diff_paths,
        ],
        capture_output=True,
        text=True,
        env={**os.environ, "GIT_PAGER": ""},
    )
    changes = done.stdout.rstrip("\n")
    lines = changes.split("\n")
    if len(lines) > 20:
        _out("\n".join(lines[:20]) + "\n")
        _out("\033[2m    ... (truncated to 20 lines)\033[0m\n")
    else:
        _out(changes + "\n")


def main() -> int:
    return _run(sys.argv[1:] or ["audit*", "deploy*"])


def _run(args: list[str]) -> int:
    # A profile selects which foundry.toml section applies - src, out, optimizer, via_ir - so
    # honouring it would audit under settings the deploy was never built with, while dropping it
    # would ignore something the caller deliberately asked for. There is no value meaning "no
    # profile", so it is refused rather than resolved either way.
    if os.environ.get("FOUNDRY_PROFILE"):
        _err(
            "\033[31mERROR: FOUNDRY_PROFILE is set"
            f' ("{os.environ["FOUNDRY_PROFILE"]}"), and it would decide which foundry.toml'
            " settings this audit compiles with\033[0m\n"
        )
        _err("       unset it and run again; the audit compiles with the default profile\n")
        return 1

    # What this tree is built from, before anything is said about what is in it. A dependency's
    # guarantees were established against ITS pins and are spent against ours - bao-base verifies
    # its sources against one OpenZeppelin while a consumer compiles them against another - so a
    # verdict below is only as good as the versions named here, and a disagreement fails the run.
    #
    # Not `yarn doctor`, which admits only checks that can never be legitimately red: this one is
    # red for as long as the fleet is unconverged, and is read at the moment someone is about to
    # deploy or audit rather than every morning.
    #
    # It STOPS the run. It ran on and reported both at first, so that one invocation would name
    # everything wrong - but in use that spends minutes compiling to produce a verdict nobody may
    # act on, and prints it under a qualification a screen further up that a reader scrolls past. A
    # tag section that says "no changes under src/" reads as a pass however it was qualified.
    # Nothing is lost by stopping: converge the versions and run it again, and both halves are
    # answerable.
    bin_dir = os.environ.get("BAO_BASE_BIN_DIR")
    if not bin_dir:
        _err("ERROR: BAO_BASE_BIN_DIR must be set by the bao-base run script\n")
        return 1
    conflicts = subprocess.run([str(Path(bin_dir) / "run-python"), "dependency-conflicts.py"]).returncode
    if conflicts != 0:
        return conflicts
    _log("every dependency shared with a repository this one depends on is staged at the same commit")

    ignores, scopes = _parse_ignore_file()

    # Refresh the tags. Whether the local tag list is stale cannot be answered locally - a tag you
    # have never seen leaves no trace - so the only way to audit against the tags that actually
    # exist is to ask the remote. It lives HERE rather than in each caller's yarn script because
    # every repo that consumes bao-base would otherwise need the same line, and they would drift;
    # here there is one definition, and a developer and CI reach it through the same command.
    #
    # Its failure is not fatal, and says so: a clone with no reachable remote can still audit the
    # tags it holds, and the per-pattern match counts below are what make a short list visible.
    if _git("fetch", "--tags", "--no-recurse-submodules").returncode != 0:
        _err("\033[33mWARNING: could not refresh the tags; auditing the tag list this clone holds\033[0m\n")

    # A shallow repository is refused rather than audited. It holds an unknown subset of the tagged
    # commits - the tag at the cloned tip is there, older ones are not - so the patterns below would
    # match only what happens to be present and the audit would report success having checked a
    # subset it never names. Nothing in the tag list distinguishes that from a genuinely complete
    # run, and the fetch above does not repair it: fetching into a shallow clone keeps it shallow.
    shallow = _git_value("rev-parse", "--is-shallow-repository")
    if shallow is None:
        _err("ERROR: could not determine whether this is a shallow repository\n")
        return 1
    if shallow == "true":
        _err(
            "ERROR: this is a shallow clone, so an unknown subset of tagged commits is absent"
            " and the audit cannot be complete\n"
        )
        _err("       fetch the full history first (in GitHub Actions: actions/checkout with fetch-depth: 0)\n")
        return 1

    # Taken once, before any revision is looked at, so a tree that cannot be snapshotted is reported
    # on its own rather than part-way through a comparison that would then mean something else.
    base = _snapshot_commit()
    if base is None:
        return 1

    builds = _Builds(base)
    try:
        return _compare_revisions(args, builds, ignores, scopes)
    finally:
        builds.cleanup()


def _compare_revisions(args: list[str], builds: _Builds, ignores: dict[str, str], scopes: dict[str, str]) -> int:
    revisions, rev_sha, fail = _resolve_revisions(args)

    for revision in revisions:
        sha = rev_sha[revision]
        _out(f"\n\033[1;36m=== {revision} ===\033[0m\n")

        scope = scopes.get(revision, "src")
        scope_dirs, deployed, scope_failed = _resolve_scope(revision, sha, scope)
        if scope_failed:
            fail = True

        # The rename map is built over all of src so it can pair renames that cross a scope
        # boundary, mapping current-tree paths back to the revision's paths for both the deployed-set
        # check and the bytecode comparison.
        rename_src, status, changed_all = _changed_since(sha)

        # The revision's path for every changed file - the cascade overlaid so a narrowly-scoped
        # contract's renamed dependencies still resolve when it builds.
        all_old = [rename_src.get(f, f) for f in changed_all]
        changed = [f for f in changed_all if _in_scope(f, scope_dirs, deployed, rename_src)]

        # Scope check + collect in-scope file ignores. A file entry outside the revision's scope can
        # never be checked, so it is an error. Done before the no-changes short-circuit so it is
        # caught even on a clean scope.
        ignore_files: list[str] = []
        if ignores.get(revision):
            for entry in ignores[revision].split():
                if _in_scope(entry, scope_dirs, deployed, rename_src):
                    ignore_files.append(entry)
                else:
                    _out(
                        f'\033[31m  ERROR: .verify-audit-ignore entry: "{entry}" for revision'
                        f' "{revision}" is outside its scope {{{scope}}} — remove it\033[0m\n'
                    )
                    fail = True

        # Whole-revision ignore
        if revision in ignores and ignores[revision] == "":
            if not changed:
                _out(
                    f'\033[31m  ERROR: stale .verify-audit-ignore entry: revision "{revision}"'
                    " has no changes — remove it\033[0m\n"
                )
                fail = True
            _out("\033[2m(ignored via .verify-audit-ignore)\033[0m\n")
            continue

        if not changed:
            _out("\033[32mno changes under src/\033[0m\n")
            continue

        # File-level ignore: check for stale entries, then filter.
        check: list[str] = []
        ignored_changed: list[str] = []  # ignored files that DID change - verified below to flag
        # any whose change would now clear (a redundant entry to remove)
        if revision in ignores:
            # reverse check: flag any ignored file that has no actual drift (ignore_files was
            # validated against the revision's scope above)
            for entry in ignore_files:
                if not any(fnmatch.fnmatchcase(f, entry) for f in changed):
                    _out(
                        f'\033[31m  ERROR: stale .verify-audit-ignore entry: "{entry}" for revision'
                        f' "{revision}" has no changes — remove it\033[0m\n'
                    )
                    fail = True
            for f in changed:
                if any(fnmatch.fnmatchcase(f, entry) for entry in ignore_files):
                    ignored_changed.append(f)
                else:
                    check.append(f)
        else:
            check = list(changed)

        # Clear files whose baseline and current versions compile to the same metadata-stripped
        # creation bytecode. Build only the changed files and their import closure, once per
        # revision; reuse one build of the current tree across revisions. A file absent from it (a
        # rename git did not pair) cannot be compiled there - it is genuine drift, reported directly
        # without a build. Ignored files that DID change are built in the same pass to flag any that
        # would now clear (a redundant entry); a deletion an entry legitimately suppresses is not
        # built.
        pair_note: dict[str, str] = {}
        if check or ignored_changed:
            residue: list[str] = []
            compare: list[str] = []
            compare_old: list[str] = []
            compare_is_ignore: list[bool] = []
            vanished: list[str] = []  # in scope, absent from the current tree: a deletion or unpaired move
            for f in check:
                if _git("cat-file", "-e", f"{builds.base}:{f}").returncode == 0:
                    compare.append(f)
                    compare_old.append(rename_src.get(f, f))
                    compare_is_ignore.append(False)
                else:
                    vanished.append(f)

            # Candidate destinations for a file git could not pair, and the other claimants on a
            # pairing git DID make. Both are files ADDED since the revision, so they are absent from
            # the DMRT diff above and have to be asked for separately. Only gathered when something
            # actually needs explaining, because every one of them has to be compiled.
            added: list[str] = []
            if vanished or any(status.get(f) == "R" for f in compare):
                for line in _git_lines(
                    "diff", "-M", "-l0", "--name-status", "--diff-filter=A", sha, "--", *_AUDIT_PATHSPEC
                ):
                    path = line.split("\t")[1]
                    if path.endswith(".sol"):
                        added.append(path)

            for f in ignored_changed:
                if _git("cat-file", "-e", f"{builds.base}:{f}").returncode == 0:
                    compare.append(f)
                    compare_old.append(rename_src.get(f, f))
                    compare_is_ignore.append(True)
                else:
                    _out(f"\033[2m  {f} (ignored via .verify-audit-ignore)\033[0m\n")

            if compare or vanished:
                if not builds.ensure_head_out():
                    return 1
                assert builds.head_out is not None and builds.head_cache is not None
                built, report = _forge_build(builds.head_out, builds.head_cache, compare + added)
                if not built:
                    _err("\033[31m  ERROR: the current tree failed to build — cannot compare bytecode\033[0m\n")
                    _err(report)
                    return 1
                if not builds.ensure_worktree():
                    _err(
                        "\033[31m  ERROR: could not set up the worktree for the current tree"
                        " — cannot compare bytecode\033[0m\n"
                    )
                    return 1
                # A vanished file is built at the revision too: its signature is the only handle on
                # where it went, since its path says nothing once it no longer exists.
                built, report = builds.overlay_and_build_revision(sha, all_old, compare_old + vanished)
                if not built:
                    # Two failures wear the same face if both are called "the build failed", and they
                    # send the reader to opposite places: sources that do not COMPILE are a problem
                    # with the revision, whereas sources that do not RESOLVE are a problem with the
                    # configuration compiling them - a remapping or dependency the current tree no
                    # longer provides. Naming the wrong one is what made this tool's own failure take
                    # an hour to place.
                    if "Unable to resolve imports" in report or "not found: File not found" in report:
                        _err(
                            f'\033[31m  ERROR: the sources at "{revision}" do not resolve in the'
                            " current tree's build environment — cannot compare bytecode\033[0m\n"
                        )
                        _err("       they import something the current configuration does not cover; forge reports:\n")
                    else:
                        _err(
                            f'\033[31m  ERROR: the sources at "{revision}" failed to compile'
                            " — cannot compare bytecode\033[0m\n"
                        )
                        _err("       forge reports:\n")
                    _err(report)
                    return 1
                assert builds.wt_out is not None

                for f, old_path, is_ignore in zip(compare, compare_old, compare_is_ignore):
                    signature_old = _file_signature(builds.wt_out, old_path)
                    signature_new = _file_signature(builds.head_out, f)
                    if signature_old == signature_new and signature_old != _MISSING:
                        # git pairs by textual similarity. Where an ADDED file compiles to the same
                        # bytecode, the pairing had more than one candidate, and clearing it would
                        # accept whichever git happened to pick - silently taking the old file's
                        # deletion with it.
                        rivals: list[str] = []
                        if status.get(f) == "R" and _signature_identifies(signature_old):
                            rivals = _signature_matches(signature_old, builds.head_out, added)
                        if rivals:
                            residue.append(f)
                            pair_note[f] = (
                                f"git paired {rename_src.get(f, '?')} here, but more than one file at"
                                f" the current tree has that bytecode ({' '.join([f, *rivals])}) — which one it"
                                " became cannot be told apart"
                            )
                        elif is_ignore:
                            _out(
                                f'\033[31m  ERROR: stale .verify-audit-ignore entry: "{f}" for revision'
                                f' "{revision}" would now clear (bytecode-equivalent) — remove it\033[0m\n'
                            )
                            fail = True
                        else:
                            _out(f"\033[2m  {f} (cleared: bytecode-equivalent)\033[0m\n")
                    else:
                        if is_ignore:
                            _out(f"\033[2m  {f} (ignored via .verify-audit-ignore)\033[0m\n")
                        else:
                            residue.append(f)

                # A file gone from the current tree. Its signature is rename-proof, so if exactly one
                # file in the tree compiles to the same bytecode, that is where it went: report it,
                # naming both paths, and clear it. Anything else is drift - no match is a removal,
                # which is what the audit exists to catch, and more than one match is a question
                # this tool must not answer by guessing.
                for f in vanished:
                    signature_old = _file_signature(builds.wt_out, f)
                    matches: list[str] = []
                    if _signature_identifies(signature_old):
                        matches = _signature_matches(signature_old, builds.head_out, added)
                    if len(matches) == 1:
                        _out(f"\033[2m  {f} -> {matches[0]} (cleared: paired by bytecode, moved or renamed)\033[0m\n")
                    else:
                        residue.append(f)
                        if len(matches) > 1:
                            pair_note[f] = (
                                f"more than one file in the current tree has this bytecode ({' '.join(matches)})"
                                " — which one it became cannot be told apart"
                            )
                builds.restore_overlay(all_old)
            check = residue

        if not check:
            _out("\033[32mno changes under src/ (ignored or cleared)\033[0m\n")
            continue

        fail = True
        _out("\033[31m  CHANGED (not ignored):\033[0m\n")
        for f in check:
            _out(f"\033[31m    {f}\033[0m\n")
            # An unresolved pairing: reported here rather than guessed at above.
            if pair_note.get(f):
                _out(f"\033[31m      {pair_note[f]}\033[0m\n")
            # A deletion's diff is the whole file as removals: it says nothing beyond the filename
            # and drowns the other entries. Report the fact instead.
            if status.get(f) == "D":
                moved = _locate_moved(sha, f)
                if moved:
                    _out(f"\033[2m      deleted since the revision; {moved}\033[0m\n")
                else:
                    _out("\033[2m      deleted since the revision (no diff shown)\033[0m\n")
                continue
            # A pairing git made by TEXTUAL SIMILARITY, whose bytecode then disagreed. Two
            # explanations fit, and no bytecode test separates them: the old file's code is absent
            # from the current tree whether it was edited or removed. So name the path that is gone and
            # readings in front of the reader rather than picking one. Without this the report shows
            # only the new path, and the removal of a deployed contract - the drift this tool exists
            # to catch - is invisible.
            if status.get(f) == "R":
                old_path = rename_src.get(f, "")
                if old_path and old_path != f:
                    _out(
                        f"\033[31m      {old_path} is GONE from the current tree; git paired it with this file,"
                        " but their bytecode differs\033[0m\n"
                    )
                    _out(
                        f"\033[2m      so either {old_path} was renamed here AND changed, or it was"
                        " removed and git\033[0m\n"
                    )
                    _out(f"\033[2m      mis-paired the deletion with {f}, which is simply new\033[0m\n")
            _print_diff(sha, f, rename_src)
        _out("\033[31mchanges under src/\033[0m\n")

    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
