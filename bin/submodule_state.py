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
from dataclasses import dataclass, field
from pathlib import Path

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

    `worktree` is None when the submodule is not checked out. `edits` counts only the developer's own
    file changes - it is read with --ignore-submodules=all, because a submodule's plain status also
    reports its NESTED submodules being off their pins, and conflating the two is what makes a tool
    tell you to commit and push a repository you do not own.
    """

    path: str
    directory: Path
    lock: Pin
    head_gitlink: str | None
    index_gitlink: str | None
    worktree: str | None
    origin_url: str | None
    gitmodules_url: str | None
    remote_tip: str | None
    worktree_ref: str | None = None
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


def read_lock(repo_root: Path) -> dict[str, Pin]:
    """foundry.lock as {path: Pin}. An unreadable or absent lock yields {}, which reads downstream as
    every dependency being unpinned - true, and better than half a picture."""
    lock_file = repo_root / "foundry.lock"
    if not lock_file.is_file():
        return {}
    try:
        raw = json.loads(lock_file.read_text())
    except json.JSONDecodeError:
        return {}
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


def _staged(repo_dir: Path, path: str) -> str | None:
    """The commit a repository STAGES for a submodule.

    The index rather than HEAD, following `ratchet.resolve`: what is staged is what you mean to depend
    on, and a bump on its way to a commit should read as the bump. Whether the index, HEAD and the
    checkout agree is a separate question, and `condition()` already answers it - this must not
    re-litigate it, or one fact grows two verdicts again."""
    fields = git(repo_dir, "ls-files", "-s", path).stdout.split()
    return fields[1] if len(fields) > 1 else None


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
            our_commit = _staged(repo_root, our_path)
            their_commit = _staged(repo_root / path, their_path)
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

    origin = git(submodule, "remote", "get-url", "origin") if checked_out else None
    declared = git(repo_root, "config", "-f", ".gitmodules", "--get", f"submodule.{path}.url")

    # The branch tip as of the last fetch. Read from the remote-tracking ref rather than the network:
    # doctor must not reach out, and "behind as of your last fetch" is the honest claim either way.
    tip = git(submodule, "rev-parse", f"origin/{pin.name}") if checked_out and pin.moving else None

    # The tag the checked-out commit IS, when it is one. This is what makes a disagreement
    # answerable: the GUI checks a tag out by name, so its bump leaves the intended version readable
    # here. forge checks out a branch, whose tip need not be tagged, so after a forge run this is
    # often None and the user has to say what they meant.
    named = git(submodule, "describe", "--tags", "--exact-match", "HEAD") if checked_out else None

    return Facts(
        path=display or path,
        directory=submodule,
        lock=pin,
        head_gitlink=head.stdout.strip() if head.returncode == 0 else None,
        index_gitlink=staged[1] if len(staged) > 1 else None,
        worktree=checked_out.stdout.strip() if checked_out and checked_out.returncode == 0 else None,
        origin_url=origin.stdout.strip() if origin and origin.returncode == 0 else None,
        gitmodules_url=declared.stdout.strip() if declared.returncode == 0 else None,
        remote_tip=tip.stdout.strip() if tip and tip.returncode == 0 else None,
        worktree_ref=named.stdout.strip() if named and named.returncode == 0 else None,
        edits=_edits(submodule) if checked_out else [],
        unpushed=_unpushed(submodule) if checked_out else [],
        nested_drift=_nested_drift(submodule) if checked_out else [],
        litter=_litter(submodule) if checked_out else [],
        at_risk=at_risk(submodule) if checked_out else [],
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
    """What is wrong with one submodule, named. `detail` states the facts behind the name and never
    speculates about how the state arose: a working tree ahead of the recorded pins looks identical
    whether a GUI bumped it or a forge run half-finished, so claiming either would be invention."""

    name: str
    detail: str
    reach: str | None = None

    # What a READER is told. `name` stays the identifier this module and its tests branch on, but it
    # is shorthand for whoever wrote it - "litter-present" describes a data structure, not a thing
    # that happened to your checkout. Anything a person sees says what is wrong in words they did not
    # have to learn.
    SUMMARIES = {
        "uninitialised": "recorded as a dependency but not checked out",
        "at-risk-content": "holds work that exists nowhere else",
        "litter-present": "has leftover directories from an older version",
        "nested-drift": "its own dependencies are not at the commits it records",
        "unpinned": "missing from foundry.lock",
        "bumped-not-locked": "is at more than one version",
        "behind-moving-pin": "is behind the branch it tracks",
        "consistent": "agrees with the commit",
    }

    @property
    def summary(self) -> str:
        return self.SUMMARIES.get(self.name, self.name)

    @property
    def is_fault(self) -> bool:
        """Whether doctor should report it. Only a branch pin behind its remote is excluded: that is
        the remote moving, not this repository holding anything, and bao-base's main moves daily.

        Work in progress inside a dependency is not among these at all - see `condition`. Doctor
        grades what has been DONE, and unfinished work is not a defect."""
        return self.name not in ("consistent", "behind-moving-pin")


def condition(facts: Facts) -> Condition:
    """Name what is wrong, most fundamental first: a submodule that is not checked out has no other
    meaningful state, and work that a repair would destroy outranks the disagreement that prompted the
    repair."""
    if not facts.initialised:
        return Condition("uninitialised", "recorded but not checked out")

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
    # .git/config (what `git submodule update` actually reads) rather than the submodule's `origin`,
    # and recurses. Two checks reporting one fault in two vocabularies is the thing this module
    # exists to stop, so there is exactly one owner.

    # HEAD is deliberately absent. doctor is what you run BEFORE committing, so a check that withholds
    # a pass until you commit demands the very thing it exists to prepare you for - and HEAD lagging is
    # only "not committed yet", which is what all work in progress looks like. What it judges is the
    # checkout, what you have STAGED, and foundry.lock: the same index-is-the-baseline rule as
    # `ratchet.resolve` and the dependency-version check. HEAD still narrates `reach` below, because
    # how far a bump travelled is worth saying once something else has already made it a fault.
    pins = {
        "working tree": facts.worktree,
        "index": facts.index_gitlink,
        "foundry.lock": facts.lock.rev,
    }
    distinct = {value for value in pins.values() if value}

    if len(distinct) > 1:
        # Grouped by the commit they name rather than listed flat: which claims AGREE is the thing a
        # reader acts on, and four values in a row hides it.
        agreeing: dict[str, list[str]] = {}
        for where, what in pins.items():
            if what:
                agreeing.setdefault(what, []).append(where)
        disagreement = "; ".join(f"{' + '.join(names)} say {what[:10]}" for what, names in agreeing.items())

        # `reach` narrates how far a version bump travelled, and is set ONLY for the three shapes a
        # bump actually produces - the lock behind, and the change having reached the working tree,
        # the index, or HEAD. Any other disagreement is not a bump, and guessing at one produced a
        # message that said the lock was behind when the lock and the working tree in fact agreed.
        # The grouping above is always true; this is the part that can only be said sometimes.
        behind = facts.lock.rev
        reach = None
        if facts.worktree != behind:
            if facts.head_gitlink == facts.index_gitlink == behind:
                reach = "the working tree"
            elif facts.worktree == facts.index_gitlink and facts.head_gitlink == behind:
                reach = "the index"
            elif facts.worktree == facts.index_gitlink == facts.head_gitlink:
                reach = "HEAD"
        return Condition("bumped-not-locked", disagreement, reach)

    # No branch for unpushed commits: `at_risk` above already collects them, running the same
    # `git log HEAD --not --remotes`, so anything this could match has returned already. One measure
    # of what exists nowhere else, not two.

    if facts.litter:
        return Condition("litter-present", "untracked repositories: " + ", ".join(facts.litter))

    if facts.nested_drift:
        return Condition(
            "nested-drift",
            f"{len(facts.nested_drift)} nested submodule(s) off their recorded commits",
        )

    if facts.lock.kind == "unpinned":
        return Condition(
            "unpinned",
            "a submodule of a foundry project, but foundry.lock does not name it",
        )

    if facts.lock.moving and facts.remote_tip and facts.remote_tip != facts.worktree:
        return Condition("behind-moving-pin", f"behind origin/{facts.lock.name}")

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
            facts.index_gitlink == facts.worktree,
            f"index {(facts.index_gitlink or 'absent')[:10]}, working tree {(facts.worktree or 'absent')[:10]}",
            f"git add {facts.path}",
        ),
        Stage(
            7,
            "the move is committed",
            # Against the WORKING TREE, not the index: while neither has moved they agree with each
            # other, and comparing them would report the stage done when nothing had happened.
            facts.head_gitlink == facts.worktree,
            f"HEAD {(facts.head_gitlink or 'absent')[:10]}, working tree {(facts.worktree or 'absent')[:10]}",
            "git commit",
        ),
    ]


def repair(facts: Facts, found: Condition) -> str:
    """The one action that reaches a consistent state, looked up rather than composed.

    Every repair here is read off the same action->effect knowledge the checklist uses, which is what
    stops two checks recommending opposite things. In particular `git add` is never offered for a
    version disagreement: staging moves the gitlink and cannot touch foundry.lock, so it records the
    disagreement instead of resolving it - the mistake the old doctor made.
    """
    # The PATH, never the basename. A dependency's dependency routinely shares a name with one of
    # ours - bao-base and OpenZeppelin both carry `lib/forge-std` - so a basename sends `yarn update`
    # to a different repository, moving one that was fine and leaving the reported problem untouched.
    # `resolve_path` accepts a full path, so this costs nothing for the ordinary top-level case.
    name = facts.path
    if found.name == "uninitialised":
        return f"git submodule update --init --recursive {facts.path}"
    if found.name == "at-risk-content":
        return f"commit and push it, or discard it: git -C {facts.path} status --untracked-files=all"
    if found.name == "nested-drift":
        return f"git -C {facts.path} submodule update --init --recursive"
    if found.name == "litter-present":
        # Not a version change: the directory outlived the move that stranded it, and clearing it
        # touches no pin, lock or gitlink. Kept separate so it can also be offered for a submodule of
        # a submodule, whose version is its own parent's to change but whose litter is still here.
        return f"yarn update --sweep {facts.path}"
    if found.name == "unpinned":
        # forge writes the entry when it installs, so pinning it is the same command as updating it.
        return f"yarn update {name}@{facts.worktree_ref or '<ref>'}"
    if found.name in ("bumped-not-locked", "litter-present"):
        # When the checkout and the index already agree and only the lock is behind them, the repair
        # needs no ref: `--relock` reads the staged commit rather than being told it. That matters
        # because `worktree_ref` is an EXACT tag match, so a branch bump - which is what most bumps
        # are - lands on no tag, and the ref-bearing advice below degrades to a literal `<ref>` the
        # user has no way to answer.
        #
        # Staged is the whole condition, and it is `relock`'s own precondition for the same reason:
        # what it records is what is there, so an accidental checkout would become the recorded pin
        # and the disagreement that would have shown it up would be gone. Unstaged, the checkout is
        # exactly the thing that might be wrong, and the user has to say what they meant.
        if facts.worktree is not None and facts.index_gitlink == facts.worktree and facts.lock.rev != facts.worktree:
            return f"yarn update --relock {name}"
        # Taken from the CHECKLIST rather than written here, against the version the working tree is
        # actually on - the working tree being the truth. So doctor's advice is literally the next
        # thing `yarn update` would do, and the two cannot drift apart or contradict each other.
        #
        # It also gets the case a fixed string got wrong: when every claim agrees except HEAD, the
        # dependency is staged and not committed, and the fix is `git commit` - not an update.
        # When the lock's REV already names the checked-out commit, the lock is right and the ref in
        # play is the one it records - even if that commit carries no tag of its own, which is the
        # usual case for a branch. Passing the working tree's tag there instead reported a correct
        # lock as out of step, and sent the user to `yarn update` when all that was left was to stage
        # or commit.
        target_ref = facts.lock.name if facts.lock.rev == facts.worktree else facts.worktree_ref
        undone = [
            stage for stage in checklist(facts, target_ref, facts.worktree) if not stage.done and 2 <= stage.number <= 7
        ]
        # Stages 2-5 are `yarn update`'s to perform, 6 and 7 are the user's - so the first stage that
        # is not done says which of the two is being asked for. That is what stops doctor telling
        # someone to update a dependency whose only remaining need is `git commit`.
        if undone and undone[0].number >= 6:
            return undone[0].action
        return f"yarn update {name}@{facts.worktree_ref or '<ref>'}"
    return ""


def stale_lock_entries(repo_root: Path) -> list[tuple[str, str]]:
    """foundry.lock entries naming a path that is not a submodule, as (display path, what it pins).

    The mirror of enumerating from .gitmodules: a dependency that was removed leaves its pin behind,
    and nothing that walks the submodule tree would ever look at it. It pins nothing, so it misleads
    every reader of the lock about what the project depends on. Checked for every parent that keeps a
    lock, since a consumer repository and bao-base each have their own.
    """
    prefixes: dict[Path, str] = {repo_root: ""}
    children: dict[Path, set[str]] = {repo_root: set()}
    for parent, name, display in submodules(repo_root):
        children.setdefault(parent, set()).add(name)
        prefixes[parent / name] = f"{display}/"
        children.setdefault(parent / name, set())

    stale: list[tuple[str, str]] = []
    for repo, names in children.items():
        if not (repo / "foundry.lock").is_file():
            continue
        for path, pin in read_lock(repo).items():
            if path not in names:
                stale.append((f"{prefixes.get(repo, '')}{path}", f"{pin.kind} {pin.name or (pin.rev or '')[:10]}"))
    return stale
