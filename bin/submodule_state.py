#!/usr/bin/env python3
"""Everything that claims to say which commit a submodule is, read once and answered from.

Four independent things make that claim, and any of them can disagree with the others:

  HEAD gitlink    the commit the parent's last commit records  - what CI builds, so the truth
  index gitlink   the commit the parent has staged
  working tree    the commit the submodule is actually on      - what YOU build
  foundry.lock    forge's record of which REF that commit came from

git can write the first three and never the fourth; forge writes the fourth and the third and never
the first two. Neither tool does the whole row, and that gap is where every broken state comes from.

Two consumers read these facts and must never contradict each other:

  `condition()` names what is wrong, for bin/doctor.py to report
  `checklist()` lists what is left to do, for bin/update-submodule to converge

They are the same question asked at two moments - before touching anything, and after - so diagnosing
and verifying are one implementation rather than two that drift.

Everything here is READ-ONLY. Nothing in this module writes to a repository.
"""

from __future__ import annotations

import json
import subprocess
from collections.abc import Iterator, Sequence
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath

# The pin kinds foundry.lock records, and what each means for a bare `yarn update <dep>`.
# A branch is the only one that can move on its own, so it is the only one that resolves without
# the user naming a ref.
MOVING = "branch"
STATIONARY = ("tag", "rev")


def git(where: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    """Run git and hand back the result. Never raises: a non-zero return is usually an answer here
    (no such ref, not a submodule, no remote), and the caller knows which."""
    return subprocess.run(["git", *arguments], cwd=where, capture_output=True, text=True)


@dataclass(frozen=True)
class Pin:
    """What foundry.lock records for one dependency.

    `kind` is 'tag', 'branch' or 'rev' when the lock names it, 'unpinned' when the parent keeps a
    foundry.lock that does not mention it, and 'unmanaged' when the parent keeps no lock at all. The
    last two look identical in the data and mean opposite things: a foundry project that forgot to
    pin a dependency has a real gap, while a third-party repository that never used forge has none.
    """

    kind: str
    name: str | None
    rev: str | None

    @property
    def moving(self) -> bool:
        """A branch pin follows its remote; a tag or commit does not. This is what decides whether a
        bare `yarn update <dep>` has a ref to resolve or must ask for one."""
        return self.kind == MOVING


@dataclass(frozen=True)
class AtRisk:
    """One thing that exists here and on no remote, so nothing could restore it.

    `kind` is 'modified', 'unpushed' or 'untracked'. What it is called elsewhere - the developer's
    work, a dependency's nested submodule, litter - is irrelevant here: those describe OWNERSHIP,
    which says nothing about whether losing it matters. Recoverability is the only safe criterion,
    and this is the only thing that measures it.

    MOVING a dependency does not delete any of this: git preserves untracked and gitignored files
    across a checkout and refuses outright rather than overwrite a modified one, so its refusal is a
    backstop behind this one. The clean-up of stranded directories DOES delete, which is the step
    this measure actually guards - a stranded checkout that is pristine is swept, and one holding a
    commit no remote has is not.
    """

    path: str
    kind: str
    detail: str


def at_risk(repo_dir: Path, display: str = "") -> list[AtRisk]:
    """Everything under `repo_dir` that exists nowhere but here, at any depth.

    Three shapes, and a tree is unsafe to delete if it holds any of them:
      modified   a tracked file changed and not committed
      unpushed   a commit no remote has - committing inside a submodule is not backup, only pushing is
      untracked  a file no repository is tracking, so nothing can restore it

    It descends through registered submodules AND through untracked directories that are themselves
    repositories, because a `+` in `git submodule status` and an untracked directory holding a `.git`
    are each produced by two situations that look identical and mean opposite things: a version bump
    nobody recursed, or a day of your work. Only looking inside tells them apart.

    `--ignore-submodules=all` keeps a child's state out of its parent's listing, so each is reported
    once, at its own path.
    """
    found: list[AtRisk] = []

    status = git(repo_dir, "status", "--porcelain", "--untracked-files=all", "--ignore-submodules=all")
    for line in status.stdout.splitlines():
        if not line:
            continue
        code, entry = line[:2], line[3:].strip().strip('"')
        if code == "??":
            bare = entry.rstrip("/")
            if (repo_dir / bare / ".git").exists():
                found.extend(at_risk(repo_dir / bare, f"{display}{bare}/"))
            else:
                found.append(AtRisk(f"{display}{entry}", "untracked", "no repository is tracking it"))
        else:
            found.append(AtRisk(f"{display}{entry}", "modified", f"changed ({code.strip()}) and not committed"))

    for line in git(repo_dir, "log", "--oneline", "HEAD", "--not", "--remotes").stdout.splitlines():
        found.append(AtRisk(display.rstrip("/") or ".", "unpushed", line))

    listing = git(repo_dir, "config", "-f", ".gitmodules", "--get-regexp", r"^submodule\..*\.path$")
    for line in listing.stdout.splitlines():
        name = line.partition(" ")[2].strip()
        if name and (repo_dir / name / ".git").exists():
            found.extend(at_risk(repo_dir / name, f"{display}{name}/"))

    return found


@dataclass(frozen=True)
class Facts:
    """Every claim about one submodule, gathered in a single read.

    `worktree` is None when the submodule is not checked out, and ALSO when it is checked out but git
    will not read it - `unreadable` is what separates those two, carrying git's own refusal. `edits`
    counts only the developer's own file changes - it is read with --ignore-submodules=all, because a
    submodule's plain status also reports its NESTED submodules being off their pins, and conflating
    the two is what makes a tool tell you to commit and push a repository you do not own.
    """

    path: str
    directory: Path
    lock: Pin
    # This dependency's foundry.lock entry as the index and HEAD record it - None where they record
    # none - read beside the gitlinks they record, because writing the entry is part of every move.
    index_lock: Pin | None
    head_lock: Pin | None
    head_gitlink: str | None
    index_gitlink: str | None
    worktree: str | None
    origin_url: str | None
    gitmodules_url: str | None
    remote_tip: str | None
    worktree_ref: str | None = None
    # Git's refusal, when the checkout is present but cannot be read. None whenever git answered -
    # including for a checkout that is genuinely absent, which is a different fault with a different
    # repair.
    unreadable: str | None = None
    edits: list[str] = field(default_factory=list)
    unpushed: list[str] = field(default_factory=list)
    nested_drift: list[str] = field(default_factory=list)
    litter: list[str] = field(default_factory=list)
    at_risk: list[AtRisk] = field(default_factory=list)

    @property
    def initialised(self) -> bool:
        return self.worktree is not None

    @property
    def has_own_work(self) -> bool:
        """Whether anything under this submodule exists nowhere else - measured over the whole
        subtree, since a nested submodule's commits and an untracked repository's commits are just as
        irreplaceable as this one's, and look like drift and litter from up here."""
        return bool(self.at_risk)


class UnreadableLock(Exception):
    """foundry.lock exists and will not parse. Raised rather than read as an absence, because the two
    mean opposite things: a project with NO lock pins nothing, which is exactly true of a repository
    that never used forge, while a lock somebody wrote and that cannot be read is a defect in the
    file - and answering {} for it makes every check downstream agree the tree is in order."""


def read_lock(repo_root: Path) -> dict[str, Pin]:
    """foundry.lock as {path: Pin}. An ABSENT lock yields {} - nothing is pinned, which is an answer.
    One that exists and will not parse raises `UnreadableLock` for the caller to report."""
    lock_file = repo_root / "foundry.lock"
    if not lock_file.is_file():
        return {}
    return _parse_lock(lock_file.read_text(), str(lock_file))


def _recorded_lock(repo_root: Path, revision: str) -> dict[str, Pin]:
    """foundry.lock as `revision` records it - "HEAD", or "" for the index - read as `read_lock` reads
    the working tree's. A failed read is an absence, as it is for `head_gitlink`: no foundry.lock
    recorded there, or no HEAD yet."""
    shown = git(repo_root, "show", f"{revision}:foundry.lock")
    if shown.returncode != 0:
        return {}
    return _parse_lock(shown.stdout, f"foundry.lock in {revision or 'the index'}")


def _parse_lock(text: str, source: str) -> dict[str, Pin]:
    try:
        raw = json.loads(text)
    except json.JSONDecodeError as broken:
        raise UnreadableLock(f"{source} does not parse: {broken}") from broken
    pins: dict[str, Pin] = {}
    for path, entry in raw.items():
        for kind in ("tag", "branch"):
            if kind in entry:
                pins[path] = Pin(kind, entry[kind].get("name"), entry[kind].get("rev"))
                break
        else:
            pins[path] = Pin("rev", None, entry.get("rev"))
    return pins


def submodules(repo_dir: Path, prefix: str = "") -> list[tuple[Path, str, str]]:
    """Every submodule in the tree, at any depth, as (its parent repository, its path within that
    parent, its path from the top).

    Read from .gitmodules rather than foundry.lock: the lock is forge's record and need not mention
    every submodule, and a submodule missing from it is exactly the kind that goes unnoticed.
    .gitmodules also still lists one that is not checked out, which `git submodule status` reports
    but a filesystem walk would miss entirely.

    Recursion is what makes depth work everywhere else: each nested submodule is read in its own
    right, against its own parent, so litter and uninitialised checkouts are found at any level
    without any function having to recurse on its own.
    """
    found: list[tuple[Path, str, str]] = []
    listing = git(repo_dir, "config", "-f", ".gitmodules", "--get-regexp", r"^submodule\..*\.path$")
    for line in listing.stdout.splitlines():
        name = line.partition(" ")[2].strip()
        if not name:
            continue
        found.append((repo_dir, name, f"{prefix}{name}"))
        nested = repo_dir / name
        if (nested / ".git").exists():
            found.extend(submodules(nested, prefix=f"{prefix}{name}/"))
    return found


@dataclass(frozen=True)
class Pinned:
    """What one repository stages for a dependency: the commit, and enough about it to choose.

    `described` is the nearest tag and `when` the commit date, because several dependencies are pinned
    by bare commit - `lib/bao-factory` carries no tag at all - and a pair of hashes says nothing about
    which is ahead. The date does, and choosing is the reader's."""

    commit: str | None
    described: str | None
    when: str | None


@dataclass(frozen=True)
class Mismatch:
    """One dependency that this repository and a dependency of ours each stage at a different commit.

    `at` is where that other repository sits, so the fix is a `cd` away. Which SIDE moves is not the
    tool's to decide: the newer pin is sometimes ours and sometimes theirs, and only the reader knows
    whether they are catching up or waiting."""

    dependency: str
    at: str
    ours: Pinned
    theirs: Pinned
    relation: str | None


def _owner(url: str) -> str:
    """The segment before the repository name - `baofinance` in `github.com/baofinance/bao-base`.

    Read positionally rather than by host, so a file path stands in for a URL unchanged. That is what
    lets the tests build a tree without a forge, and what keeps a mirror or a fork readable."""
    parts = [part for part in url.rstrip("/").removesuffix(".git").replace(":", "/").split("/") if part]
    return parts[-2] if len(parts) >= 2 else ""


def _identity(url: str) -> str:
    """A dependency's identity is its URL, not its directory name: two dependencies can be checked out
    under one name, and one dependency under two.

    Normalised so that nothing which is merely how a URL was written can split a dependency from
    itself - the scheme, an ssh user, `:` against `/` as the host separator, a trailing `.git`. The
    two spellings of one GitHub repository both land on `github.com/owner/name`."""
    text = url.rstrip("/").removesuffix(".git")
    text = text.split("://", 1)[-1]
    text = text.split("@", 1)[-1]
    return "/".join(part for part in text.replace(":", "/").split("/") if part).lower()


def _declared(repo_dir: Path) -> list[tuple[str, str]]:
    """Every submodule this repository declares, as (path within it, url)."""
    listing = git(repo_dir, "config", "-f", ".gitmodules", "--get-regexp", r"^submodule\..*\.(path|url)$")
    fields: dict[str, dict[str, str]] = {}
    for line in listing.stdout.splitlines():
        key, _, value = line.partition(" ")
        name, _, field = key.removeprefix("submodule.").rpartition(".")
        if name and field in ("path", "url"):
            fields.setdefault(name, {})[field] = value.strip()
    return [(entry["path"], entry["url"]) for entry in fields.values() if "path" in entry and "url" in entry]


class UnreadableGitmodules(Exception):
    """A `.gitmodules` exists and git will not read it. Raised rather than read as declaring nothing, for
    the reason `UnreadableLock` gives: the two mean opposite things, and reading the defect as the absence
    makes every check over the dependencies agree that there is nothing wrong."""


@dataclass(frozen=True)
class Declared:
    """One submodule as a `.gitmodules` declares it. `branch` is the branch it follows, when it names one."""

    name: str
    path: str
    url: str | None
    branch: str | None


def declared_submodules(repo_dir: Path, revision: str | None = None) -> list[Declared]:
    """Every submodule a `.gitmodules` in `repo_dir` declares, in the order it lists them: the working
    tree's, or the one `revision` records - "HEAD", or "" for the index.

    No `.gitmodules` declares nothing. One git will not read raises `UnreadableGitmodules` in git's words.
    Read NUL-separated, because a submodule's name is free text and may hold a space."""
    if revision is None:
        if not (repo_dir / ".gitmodules").is_file():
            return []
        source, named = ["-f", ".gitmodules"], str(repo_dir / ".gitmodules")
    else:
        recorded = f"{revision}:.gitmodules"
        # quiet and non-zero exactly when no such object exists: none recorded there, or no HEAD yet
        if git(repo_dir, "rev-parse", "--verify", "--quiet", recorded).returncode != 0:
            return []
        source, named = ["--blob", recorded], f".gitmodules in {revision or 'the index'}"
    listing = git(repo_dir, "config", "-z", *source, "--get-regexp", r"^submodule\..*\.(path|url|branch)$")
    # git's answer for "no key matches" is exit 1 with nothing said - a file holding only comments gives it
    if listing.returncode == 1 and not listing.stderr.strip():
        return []
    if listing.returncode != 0:
        raise UnreadableGitmodules(f"{named}: {listing.stderr.strip()}")
    fields: dict[str, dict[str, str]] = {}
    for item in listing.stdout.split("\0"):
        if not item:
            continue
        key, _, value = item.partition("\n")
        name, _, field_name = key.removeprefix("submodule.").rpartition(".")
        fields.setdefault(name, {})[field_name] = value
    return [
        Declared(name, entry["path"], entry.get("url"), entry.get("branch"))
        for name, entry in fields.items()
        if "path" in entry
    ]


def remapping_target(remapping: str) -> str:
    """The path a remapping sends imports to, relative to the project. A remapping is
    `[context:]prefix=target`, and the context sits before the `=`, so the target is everything after it."""
    return remapping.partition("=")[2].rstrip("/")


def submodule_levels(repo_root: Path, path: str) -> Iterator[tuple[Path, Declared]]:
    """The submodules `path` (relative to `repo_root`) lies inside, outermost first, each with the directory
    that declares it.

    Lazy on purpose. Each level's `.gitmodules` is in that level's own checkout, so it is read only when the
    walk reaches it: a caller can check a level out before the next one is read, and a level that is not
    checked out declares nothing, which ends the walk there."""
    directory, remainder = repo_root, PurePosixPath(path)
    while (
        level := next((entry for entry in declared_submodules(directory) if remainder.is_relative_to(entry.path)), None)
    ) is not None:
        yield directory, level
        directory, remainder = directory / level.path, remainder.relative_to(level.path)


def nested_levels(repo_root: Path, path: str, remappings: list[str]) -> Iterator[tuple[Path, Declared]]:
    """The submodules beneath the dependency at `path` that remappings reach - the nested paths the build
    reads from it - each with the directory declaring it, outermost first for each remapping. Lazy, as
    `submodule_levels` is, so a caller can check each one out before the next is read."""
    for remapping in remappings:
        levels = submodule_levels(repo_root, remapping_target(remapping))
        first = next(levels, None)
        if first is not None and first[1].path == path:
            yield from levels


@dataclass(frozen=True)
class Recorded:
    """One dependency's `.gitmodules` entry as the working tree, the index and HEAD hold it - None where that
    version declares no submodule at its path."""

    working: Declared | None
    staged: Declared | None
    committed: Declared | None


def recorded_entry(repo_root: Path, path: str) -> Recorded:
    entries = [
        next((entry for entry in declared_submodules(repo_root, revision) if entry.path == path), None)
        for revision in (None, "", "HEAD")
    ]
    return Recorded(*entries)


def staged_gitlink(repo_dir: Path, path: str) -> str | None:
    """The commit a repository STAGES for a submodule.

    The index rather than HEAD, following `ratchet.resolve`: what is staged is what you mean to depend
    on, and a bump on its way to a commit should read as the bump. Whether the index, HEAD and the
    checkout agree is a separate question, and `condition()` already answers it - this must not
    re-litigate it, or one fact grows two verdicts again."""
    fields = git(repo_dir, "ls-files", "-s", path).stdout.split()
    return fields[1] if len(fields) > 1 else None


def checked_out(checkout: Path) -> str | None:
    """The commit a checkout is on, or None when there is no checkout git can read."""
    if not (checkout / ".git").exists():
        return None
    head = git(checkout, "rev-parse", "HEAD")
    return head.stdout.strip() if head.returncode == 0 else None


def at_record(directory: Path, level: Declared) -> bool:
    """Whether the submodule `directory` declares is checked out at the commit `directory` records."""
    have = checked_out(directory / level.path)
    return have is not None and have == staged_gitlink(directory, level.path)


def _about(commit: str | None, checkouts: list[Path]) -> Pinned:
    """Describe `commit` from whichever checkout holds the object.

    More than one is tried because a repository that has not fetched lately may not hold the commit
    another one stages, and every checkout of a dependency is a clone of the same upstream."""
    if commit is None:
        return Pinned(None, None, None)
    for checkout in checkouts:
        if not (checkout / ".git").exists():
            continue
        when = git(checkout, "show", "-s", "--format=%cI", commit).stdout.strip()
        if not when:
            continue
        described = git(checkout, "describe", "--tags", commit).stdout.strip()
        return Pinned(commit, described or None, when)
    return Pinned(commit, None, None)


def _relation(ours: str | None, theirs: str | None, checkouts: list[Path]) -> str | None:
    """Which pin is later, read from the graph rather than from a clock.

    Ancestry is the only structural answer - a rebase rewrites dates, a cherry-pick invents them - so
    it is asked first and its verdict stands. It cannot always answer, and the two ways it fails must
    stay apart:

      `diverged`             a common ancestor exists and neither pin reaches the other. Real, and
                             worth alarm.
      `unrelated histories`  no common ancestor at all. Ordinary for a generated repository -
                             openzeppelin-contracts-upgradeable is transpiled per release, so v5.6.1
                             and v5.7.0 share no commit - and reporting THAT as divergence would
                             alarm about every OpenZeppelin version gap there is.

    Both commits must be in one object store; a checkout that has not fetched holds only its own, and
    a read-only reader must not fetch to fill the gap. Each checkout of the dependency is tried, and
    `None` means none of them could answer - which is when the tag and the date have to carry it.
    """
    if not ours or not theirs:
        return None
    for checkout in checkouts:
        if not (checkout / ".git").exists():
            continue
        if any(git(checkout, "cat-file", "-e", commit).returncode != 0 for commit in (ours, theirs)):
            continue
        if git(checkout, "merge-base", "--is-ancestor", theirs, ours).returncode == 0:
            return "ours is later"
        if git(checkout, "merge-base", "--is-ancestor", ours, theirs).returncode == 0:
            return "theirs is later"
        return "diverged" if git(checkout, "merge-base", ours, theirs).stdout.strip() else "unrelated histories"
    return None


def _shares_our_toolchain(repo_dir: Path, path: str, url: str, toolchain: str) -> bool:
    """Whether a dependency shares bao-base with us, and so has to agree with us about versions.

    Not because bao-base dictates them - a version moves wherever it is first needed, and reaches the
    others by way of bao-base afterwards. Sharing bao-base is what makes two repositories subject to
    the same move, whichever of them starts it. Taking it as a submodule is what that looks like, so it
    is what this reads: no configuration, and a new sibling joins the day it adopts bao-base. bao-base
    itself counts without depending on itself, the one case the rule has to name outright.

    A repository standing alone is deliberately out: bao-factory pins its own solady and forge-std, is
    consumed without inheriting ours, and has no reason to move when we do. Requiring it to agree would
    report a disagreement neither side is wrong about."""
    if _identity(url).rsplit("/", 1)[-1] == toolchain:
        return True
    return any(_identity(u).rsplit("/", 1)[-1] == toolchain for _, u in _declared(repo_dir / path))


def conflicting_dependencies(repo_root: Path, owner: str | None = None, toolchain: str = "bao-base") -> list[Mismatch]:
    """Dependencies this repository and a dependency of OURS each stage at a different commit.

    Only DIRECT against DIRECT, and only against submodules we own. That is what makes every finding
    the same thing as its repair: a mismatch here is one `yarn update` away, in this repository, by
    whoever is reading. A disagreement further down - bao-factory's forge-std beneath bao-base - is
    real but is not ours to settle, and bao-base's own run reports it where it can be fixed. The check
    decomposes across repositories rather than one run policing a whole tree, and nothing is lost.

    Scope is the whole difficulty. A tree can hold sixteen checkouts of forge-std at seven versions,
    most pinned by OpenZeppelin and openzeppelin-foundry-upgrades; requiring those to agree would be
    permanently red and unfixable, which is the failure this module exists to remove. `owner` names
    who counts as ours, defaulting to whoever owns this repository, so nothing needs configuring and a
    sibling is included without being listed.

    What a mismatch costs, when it is one: a dependency's guarantees are established against its OWN
    pins and spent against ours - bao-base verifies its sources against one OpenZeppelin while we
    compile them against another - and a config copied between repositories assumes a version we may
    not have.
    """
    if owner is None:
        origin = git(repo_root, "config", "--get", "remote.origin.url").stdout.strip()
        owner = _owner(origin) if origin else ""

    ours = {_identity(url): path for path, url in _declared(repo_root)}
    found: list[Mismatch] = []
    for path, url in _declared(repo_root):
        if _owner(url) != owner or not (repo_root / path / ".git").exists():
            continue
        if not _shares_our_toolchain(repo_root, path, url, toolchain):
            continue
        for their_path, their_url in _declared(repo_root / path):
            identity = _identity(their_url)
            our_path = ours.get(identity)
            if our_path is None:
                continue
            our_commit = staged_gitlink(repo_root, our_path)
            their_commit = staged_gitlink(repo_root / path, their_path)
            if our_commit == their_commit:
                continue
            checkouts = [repo_root / our_path, repo_root / path / their_path]
            found.append(
                Mismatch(
                    dependency=identity.rsplit("/", 1)[-1],
                    at=path,
                    ours=_about(our_commit, checkouts),
                    theirs=_about(their_commit, list(reversed(checkouts))),
                    relation=_relation(our_commit, their_commit, checkouts),
                )
            )
    return found


def stray_clones(repo_root: Path) -> list[str]:
    """Git repositories sitting untracked in OUR OWN tree - a `forge install` or clone run in the
    wrong directory. Distinct from the litter inside a dependency: this is ours to delete, and its
    contents are invisible to everyone else because nothing tracks them.

    Only the top repository, since anything inside a submodule is that dependency's own and is
    reported as its litter instead."""
    status = git(repo_root, "status", "--porcelain", "--untracked-files=all")
    found: list[str] = []
    for line in status.stdout.splitlines():
        if line.startswith("?? "):
            entry = line[3:].strip().strip('"').rstrip("/")
            if (repo_root / entry / ".git").exists():
                found.append(entry)
    return found


def read_facts(repo_root: Path, path: str, pin: Pin | None = None, display: str | None = None) -> Facts:
    """Gather every claim about the submodule at `path`, which is relative to `repo_root` - its
    IMMEDIATE parent, so a nested submodule is read against the repository that records its gitlink
    and pins it. `display` is how to name it from the top of the tree.

    `pin` saves re-reading foundry.lock when the caller already has it."""
    if pin is None:
        managed = (repo_root / "foundry.lock").is_file()
        pin = read_lock(repo_root).get(path, Pin("unpinned" if managed else "unmanaged", None, None))
    submodule = repo_root / path

    head = git(repo_root, "rev-parse", f"HEAD:{path}")
    staged = git(repo_root, "ls-files", "-s", path).stdout.split()
    checked_out = git(submodule, "rev-parse", "HEAD") if (submodule / ".git").exists() else None

    # A `.git` that is there but that git will not read is a different fault from a checkout that is
    # not there, and every reading below is gated on which. `checked_out` alone cannot carry that:
    # a CompletedProcess is truthy whether or not the command worked, so gating on it ran a further
    # dozen git calls that could only fail too, and a failed read then arrived indistinguishable from
    # an absent one.
    readable = checked_out is not None and checked_out.returncode == 0
    refusal = checked_out.stderr.strip().splitlines() if checked_out is not None and not readable else []

    origin = git(submodule, "remote", "get-url", "origin") if readable else None
    declared = git(repo_root, "config", "-f", ".gitmodules", "--get", f"submodule.{path}.url")

    # The branch tip as of the last fetch. Read from the remote-tracking ref rather than the network:
    # doctor must not reach out, and "behind as of your last fetch" is the honest claim either way.
    tip = git(submodule, "rev-parse", f"origin/{pin.name}") if readable and pin.moving else None

    # The tag the checked-out commit IS, when it is one. This is what makes a disagreement
    # answerable: the GUI checks a tag out by name, so its bump leaves the intended version readable
    # here. forge checks out a branch, whose tip need not be tagged, so after a forge run this is
    # often None and the user has to say what they meant.
    named = git(submodule, "describe", "--tags", "--exact-match", "HEAD") if readable else None

    return Facts(
        path=display or path,
        directory=submodule,
        lock=pin,
        index_lock=_recorded_lock(repo_root, "").get(path),
        head_lock=_recorded_lock(repo_root, "HEAD").get(path),
        head_gitlink=head.stdout.strip() if head.returncode == 0 else None,
        index_gitlink=staged[1] if len(staged) > 1 else None,
        worktree=checked_out.stdout.strip() if readable else None,
        origin_url=origin.stdout.strip() if origin and origin.returncode == 0 else None,
        gitmodules_url=declared.stdout.strip() if declared.returncode == 0 else None,
        remote_tip=tip.stdout.strip() if tip and tip.returncode == 0 else None,
        worktree_ref=named.stdout.strip() if named and named.returncode == 0 else None,
        # The first line only: git puts what it could not do there, and repeats itself afterwards
        # about which command it gave up on, which the reader already knows.
        unreadable=refusal[0] if refusal else None,
        edits=_edits(submodule) if readable else [],
        unpushed=_unpushed(submodule) if readable else [],
        nested_drift=_nested_drift(submodule) if readable else [],
        litter=_litter(submodule) if readable else [],
        at_risk=at_risk(submodule) if readable else [],
    )


def _edits(submodule: Path) -> list[str]:
    """The developer's own modifications to tracked files. --ignore-submodules=all is what separates
    these from this dependency's nested submodules being off their pins: the first cannot be
    recovered, the second is fixed by recursing and is not the developer's work at all."""
    status = git(submodule, "status", "--porcelain", "--ignore-submodules=all")
    return [line for line in status.stdout.splitlines() if line and not line.startswith("??")]


def _unpushed(submodule: Path) -> list[str]:
    """Commits no remote holds. Committing inside a submodule is not safety - only pushing is - so
    these live in one clone, and every other checkout is missing what the gitlink names."""
    log = git(submodule, "log", "--oneline", "HEAD", "--not", "--remotes")
    return log.stdout.splitlines() if log.returncode == 0 else []


def _nested_drift(submodule: Path) -> list[str]:
    """This dependency's own submodules that are not at the commit it records for them, at any depth.
    Not the developer's doing, and not fixed by committing anything - only by recursing."""
    status = git(submodule, "submodule", "status", "--recursive")
    return [line[1:].strip() for line in status.stdout.splitlines() if line[:1] in ("+", "-", "U")]


def _litter(submodule: Path) -> list[str]:
    """Directories inside this dependency that are git repositories nothing tracks - what is left when
    a version stops declaring a submodule and git cannot delete the populated directory ("unable to
    rmdir"). It belongs to the dependency, not to us, so it must never be reported as work to commit.
    --untracked-files=all lists a nested one individually instead of collapsing it onto its parent."""
    status = git(submodule, "status", "--porcelain", "--untracked-files=all")
    found: list[str] = []
    for line in status.stdout.splitlines():
        if line.startswith("?? "):
            entry = line[3:].strip().strip('"').rstrip("/")
            if (submodule / entry / ".git").exists():
                found.append(entry)
    return found


@dataclass(frozen=True)
class Condition:
    """What is wrong with one submodule, named. The facts behind the name never speculate about how
    the state arose: a checkout ahead of its record looks identical whether someone moved it on purpose
    or a run stopped half-way, so claiming either would be invention.

    They arrive as `detail` OR as `rows`, never both - one representation per condition, so a sentence
    and a table cannot drift apart. `rows` is for the conditions that COMPARE the checkout with its
    record, where the two commits side by side are what a reader acts on; every other condition is a
    single fact and says it in words. `relation` says how the two commits relate when neither leads to
    the other, which the name alone cannot."""

    name: str
    detail: str
    relation: str | None = None
    # Cells for `columns.rows`, laid out by whoever renders them - the alignment is not this module's
    # business, and neither is the indent it will sit under.
    rows: tuple[tuple[str, ...], ...] = ()

    # What a READER is told. `name` stays the identifier this module and its tests branch on, but it
    # is shorthand for whoever wrote it - "litter-present" describes a data structure, not a thing
    # that happened to your checkout. Anything a person sees says what is wrong in plain words, one fact
    # at a time, naming the repository rather than using git's internal terms for where it points.
    SUMMARIES = {
        "uninitialised": "is in .gitmodules, but nothing is checked out in its folder",
        "unreadable": "has a folder that git cannot read",
        "litter-present": "contains old git repositories that nothing uses",
        "nested-drift": "contains a submodule that a remapping uses, at a different commit than it points to",
        "behind-record": "the folder has an older commit than the one {repository} points to",
        "ahead-of-record": "the folder has a newer commit than the one {repository} points to",
        "off-record": "the folder has a different commit from the one {repository} points to",
        "consistent": "the folder has the commit {repository} points to",
    }
    # How the two commits of an `off-record` relate, in the same plain words.
    RELATIONS = {
        "diverged": "Each of the two commits has history that the other does not have.",
        "unrelated histories": "The two commits have no history in common.",
        "not comparable": "Git cannot tell which is newer, because the folder does not have both commits.",
    }

    def describe(self, repository: str) -> str:
        return self.SUMMARIES.get(self.name, self.name).format(repository=repository)

    @property
    def is_fault(self) -> bool:
        """Whether doctor should report it: anything but agreement. Work in progress inside a dependency
        is not among the conditions at all - see `condition`. Doctor grades what has been DONE, and
        unfinished work is not a defect."""
        return self.name != "consistent"


def litter_condition(facts: Facts) -> Condition | None:
    """Directories a version change stranded, or None. ORTHOGONAL to everything else that can be wrong
    with a dependency: a checkout can be at the wrong version AND have leftovers, and they are fixed
    by different commands.

    So it is read on its own as well as through `condition`, which can only ever name one thing and
    ranks a version disagreement above this. Reading it separately is what lets a reader be told about
    leftovers that a more urgent fault would otherwise have buried - and it is why doctor's leftovers
    check cannot be built from `condition` alone, which would have it report all-clear while the
    version finding beside it named a stranded directory."""
    if not facts.litter:
        return None
    return Condition("litter-present", "old git repositories: " + ", ".join(facts.litter))


def condition(facts: Facts, nested_off: Sequence[str] = ()) -> Condition:
    """Name what is wrong with one of this repository's own dependencies, most fundamental first: a
    submodule that is not checked out has no other meaningful state.

    `nested_off` is each remapped nested path beneath it that is not at its record. Those are the only
    nested submodules the build reads, so they are the only ones that count; the dependency's others are
    its own lockfile, whatever state they are in."""
    # Ahead of `uninitialised`, which it would otherwise be read as: both leave `worktree` unset, and
    # only this one means the checkout is sitting right there. Git's own words are the detail, per
    # "error messages report facts, not assumptions" - a dangling core.worktree, a gitdir that was
    # moved and a corrupt object store all arrive here, and naming one of them would be a guess.
    if facts.unreadable:
        return Condition("unreadable", facts.unreadable)
    if not facts.initialised:
        return Condition("uninitialised", "the folder is empty")

    # `at_risk` is deliberately NOT a condition. It answers "would this be destroyed", which is what
    # guards `yarn update`'s deleting steps and must stay as wide as it is - `has_own_work` still
    # carries it, unchanged. It does not answer "is this wrong", which is what doctor reports, and
    # having work in progress inside a dependency is not wrong: it is what working in one looks like,
    # and saying so every run says only that you have not finished yet.
    #
    # Removed here rather than merely excluded from `is_fault`, because it was returned AHEAD of the
    # version comparison below - so a dependency being edited announced "holds work that exists nowhere
    # else" and buried a real lock disagreement under it as an afterthought.

    # URL drift is deliberately NOT named here. doctor owns it in its own check, which compares
    # .git/config (what `git submodule update` actually reads) rather than the submodule's `origin`.
    # Two checks reporting one fault in two vocabularies is the thing this module exists to stop, so
    # there is exactly one owner.

    # HEAD is deliberately absent. doctor is what you run BEFORE committing, so a check that withholds
    # a pass until you commit demands the very thing it exists to prepare you for - and HEAD lagging is
    # only "not committed yet", which is what all work in progress looks like. What it judges is the
    # checkout against what you have STAGED: the same index-is-the-baseline rule as `ratchet.resolve`
    # and the dependency-version check. foundry.lock is not read at all.
    if facts.worktree != facts.index_gitlink:
        # The two commits side by side, the commit first because its width is fixed.
        rows = (((facts.worktree or "")[:10], "working tree"), ((facts.index_gitlink or "absent")[:10], "index"))
        # Which is later decides the repair - a checkout behind its record is stale and goes forward to
        # it, one ahead is a move not yet recorded - and only the graph can say which.
        relation = _relation(facts.worktree, facts.index_gitlink, [facts.directory])
        if relation == "ours is later":
            return Condition("ahead-of-record", "", None, rows)
        if relation == "theirs is later":
            return Condition("behind-record", "", None, rows)
        return Condition(
            "off-record",
            "",
            relation or "not comparable",
            rows,
        )

    # No branch for unpushed commits: `at_risk` above already collects them, running the same
    # `git log HEAD --not --remotes`, so anything this could match has returned already. One measure
    # of what exists nowhere else, not two.

    if leftovers := litter_condition(facts):
        return leftovers

    if nested_off:
        return Condition("nested-drift", "at a different commit: " + ", ".join(nested_off))

    return Condition("consistent", f"agrees on {(facts.worktree or '')[:10]}")


@dataclass(frozen=True)
class Stage:
    """One item of the checklist `yarn update` converges: whether it is already done, and the action
    that would complete it. An action is a command to run or an instruction to give - stages the user
    must perform themselves (staging, committing) complete by being printed."""

    number: int
    name: str
    done: bool
    detail: str
    action: str


def checklist(facts: Facts, target_ref: str | None, target_rev: str | None) -> list[Stage]:
    """What is left to do to bring `facts` to `target_ref` (whose commit is `target_rev`).

    The caller resolves the ref, because resolving may need a fetch and this module never reaches the
    network. `target_ref` of None means the caller could not resolve one, which is itself a stage-1
    failure rather than an error here.
    """
    safe = not facts.has_own_work
    # Named individually rather than counted: the point of stopping is that only the user can say
    # whether a given thing is a day's work or a stray file, and they cannot judge a number.
    listed = "; ".join(f"{item.path} ({item.kind}: {item.detail})" for item in facts.at_risk[:8])
    if len(facts.at_risk) > 8:
        listed += f"; and {len(facts.at_risk) - 8} more"
    # The move is the gitlink AND this dependency's lock entry, which stage 5 writes: staging or
    # committing the gitlink alone records a pin and a lock that disagree. The working tree's entry is
    # put in the terms the index's and HEAD's are read in - None where there is none, for either of
    # the two reasons `Pin` keeps apart - and only this entry is compared, never the whole file, whose
    # other entries belong to other dependencies' moves.
    entry = facts.lock if facts.lock.kind not in ("unpinned", "unmanaged") else None
    lock_staged = facts.index_lock == entry
    lock_committed = facts.head_lock == entry
    unstaged = [facts.path] if facts.index_gitlink != facts.worktree else []
    if not lock_staged:
        unstaged.append("foundry.lock")
    return [
        Stage(
            0,
            "nothing here exists only here",
            safe,
            "no remote is missing anything under this dependency" if safe else f"exists only here: {listed}",
            ""
            if safe
            else "commit and push what matters, then run this again - or repeat it with --force to move anyway",
        ),
        Stage(
            1,
            "a ref to move to",
            target_ref is not None,
            f"{target_ref}" if target_ref else f"{facts.lock.kind} pin cannot resolve itself",
            "" if target_ref else f"name one: `yarn update {facts.path}@<ref>`",
        ),
        Stage(
            2,
            "working tree at that ref",
            bool(target_rev) and facts.worktree == target_rev,
            f"working tree {(facts.worktree or 'absent')[:10]}, wanted {(target_rev or '?')[:10]}",
            f"git -C {facts.path} fetch --tags origin && git -C {facts.path} checkout {target_ref or '<ref>'}",
        ),
        Stage(
            3,
            "nested submodules at their recorded commits",
            not facts.nested_drift,
            f"{len(facts.nested_drift)} off their pins" if facts.nested_drift else "all at their pins",
            f"git -C {facts.path} submodule update --init --recursive",
        ),
        Stage(
            4,
            "no orphaned directories",
            not facts.litter,
            ", ".join(facts.litter) if facts.litter else "none",
            "remove each directory and its gitdir - recursing is what strands them",
        ),
        Stage(
            5,
            "foundry.lock names that ref",
            facts.lock.name == target_ref and facts.lock.rev == target_rev,
            f"lock says {facts.lock.kind} {facts.lock.name} {(facts.lock.rev or '')[:10]}",
            "rewritten in forge's own format, then verified by re-reading it",
        ),
        Stage(
            6,
            "the move is staged",
            not unstaged,
            f"index {(facts.index_gitlink or 'absent')[:10]}, working tree {(facts.worktree or 'absent')[:10]};"
            f" foundry.lock entry {'staged' if lock_staged else 'not staged'}",
            f"git add {' '.join(unstaged)}",
        ),
        Stage(
            7,
            "the move is committed",
            # Against the WORKING TREE, not the index - the gitlink and the lock entry alike: while
            # neither has moved they agree with each other, and comparing them would report the stage
            # done when nothing had happened.
            facts.head_gitlink == facts.worktree and lock_committed,
            f"HEAD {(facts.head_gitlink or 'absent')[:10]}, working tree {(facts.worktree or 'absent')[:10]};"
            f" foundry.lock entry {'committed' if lock_committed else 'not committed'}",
            "git commit",
        ),
    ]


def describe_at_risk(item: AtRisk, under: str) -> str:
    """One thing that exists only on this computer, in plain words, named by its path from the repository
    root. `under` is the dependency the item was found in; `at_risk` names items relative to it, and the
    dependency's own unpushed commits as `.`."""
    where = under if item.path == "." else f"{under}/{item.path}"
    if item.kind == "unpushed":
        commit, _, message = item.detail.partition(" ")
        return f'{where}: commit {commit} "{message}" is not pushed'
    return f"{where}: {'not tracked by git' if item.kind == 'untracked' else 'changed and not committed'}"


def move_checklist(
    facts: Facts,
    target_ref: str,
    target_rev: str | None,
    follows: str | None,
    entry: Recorded,
    nested_off: list[tuple[str, str]],
) -> list[Stage]:
    """What is left to do to move a dependency to `target_ref` (whose commit is `target_rev`) for bin/dep:
    `checklist` without foundry.lock, in plain words.

    What the dependency follows - `follows`, a branch, or None at a tag or commit - is recorded in
    `.gitmodules`, so adding and committing the move cover this dependency's entry there beside its
    folder. Only this entry is compared, never the whole file, whose other entries belong to other
    dependencies' moves. `nested_off` is each remapped nested path not at the commit its parent points to,
    with the command that checks it out.
    """
    path = facts.path
    safe = not facts.has_own_work
    # Named individually rather than counted: only the user can say whether a given thing is a day's work
    # or a stray file, and they cannot judge a number.
    listed = "; ".join(describe_at_risk(item, path) for item in facts.at_risk[:8])
    if len(facts.at_risk) > 8:
        listed += f"; and {len(facts.at_risk) - 8} more"
    name = entry.working.name if entry.working is not None else path
    recorded_branch = entry.working.branch if entry.working is not None else None
    entry_staged = entry.staged == entry.working
    entry_committed = entry.committed == entry.working
    unstaged = [path] if facts.index_gitlink != facts.worktree else []
    if not entry_staged:
        unstaged.append(".gitmodules")
    folder = (facts.worktree or "nothing")[:10]
    return [
        Stage(
            0,
            f"nothing in {path} is only on this computer",
            safe,
            "nothing found" if safe else f"found: {listed}",
            "" if safe else "push what you want to keep, or remove what you do not - or use --force",
        ),
        Stage(1, "a version to move to", True, target_ref, ""),
        Stage(
            2,
            "the folder has that version",
            bool(target_rev) and facts.worktree == target_rev,
            f"the folder has {folder}, wanted {(target_rev or 'unknown')[:10]}",
            f"git -C {path} fetch --tags origin && git -C {path} checkout {target_ref or '<version>'}",
        ),
        Stage(
            3,
            "submodules inside it that remappings use are at the commits it points to",
            not nested_off,
            ("not: " + ", ".join(nested for nested, _ in nested_off)) if nested_off else "all are",
            " && ".join(command for _, command in nested_off),
        ),
        Stage(
            4,
            "no old git repositories are left inside it",
            not facts.litter,
            ", ".join(facts.litter) if facts.litter else "none",
            "remove each folder and its git data",
        ),
        Stage(
            5,
            ".gitmodules says which branch it follows",
            # Unjudgeable until the ref resolves: whether it is a branch decides what should be recorded.
            target_rev is not None and recorded_branch == follows,
            f"it says {f'branch {recorded_branch}' if recorded_branch else 'no branch'}"
            + (
                f", wanted {f'branch {follows}' if follows else 'no branch'}"
                if target_rev is not None
                else "; what it should say is unknown until the version is found"
            ),
            ""
            if target_rev is None
            else f"git config -f .gitmodules submodule.{name}.branch {follows}"
            if follows
            else f"git config -f .gitmodules --unset submodule.{name}.branch",
        ),
        Stage(
            6,
            "the change is added (git add)",
            not unstaged,
            f"this repository points to {(facts.index_gitlink or 'nothing')[:10]}, the folder has {folder};"
            f" the .gitmodules change is {'added' if entry_staged else 'not added'}",
            f"git add {' '.join(unstaged)}",
        ),
        Stage(
            7,
            "the change is committed",
            # Against the FOLDER, not what is added - the gitlink and the entry alike: while neither has moved
            # they agree with each other, and comparing them would report the step done when nothing had
            # happened.
            facts.head_gitlink == facts.worktree and entry_committed,
            f"the last commit points to {(facts.head_gitlink or 'nothing')[:10]}, the folder has {folder};"
            f" the .gitmodules change is {'committed' if entry_committed else 'not committed'}",
            "git commit",
        ),
    ]


def repair(facts: Facts, found: Condition, entry: Recorded | None = None, repository: str = "this repository") -> str:
    """The one action that reaches a consistent state, looked up rather than composed, in plain words.

    `entry` is the dependency's `.gitmodules` entry. Keeping the folder's version adds that entry beside
    the folder when its working-tree version is not added, exactly as `yarn dep update` hands a move over,
    so the two tools never name different commands for one tree."""
    if found.name == "unreadable":
        # git's own mend: it writes the gitdir's `core.worktree` afresh.
        return f"git submodule update --init -- {facts.path} (this repairs git's link to the folder)"
    if found.name in ("uninitialised", "behind-record", "nested-drift"):
        # Each is a folder not at the commit the repository points to, and checking that out is sync's
        # job. Never `git add` for an older commit: that points the repository backwards for everyone
        # who pulls.
        return f"yarn dep sync (this checks out the commits {repository} points to)"
    if found.name == "litter-present":
        # Not a version change: the directory outlived the move that stranded it, and clearing it
        # touches no gitlink.
        return f"yarn update --sweep {facts.path}"
    if found.name in ("ahead-of-record", "off-record"):
        # Only the user knows whether the folder's commit was meant, so both directions are named.
        unstaged_entry = entry is not None and entry.staged != entry.working
        adding = " ".join([facts.path, *([".gitmodules"] if unstaged_entry else [])])
        if facts.unpushed:
            # Pointing the repository at a commit no remote holds breaks every other clone, and sync
            # refuses to move a folder holding one - so the commits are dealt with first, either way.
            commits = "commit" if len(facts.unpushed) == 1 else "commits"
            return (
                f"To keep the folder's version: push it (git -C {facts.path} push), then git add {adding}. "
                f"To go back to the version {repository} points to: remove the unpushed {commits}, then "
                f"yarn dep sync."
            )
        return (
            f"To keep the folder's version: git add {adding} ({repository} then points to it). "
            f"To go back to the version {repository} points to: yarn dep sync."
        )
    return ""
