#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import tomllib
from collections import Counter
from collections.abc import Sequence
from pathlib import Path, PurePath
from typing import Any, cast

import json5

import columns
import workflow_copy
from checks import Check, report
from deployment_baselines import RECORD, OriginUnanswered, compare_with_origin, origin_tags, read_baselines
from forge_config import forge_config
from submodule_state import (
    Condition,
    Declared,
    Facts,
    at_record,
    condition,
    declared_submodules,
    git,
    keep_command,
    litter_condition,
    nested_levels,
    read_facts,
    remapping_target,
    remote_holds,
    repair,
    staged_gitlink,
    stray_clones,
    submodule_levels,
    unused_checkouts,
)


def load_toml(path: Path) -> dict[str, Any]:
    """Parse a TOML file with the stdlib tomllib. bao-base runs on its pinned Python (3.13, see
    bin/.python-version), so tomllib is always present — no third-party fallback needed."""
    with path.open("rb") as stream:
        return tomllib.load(stream)


def load_remappings(repo_root: Path) -> tuple[list[str], list[str]]:
    """Load and validate the remapping lists from foundry.toml (profile.default.remappings) and
    wake.toml (compiler.solc.remappings). Exits with a clear message if a file or key is missing or a
    list is malformed. Returns (foundry_remappings, wake_remappings)."""
    foundry_path = repo_root / "foundry.toml"
    wake_path = repo_root / "wake.toml"

    missing = [path for path in (foundry_path, wake_path) if not path.is_file()]
    if missing:
        readable = ", ".join(path.name for path in missing)
        raise SystemExit(f"Missing config file(s): {readable}.")

    foundry_data = load_toml(foundry_path)
    wake_data = load_toml(wake_path)

    try:
        foundry_remappings = foundry_data["profile"]["default"]["remappings"]
    except KeyError as exc:
        raise SystemExit("foundry.toml does not define profile.default.remappings.") from exc

    try:
        wake_remappings = wake_data["compiler"]["solc"]["remappings"]
    except KeyError as exc:
        raise SystemExit("wake.toml does not define compiler.solc.remappings.") from exc

    if not isinstance(foundry_remappings, list):
        raise SystemExit("profile.default.remappings in foundry.toml is not a list.")
    if not isinstance(wake_remappings, list):
        raise SystemExit("compiler.solc.remappings in wake.toml is not a list.")

    foundry_items = cast(list[Any], foundry_remappings)
    for item in foundry_items:
        if not isinstance(item, str):
            raise SystemExit("profile.default.remappings in foundry.toml must contain only strings.")
    wake_items = cast(list[Any], wake_remappings)
    for item in wake_items:
        if not isinstance(item, str):
            raise SystemExit("compiler.solc.remappings in wake.toml must contain only strings.")

    return cast(list[str], foundry_items), cast(list[str], wake_items)


def strip_context_prefix(entry: str) -> str:
    """Foundry supports context-specific remappings ('ctx/:key=val'); Wake does not.
    Strip the context prefix so both sides can be compared on equal footing."""
    eq = entry.find("=")
    colon = entry.find(":", 0, eq if eq != -1 else len(entry))
    if colon != -1:
        return entry[colon + 1 :]
    return entry


def submodule_url_drift(repo_dir: Path) -> list[tuple[str, str, str]]:
    """Find this repository's submodules whose initialized URL in .git/config disagrees with the
    committed .gitmodules. `git submodule update` trusts .git/config (written once at init/sync) and
    never reconciles it when .gitmodules changes, so a stale .git/config silently clones the wrong URL.
    Read-only: compares the two configs. A dependency's own nested submodules are its business, so they
    are not read. Returns (path, .gitmodules url, .git/config url)."""
    gitmodules = repo_dir / ".gitmodules"
    if not gitmodules.is_file():
        return []

    listing = subprocess.run(
        ["git", "config", "-f", ".gitmodules", "--get-regexp", r"^submodule\..*\.url$"],
        cwd=repo_dir,
        capture_output=True,
        text=True,
    )

    drift: list[tuple[str, str, str]] = []
    for line in listing.stdout.splitlines():
        key, _, gitmodules_url = line.partition(" ")
        gitmodules_url = gitmodules_url.strip()
        name = key[len("submodule.") : -len(".url")]

        path_result = subprocess.run(
            ["git", "config", "-f", ".gitmodules", "--get", f"submodule.{name}.path"],
            cwd=repo_dir,
            capture_output=True,
            text=True,
        )
        sub_path = path_result.stdout.strip() or name

        # --local is the .git/config that `submodule update` reads. A non-zero return means
        # this submodule isn't initialized in this clone, so there is no stored URL to drift.
        local = subprocess.run(
            ["git", "config", "--local", "--get", f"submodule.{name}.url"],
            cwd=repo_dir,
            capture_output=True,
            text=True,
        )
        if local.returncode == 0:
            gitconfig_url = local.stdout.strip()
            if gitconfig_url != gitmodules_url:
                drift.append((sub_path, gitmodules_url, gitconfig_url))

    return drift


def _finding(facts: Facts, found: Condition, repository: str, weigh: Sequence[str] = (), keep: str = "") -> str:
    """One finding as doctor prints it: what is wrong, the facts behind it, anything a reader must
    weigh before acting, and the one command that fixes it - in plain words, naming the repository.

    Shared by the version findings and the leftovers, so the two checks cannot come to look like
    different tools reporting on the same tree."""
    lines = [f"{facts.path}: {found.describe(repository)}"]
    # A comparison arrives as rows and is aligned; every other condition is one fact in words. Same
    # alignment as the cross-repo table in `dependency-conflicts.py`, from the same code, so a reader
    # meets one column discipline rather than one per report. The rows carry which side each commit is
    # from; the reader is told it in words.
    sides = {"working tree": f"in the {facts.path} folder", "index": f"{repository} points to"}
    rows = [(commit, sides.get(side, side)) for commit, side in found.rows]
    lines.extend(columns.rows(rows, indent="  ") if rows else [f"  {found.detail}"])
    if found.relation:
        lines.append(f"  {Condition.RELATIONS.get(found.relation, found.relation)}")
    lines.extend(f"  {item}" for item in weigh)
    if fix := repair(facts, found, keep, repository):
        lines.append(f"  Repair: {fix}")
    return "\n".join(lines)


def submodule_problems(repo_root: Path, remappings: list[str]) -> tuple[list[str], list[str]]:
    """One finding per dependency of this repository, from bin/submodule_state.py, split into
    (versions, leftovers).

    Split by what the reader must DO, which is what a check title has to be true of: a version is
    moved or staged, and a leftover is deleted. Three findings reading "has leftover directories from
    an older version" under a check titled "each dependency is at one version" made the title false of
    half its contents.

    Only this repository's own submodules are read. A dependency's nested submodules are its own
    lockfile: the only ones that count are the paths `remappings` point into, judged as part of the
    dependency that holds them, because those are what the build reads. The rest are not reported in any
    state - checked out, stale or absent.

    Every reading and every repair comes from the module `yarn dep` acts on, so the two tools cannot
    disagree. States that are normal are not reported at all: a dependency carrying local commits is
    what working in one looks like."""
    repository = repo_root.name
    versions: list[str] = []
    leftovers: list[str] = []
    for stray in stray_clones(repo_root):
        leftovers.append(
            f"{stray}: a git repository inside {repository} that is not a submodule\n"
            f"  Nobody else can see what is in it, because .gitmodules does not name it.\n"
            f"  Repair: delete {stray}, and the .git/modules/{stray} folder if there is one"
        )
    for dependency in declared_submodules(repo_root):
        facts = read_facts(repo_root, dependency.path)
        nested_off = [
            (directory / level.path).relative_to(repo_root).as_posix()
            for directory, level in nested_levels(repo_root, dependency.path, remappings)
            if not at_record(directory, level)
        ]
        found = condition(facts, list(dict.fromkeys(nested_off)))
        # Leftovers are read on their own rather than through `condition`, which names one thing and
        # ranks a version disagreement above them. A dependency can be at the wrong version AND have
        # stranded directories - two faults, two commands - and a check titled "no dependency has
        # leftovers" that could only see them when nothing outranked them would report all-clear
        # beside a version finding that named one.
        if stranded := litter_condition(facts):
            leftovers.append(_finding(facts, stranded, repository))
        if not found.is_fault or found.name == "litter-present":
            continue
        # Facts a reader must weigh before acting, which `condition` did not name because something
        # more urgent outranked it. Without these a repair can look safe when it is not.
        weigh = []
        if facts.unpushed:
            count = len(facts.unpushed)
            weigh.append(
                f"{count} commit{'s' if count > 1 else ''} in the folder {'are' if count > 1 else 'is'} not pushed."
            )
        versions.append(_finding(facts, found, repository, weigh, keep_command(repo_root, dependency.path)))
    return versions, leftovers


def unpublished_commit_problems(repo_root: Path, remappings: list[str]) -> list[str]:
    """Commits this repository points to that no remote holds, as each clone knew its remote at its last
    fetch: for each dependency, and each nested path a remapping uses, judged in the repository that points
    to it. The version check passes when the folder has the commit pointed to, even when only this computer
    has that commit, and every other clone then fails to fetch it. Both the index's commit and HEAD's are
    judged: HEAD's is what a clone gets now, the index's what it gets after the next commit. Returns one
    finding per such commit, or []."""
    repository = repo_root.name
    levels: dict[str, tuple[Path, Declared]] = {}
    for dependency in declared_submodules(repo_root):
        levels[dependency.path] = (repo_root, dependency)
        for directory, level in nested_levels(repo_root, dependency.path, remappings):
            levels.setdefault((directory / level.path).relative_to(repo_root).as_posix(), (directory, level))
    problems: list[str] = []
    for path, (directory, level) in levels.items():
        parent = repository if directory == repo_root else directory.relative_to(repo_root).as_posix()
        committed = git(directory, "rev-parse", "--verify", "--quiet", f"HEAD:{level.path}").stdout.strip()
        # Keyed by commit, so one pointed to by both is judged once, named as the index names it.
        pointed = {
            committed: f"the commit {parent}'s last commit points to",
            staged_gitlink(directory, level.path): f"the commit {parent} points to",
        }
        for commit, side in pointed.items():
            if not commit or remote_holds(directory / level.path, commit) is not False:
                continue
            # A nested path's commit is its dependency's to choose, so only pushing it is offered there.
            moving = (
                f", or move to a version a remote holds: yarn dep update {path}@<version>"
                if directory == repo_root
                else ""
            )
            problems.append(
                f"{path}: no remote holds {commit[:10]}, {side}\n"
                f"  Only this computer has it, so any other clone fails to check {path} out.\n"
                f"  Repair: push it (git -C {path} push){moving}"
            )
    return problems


def _config_entries(checkout: Path, pattern: str, *options: str) -> list[tuple[str, str, str, str]]:
    """Each setting git reads in `checkout` whose key matches `pattern`, in the order git reads them, as
    (scope, origin, key, value). `--show-origin` gives the origin as `file:<path>`, or `command line:` for
    one set by the environment. None set is an empty list, which git reports as exit 1."""
    listed = subprocess.run(
        ["git", "config", "-z", "--show-scope", "--show-origin", *options, "--get-regexp", pattern],
        cwd=checkout,
        capture_output=True,
        text=True,
    )
    # Each entry is `scope\0origin\0key\nvalue\0`.
    fields = listed.stdout.split("\0")[:-1]
    entries: list[tuple[str, str, str, str]] = []
    for scope, origin, setting in zip(fields[0::3], fields[1::3], fields[2::3], strict=True):
        key, _, value = setting.partition("\n")
        entries.append((scope, origin, key, value))
    return entries


def tag_push_setting_problems(repo_root: Path) -> list[str]:
    """Settings that make `git push` send tags nobody named, in this repository and in each dependency
    checkout: each is a clone with its own config, and a push can be made from any of them.
    `verify-audit --push` sends each deployment tag by name; these send other tags with it:

    - `push.followTags`: every annotated tag on the commits pushed, deployment tag or not.
    - `remote.<name>.mirror`: every ref, and each tag there that this clone lacks is deleted.
    - a `remote.<name>.push` refspec whose source covers `refs/tags/`.

    A true-or-false setting counts as git reads it: the last value wins, so one turned off later is no
    finding, and when it is on, every place setting it on is named, since each must go. One setting that
    several checkouts read, a global one, is one finding naming them all. Each repair names the file git
    reports, relative to the repository root when it is inside it."""
    checkouts = [(repo_root.name, repo_root)] + [
        (dependency.path, repo_root / dependency.path)
        for dependency in declared_submodules(repo_root)
        if (repo_root / dependency.path / ".git").exists()
    ]
    scopes = {
        "local": "the clone's own config",
        "worktree": "the worktree's config",
        "global": "your global config",
        "system": "the system config",
    }
    # (what is wrong, where it is set, the repair) to the checkouts it reaches, in the order met.
    found: dict[tuple[str, str, str], list[str]] = {}
    for shown, checkout in checkouts:
        switches = _config_entries(checkout, r"^(push\.followtags|remote\..*\.mirror)$", "--type=bool")
        last = {key: value for _, _, key, value in switches}
        refspecs = _config_entries(checkout, r"^remote\..*\.push$")
        for scope, origin, key, value in [*switches, *refspecs]:
            # A refspec's source side is what it pushes: a tag name, or a glob whose fixed part a tag's name
            # starts with. A negative refspec (`^…`) and `:`, which pushes matching branches, cover no tag.
            source = value.removeprefix("+").partition(":")[0]
            covers_tags = source.startswith("refs/tags/") or (
                "*" in source and "refs/tags/".startswith(source.partition("*")[0])
            )
            if key == "push.followtags" and value == "true" and last[key] == "true":
                what = (
                    "push.followTags is true, so git push also sends every annotated tag on the commits it pushes, "
                    "deployment tag or not"
                )
                unset = ["--unset", "push.followTags"]
            elif key.endswith(".mirror") and value == "true" and last[key] == "true":
                remote = key.removeprefix("remote.").removesuffix(".mirror")
                what = (
                    f"remote {remote} mirrors, so git push {remote} sends every ref, tags included, and deletes "
                    "each tag there that this clone lacks"
                )
                unset = ["--unset", key]
            elif key.endswith(".push") and covers_tags:
                remote = key.removeprefix("remote.").removesuffix(".push")
                what = f"remote {remote} pushes {value}, so git push {remote} sends every tag that refspec covers"
                unset = ["--fixed-value", "--unset", key, value]
            else:
                continue
            if not origin.startswith("file:"):
                where = "the environment, by GIT_CONFIG_COUNT or GIT_CONFIG_PARAMETERS, not a file"
                repair = "remove it from the environment git runs in"
            else:
                held = Path(origin.removeprefix("file:"))
                held = (held if held.is_absolute() else checkout / held).resolve()
                named = held.relative_to(repo_root.resolve()) if held.is_relative_to(repo_root.resolve()) else held
                where = f"{named.as_posix()}, {scopes.get(scope, f'the {scope} config')}"
                repair = shlex.join(["git", "config", "--file", named.as_posix(), *unset])
            reached = found.setdefault((what, where, repair), [])
            if shown not in reached:
                reached.append(shown)
    return [
        f"{', '.join(shown)}: {what}\n  Set in {where}\n  Repair: {repair}"
        for (what, where, repair), shown in found.items()
    ]


def deployment_tag_problems(repo_root: Path) -> list[str]:
    """How origin's deployment tags stand against the record and this clone, in a repository with a
    deployed.json: each tag the record derives that origin lacks, or holds as another object than this
    clone's, and each name origin holds that the record no longer derives. Returns one finding per tag, or
    [].

    git keeps a copy of origin's branches but none of its tags, so this asks origin, once. A check that
    could not ask fails, in git's words: passing would say origin was looked at when it was not."""
    if not (repo_root / RECORD).is_file():
        return []
    record = list(read_baselines(repo_root).values())
    try:
        origin = origin_tags(repo_root)
    except OriginUnanswered as unanswered:
        return [
            f"origin could not be asked for its tags, so none was checked:\n  {unanswered}\n"
            "  Repair: reach origin, then run yarn doctor again"
        ]
    found = compare_with_origin(repo_root, record, origin)
    problems = [
        f"{tag}: origin does not hold it\n"
        "  Repair: yarn verify-audit --write if this clone lacks it too, then yarn verify-audit --push"
        for tag in found.lacking
    ]
    problems += [
        f"{tag}: origin holds another copy than this clone's\n  Repair: yarn verify-audit --pull --write --push"
        for tag in found.differing
    ]
    for tag, replacement in found.stale.items():
        if replacement is not None:
            problems.append(
                f"{tag}: origin holds it, and the record no longer derives it. It is replaced by {replacement}\n"
                "  Repair: yarn verify-audit --push deletes it on origin"
            )
        else:
            problems.append(
                f"{tag}: origin holds it, and the record no longer derives it\n"
                f"  Repair: deleting it is yours: git push origin --delete refs/tags/{tag}"
            )
    return problems


def unused_checkout_problems(repo_root: Path, remappings: list[str]) -> list[str]:
    """Submodules checked out inside this repository's dependencies that no remapping uses. The build does not
    read them: they are left from an older recursive checkout, or from a sync run inside a dependency to work
    on it. Returns one block listing each, or []."""
    found = [
        (parent / nested.path).relative_to(repo_root).as_posix()
        for dependency in declared_submodules(repo_root)
        if (repo_root / dependency.path / ".git").exists()
        for parent, nested in unused_checkouts(repo_root, repo_root, dependency, remappings)
    ]
    if not found:
        return []
    lines = ["These submodules are checked out inside a dependency, and no remapping uses them:"]
    lines.extend(f"  {path}" for path in found)
    lines.append(
        "  Repair: yarn dep sync. One that holds work only on this computer stops it, and is named with that work."
    )
    return ["\n".join(lines)]


def remapping_target_problems(repo_root: Path, remappings: list[str]) -> list[str]:
    """Remappings that lead to no path, though every submodule on the way is checked out at its record -
    so no submodule provides the path, rather than one not yet being checked out (which the dependency
    check reports, with its own repair). Such a remapping resolves no import, misstates what the build
    reads, and points `yarn dep` at a nested path nothing declares. Returns one block listing each, or
    []."""
    dead = [
        remapping
        for remapping in remappings
        if not (repo_root / remapping_target(remapping)).exists()
        and all(
            at_record(directory, level) for directory, level in submodule_levels(repo_root, remapping_target(remapping))
        )
    ]
    if not dead:
        return []
    lines = ["These remappings point to folders that do not exist, and no submodule provides them:"]
    lines.extend(f"  {remapping}" for remapping in dead)
    lines.append(
        "  Repair: remove each one from foundry.toml and from wake.toml (the two files list the same remappings)"
    )
    return ["\n".join(lines)]


def remapping_problems(foundry_remappings: list[str], wake_remappings: list[str]) -> list[str]:
    """Compare foundry.toml's remappings (foundry context prefixes stripped, since Wake doesn't
    support them) against wake.toml's. Returns problem lines, or [] when they are consistent."""
    normalized_foundry = [strip_context_prefix(r) for r in foundry_remappings]
    if normalized_foundry == wake_remappings:
        return []

    foundry_only = [item for item in normalized_foundry if item not in wake_remappings]
    wake_only = [item for item in wake_remappings if item not in normalized_foundry]

    # A wake entry that still carries foundry's context syntax (`context:prefix=target`) is the common
    # mistake (copying foundry's remapping verbatim): Wake doesn't support contexts, so it needs the
    # bare form. If stripping the context yields an entry foundry has, report that specifically rather
    # than as an opaque two-sided diff.
    mismatch_details: list[str] = []
    for entry in list(wake_only):
        bare = strip_context_prefix(entry)
        if bare != entry and bare in foundry_only:
            mismatch_details.append(
                f"wake.toml has `{entry}`. Wake does not support forge's context remappings (the part "
                f"before `:`). Use `{bare}` instead."
            )
            wake_only.remove(entry)
            foundry_only.remove(bare)

    if foundry_only:
        mismatch_details.append("Entries only in foundry.toml:\n  " + "\n  ".join(foundry_only))
    if wake_only:
        mismatch_details.append("Entries only in wake.toml:\n  " + "\n  ".join(wake_only))

    if not mismatch_details:
        for index, pair in enumerate(zip(normalized_foundry, wake_remappings)):
            if pair[0] != pair[1]:
                mismatch_details.append(
                    f"The lists are in a different order. At position {index}, foundry.toml has {pair[0]!r} "
                    f"and wake.toml has {pair[1]!r}."
                )
                break
        if len(normalized_foundry) != len(wake_remappings):
            mismatch_details.append(
                f"The lists have different lengths: {len(normalized_foundry)} in foundry.toml, "
                f"{len(wake_remappings)} in wake.toml."
            )

    if not mismatch_details:
        mismatch_details.append("The lists are different, but doctor cannot say where.")

    return ["The remappings in foundry.toml and wake.toml are different:\n" + "\n".join(mismatch_details)]


def forge_source_directories(repo_root: Path) -> tuple[str, ...]:
    """The directories forge builds every Solidity file in - source, test and script - as `forge config`
    resolves them, relative to the repo root."""
    config = forge_config(repo_root)
    return tuple(config[key] for key in ("src", "test", "script"))


def forge_setting_findings(
    repo_root: Path, section: str | None, key: str, wanted: Any, consequence: str, repair: str
) -> list[str]:
    """One finding when forge does not resolve the setting `key` to `wanted` - in the table `section` of
    foundry.toml, or in the profile when `section` is None. Read from `forge config` rather than foundry.toml,
    because an environment variable or the active profile overrides the file, and forge builds and tests with
    what it resolves. A key forge does not report is a finding too: the question is then unanswered, and a
    pass would say it was looked at. `consequence` is what the setting's other value does, as the finding
    states it; `repair` is the change to foundry.toml. Returns [] when forge resolves the setting to
    `wanted`."""
    resolved = forge_config(repo_root)
    settings: dict[str, Any] = resolved if section is None else resolved.get(section, {})
    name = key if section is None else f"{section}.{key}"
    if key in settings and settings[key] == wanted:
        return []
    found = (
        f"forge config gives {name} = {json.dumps(settings[key])}, so {consequence}"
        if key in settings
        else f"forge config does not give {name}, so doctor cannot tell whether {consequence}"
    )
    return [
        f"{found}\n  Repair: {repair}. If foundry.toml already says so, an environment variable changes it:"
        " FOUNDRY_PROFILE, or another FOUNDRY_* variable."
    ]


def remapping_detection_problems(repo_root: Path) -> list[str]:
    """Whether forge adds remappings of its own. Unless `auto_detect_remappings` is false, forge derives
    remappings from the library directories it finds - nested ones inside dependencies included - and uses
    them beside the ones foundry.toml writes. Returns one finding, or [] when forge resolves it to false."""
    return forge_setting_findings(
        repo_root,
        None,
        "auto_detect_remappings",
        False,
        "forge adds remappings of its own",
        "set auto_detect_remappings = false in [profile.default] in foundry.toml",
    )


def block_gas_limit_problems(repo_root: Path) -> list[str]:
    """Whether a script's simulation keeps the block gas limit check. `disable_block_gas_limit` in
    foundry.toml reaches every forge run, `forge script` included, whose simulation then no longer checks
    that each transaction fits a block before it is sent. The test runs, which need the lift - one call
    running a whole deploy or upgrade exceeds a forked block's gas limit - ask for it on their command line
    (bin/forge_test_runs.py), where no script sees it. Returns one finding, or [] when forge resolves it to
    false."""
    return forge_setting_findings(
        repo_root,
        None,
        "disable_block_gas_limit",
        False,
        "a script's simulation does not check that each transaction fits a block",
        "remove disable_block_gas_limit from foundry.toml",
    )


def deny_warnings_problems(repo_root: Path) -> list[str]:
    """Whether a build fails on a compiler warning. The test runs pass their own `--deny`
    (bin/forge_test_runs.py), so foundry.toml's `deny` reaches only the builds they do not make: one made by
    hand, and the one a script makes before it runs, where a warning would otherwise pass unseen. Returns one
    finding, or [] when forge resolves it to "warnings"."""
    return forge_setting_findings(
        repo_root,
        None,
        "deny",
        "warnings",
        "a build made by hand, or for a script, passes with compiler warnings",
        'set deny = "warnings" in [profile.default] in foundry.toml',
    )


def foundry_lock_problems(repo_root: Path) -> list[str]:
    """A foundry.lock in the index or the working tree. forge writes one whenever it installs: on `forge
    install` and `forge update`, recording which branch or tag each dependency came from, and when build, test,
    coverage or script finds a dependency with nothing checked out in its folder, which it then installs with
    every nested submodule, unbidden. `yarn dep`, which replaces the install commands, records versions in
    .gitmodules and in the commit this repository points to, and leaves the lock as it was - so a lock names
    versions the dependencies left, and forge reads it as current when told to (`--locked`). Presence is the
    finding, whatever the lock says; the removal depends on what git knows of it, and `yarn dep sync` follows,
    to leave only the checkouts the build reads. Returns [] when there is none."""
    tracked = (
        subprocess.run(
            ["git", "ls-files", "--error-unmatch", "foundry.lock"], cwd=repo_root, capture_output=True, text=True
        ).returncode
        == 0
    )
    present = (repo_root / "foundry.lock").is_file()
    if tracked and present:
        return ["git tracks foundry.lock\n  Repair: git rm foundry.lock, then yarn dep sync"]
    if tracked:
        return [
            "git tracks foundry.lock, and the working tree does not have it, so the next checkout brings it back\n"
            "  Repair: git rm foundry.lock (this records the deletion), then yarn dep sync"
        ]
    if present:
        return [
            "foundry.lock is in the working tree, and git does not track it\n  Repair: rm foundry.lock, then yarn dep sync"
        ]
    return []


# a forge-config comment, `// forge-config: <profile>.<key> = <value>`, in either comment form
_INLINE_CONFIG = re.compile(r"^\s*//+\s*forge-config:\s*(?P<setting>[\w-]+\.(?P<key>[\w.-]+?)\s*=\s*.*?)\s*$")
# the settings a test may set for itself: a property of the test, not the runs' to choose
_TEST_OWN_SETTINGS = ("allow_internal_expect_revert",)


def inline_config_problems(repo_root: Path) -> list[str]:
    """`forge-config:` comments in the source, test and script directories that set a fuzz or invariant
    parameter for one test. Such a line is applied last, for that test alone, over foundry.toml, the
    environment and the command line - verified on forge 1.8.7 for the environment and for a command-line
    flag - so it replaces what yarn test, gas and coverage chose: the fuzz seed and runs, and the invariant
    settings (bin/forge_test_runs.py). A setting that is the test's own, allow_internal_expect_revert, is
    left alone. Returns one block listing each line, or [] when no test sets a run's parameter."""
    found: list[str] = []
    for directory in forge_source_directories(repo_root):
        for path in sorted((repo_root / directory).rglob("*.sol")):
            for number, line in enumerate(path.read_text().splitlines(), 1):
                matched = _INLINE_CONFIG.match(line)
                if matched and matched["key"] not in _TEST_OWN_SETTINGS:
                    found.append(f"{path.relative_to(repo_root).as_posix()}:{number}  {matched['setting']}")
    if not found:
        return []
    lines = ["These tests set a fuzz or invariant parameter for themselves, replacing what the run chose:"]
    lines.extend(f"  {entry}" for entry in found)
    lines.append("  Repair: delete each line. yarn test, gas and coverage set these for every test.")
    return ["\n".join(lines)]


# a fork cheatcode, or BaoTest's wrapper over it, given the endpoint's name as a literal
_FORK_ENDPOINT = re.compile(r'\b(?:(?:createSelectFork|createFork)(?:AtTransaction)?|rpcUrl)\(\s*"(?P<name>[^"]*)"')
# bao-base's test helpers, compiled into every project's tests: BaoTest.forkMainnetWithBaoFactory names its endpoint
# here, and BaoTest's fork wrappers end in the cheatcode here
_INHERITED_FORK_HELPERS = (Path(__file__).resolve().parents[1] / "test" / "BaoTest.sol",)
# the list BaoTest takes every fork from, at the path BaoTest.forkBlocksFile names, relative to the project root
_FORK_BLOCKS = PurePath("test/fork-blocks.toml")
# the most blocks and transactions a list holds before doctor complains: each is a cache of its own, fetched from
# the provider on every machine's first run, and a burst of requests from every suite forking at it
_FORK_POSITIONS_LIMIT = 8
# a fork taken by the cheatcode, at a block the list need not hold
_FORK_CHEATCODE = re.compile(r"\b(?P<call>_?vm\.(?:createSelectFork|createFork|rollFork))\s*\(")
# a fork taken either way
_FORK_CALL = re.compile(r"\b(?:_?vm\.)?(?:createSelectFork|createFork)(?:AtTransaction)?\s*\(")


def fork_endpoint_problems(repo_root: Path) -> list[str]:
    """Forks naming an endpoint that `forge config`'s [rpc_endpoints] does not have. A test or script names the
    endpoint of a fork it creates by an entry's alias - the form that gives the fork the entry's retries, where
    the URL `vm.rpcUrl` returns loses them (bug-reports/foundry-1-9-0-cheatcode-fork-retry-settings.md) - and
    forge fails the test at the fork's creation when no entry has the alias. The aliases are read where they
    are named: the source, test and script directories, and the bao-base test helpers a project's tests
    inherit. A literal URL names no entry and is left alone. Returns one block listing each line, or [] when
    every alias named has an entry."""
    entries = forge_config(repo_root).get("rpc_endpoints", {})
    root = repo_root.resolve()
    files: dict[Path, None] = {}
    for directory in forge_source_directories(repo_root):
        for path in sorted((repo_root / directory).rglob("*.sol")):
            files.setdefault(path.resolve())
    for helper in _INHERITED_FORK_HELPERS:
        files.setdefault(helper.resolve())
    found: list[str] = []
    for path in files:
        shown = path.relative_to(root).as_posix() if path.is_relative_to(root) else path.as_posix()
        for number, line in enumerate(path.read_text().splitlines(), 1):
            for matched in _FORK_ENDPOINT.finditer(line):
                if "://" not in matched["name"] and matched["name"] not in entries:
                    found.append(f'{shown}:{number}  "{matched["name"]}"')
    if not found:
        return []
    lines = ["These forks name an endpoint that foundry.toml's [rpc_endpoints] does not have:"]
    lines.extend(f"  {entry}" for entry in found)
    lines.append("  Repair: add an entry for each alias to [rpc_endpoints] in foundry.toml, or name one that is there.")
    return ["\n".join(lines)]


def _test_files(repo_root: Path) -> list[Path]:
    """Every Solidity file in the test directory forge resolves, bao-base's test helpers left out."""
    helpers = {helper.resolve() for helper in _INHERITED_FORK_HELPERS}
    directory = repo_root / forge_config(repo_root)["test"]
    return [path for path in sorted(directory.rglob("*.sol")) if path.resolve() not in helpers]


def fork_cheatcode_problems(repo_root: Path) -> list[str]:
    """Forks taken by a cheatcode in the test directory: `vm.createSelectFork`, `vm.createFork` and `vm.rollFork`,
    `_vm.` included. A fork in test code goes through BaoTest's createFork or createSelectFork, which take it at
    a block or transaction test/fork-blocks.toml lists and refuse any other; the cheatcode takes it at any block,
    listed or not. BaoTest's own wrappers, which end in the cheatcode, are left out, and so is script/: a
    campaign meets the chain's head, or a capture's block, by the cheatcode. Returns one block listing each
    line, or [] when every fork in the test directory goes through BaoTest."""
    found: list[str] = []
    for path in _test_files(repo_root):
        shown = path.relative_to(repo_root).as_posix()
        for number, line in enumerate(path.read_text().splitlines(), 1):
            for matched in _FORK_CHEATCODE.finditer(line):
                found.append(f"{shown}:{number}  {matched['call']}")
    if not found:
        return []
    lines = [f"These tests fork by a cheatcode, at a block {_FORK_BLOCKS.as_posix()} need not hold:"]
    lines.extend(f"  {entry}" for entry in found)
    lines.append(
        "  Repair: take the fork through BaoTest's createFork or createSelectFork, at a listed block, name or "
        "transaction; in place of rollFork, a second fork at a listed block."
    )
    return ["\n".join(lines)]


def fork_blocks_list_problems(repo_root: Path) -> list[str]:
    """test/fork-blocks.toml, the blocks and transactions BaoTest takes a fork at: it holds a block named
    `default`, names none `latest` - the name of the highest block listed - and holds at most 8 blocks and
    transactions together, each being a cache of its own, fetched from the provider on every machine's first
    run, and a burst of requests from every suite forking at it. Each block is a number and each transaction a
    32-byte hash, as BaoTest parses them. A test directory that forks with no list is reported too. Returns
    one problem a line, or [] when the list is as described, or absent where nothing forks."""
    file = repo_root / _FORK_BLOCKS
    shown = _FORK_BLOCKS.as_posix()
    if not file.is_file():
        forking = [
            path.relative_to(repo_root).as_posix()
            for path in _test_files(repo_root)
            if _FORK_CALL.search(path.read_text())
        ]
        if not forking:
            return []
        return [
            f"{shown} is not there, and these tests fork: {', '.join(forking)}.\n"
            f"  Repair: write {shown} with [blocks] and a block named default, any block after the last deployment "
            f"the tests read."
        ]
    listed = load_toml(file)
    problems: list[str] = []
    tables: dict[str, dict[str, Any]] = {}
    for table in ("blocks", "transactions"):
        value = listed.get(table, {})
        if isinstance(value, dict):
            tables[table] = cast(dict[str, Any], value)
        else:
            problems.append(f"{shown}: [{table}] is {value!r}, not a table of name = value entries.")
            tables[table] = {}
    blocks, transactions = tables["blocks"], tables["transactions"]
    if "default" not in blocks:
        problems.append(f'{shown} has no block named "default", the block for every test the block does not matter to.')
    if "latest" in blocks:
        problems.append(f'{shown} names a block "latest", the name of the highest block listed.')
    for name, value in blocks.items():
        if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
            problems.append(f'{shown}: block "{name}" is {value!r}, not a block number.')
    for name, value in transactions.items():
        if not isinstance(value, str) or not re.fullmatch(r"0x[0-9a-fA-F]{64}", value):
            problems.append(f'{shown}: transaction "{name}" is {value!r}, not a 32-byte hash.')
    count = len(blocks) + len(transactions)
    if count > _FORK_POSITIONS_LIMIT:
        problems.append(
            f"{shown} lists {count} blocks and transactions; doctor's limit is {_FORK_POSITIONS_LIMIT}. Each is a "
            f"cache of its own and a burst of requests from every suite forking at it.\n"
            f"  Repair: fork at a block already listed where the block does not matter, and drop the entries no test "
            f"names."
        )
    return problems


def fork_blocks_permission_problems(repo_root: Path) -> list[str]:
    """test/fork-blocks.toml, which BaoTest reads at every fork a test takes, is under a path an fs_permissions
    entry in foundry.toml grants read access to: forge refuses a read elsewhere. The entries are read as
    `forge config` reports them, an access of "read" or "read-write", the latter printed as true. Returns one
    problem naming the file, or [] when an entry covers it or the file is not there."""
    file = repo_root / _FORK_BLOCKS
    if not file.is_file():
        return []
    for entry in forge_config(repo_root).get("fs_permissions", []):
        grants_read = entry.get("access") in ("read", "read-write", True)
        if grants_read and file.resolve().is_relative_to((repo_root / entry["path"]).resolve()):
            return []
    shown = _FORK_BLOCKS.as_posix()
    return [
        f"{shown} is read by every fork a test takes, and no fs_permissions entry in foundry.toml grants read "
        f"access to a path holding it.\n"
        f'  Repair: add {{ access = "read", path = "./{shown}" }} to fs_permissions in foundry.toml.'
    ]


def wake_scope_problems(repo_root: Path) -> list[str]:
    """Solidity files wake compiles that forge does not build. Wake compiles every `*.sol` in the project
    that `compiler.solc.exclude_paths` does not cover, found by a recursive glob: directories and files
    whose names start with a dot are skipped, symlinked directories are followed, and an exclusion covers
    whole path components, so `lib` covers lib/ and not library/. Forge builds its source, test and script
    directories and what they import. Excluding a path never hides code forge builds, because wake still
    compiles an excluded file that a compiled one imports.

    Each finding names the path to exclude: the shallowest one holding none of forge's directories, so
    the file itself when it sits directly beside one. A wake.toml whose exclusions cannot be read is this
    check's finding, the key's absence included: wake then applies a built-in default that is wake's to
    change. Returns one block listing each path with the number of files under it; [] when wake compiles
    only what forge builds."""
    wake_path = repo_root / "wake.toml"
    if not wake_path.is_file():
        return [f"{wake_path} is missing, so doctor cannot tell which files wake compiles."]
    exclude_paths = load_toml(wake_path).get("compiler", {}).get("solc", {}).get("exclude_paths")
    if exclude_paths is None:
        return ["wake.toml does not set compiler.solc.exclude_paths, so doctor cannot tell which files wake compiles."]
    if not isinstance(exclude_paths, list) or not all(isinstance(path, str) for path in cast(list[Any], exclude_paths)):
        return [
            f"compiler.solc.exclude_paths in wake.toml is {exclude_paths!r}, not a list of paths, so doctor "
            f"cannot tell which files wake compiles."
        ]

    # wake resolves each exclusion and compares the paths its glob finds, unresolved, against them
    excluded = [(repo_root / path).resolve() for path in cast(list[str], exclude_paths)]
    directories = forge_source_directories(repo_root)
    built = [repo_root / directory for directory in directories]
    unbuilt: Counter[PurePath] = Counter()
    for directory, subdirectories, files in os.walk(repo_root, followlinks=True):
        here = Path(directory)
        subdirectories[:] = [
            name
            for name in subdirectories
            if not name.startswith(".") and not any((here / name).is_relative_to(path) for path in excluded + built)
        ]
        for name in files:
            if name.startswith(".") or not name.endswith(".sol"):
                continue
            if any((here / name).is_relative_to(path) for path in excluded + built):
                continue
            parts = (here / name).relative_to(repo_root).parts
            unbuilt[
                next(
                    PurePath(*parts[:depth])
                    for depth in range(1, len(parts) + 1)
                    if not any(path.is_relative_to(repo_root.joinpath(*parts[:depth])) for path in built)
                )
            ] += 1
    if not unbuilt:
        return []

    lines = ["wake compiles these Solidity files, but forge does not build them:"]
    lines += columns.rows(
        [[path.as_posix(), f"{count} file{'' if count == 1 else 's'}"] for path, count in sorted(unbuilt.items())],
        indent="  ",
    )
    lines.append(
        "  Repair: add each path above to compiler.solc.exclude_paths in wake.toml. If the code should be "
        f"built, move it under {', '.join(directories[:-1])} or {directories[-1]} instead."
    )
    return ["\n".join(lines)]


def submodule_url_drift_problems(repo_root: Path) -> list[str]:
    """`submodule_url_drift` formatted as a problem block. Returns [] when URLs agree."""
    drift = submodule_url_drift(repo_root)
    if not drift:
        return []
    lines = ["These submodules have a different URL in .git/config than in .gitmodules:"]
    for display, gitmodules_url, gitconfig_url in drift:
        lines.append(f"  {display}")
        lines.append(f"    .git/config: {gitconfig_url}")
        lines.append(f"    .gitmodules: {gitmodules_url}")
    lines.append("Repair: yarn dep sync (this copies the URLs from .gitmodules to .git/config)")
    return ["\n".join(lines)]


def tracked_but_ignored_problems(repo_root: Path) -> list[str]:
    """Files the exclude rules match that git nonetheless tracks. Ignore rules apply only to untracked
    paths, so once a file is in the index the rule does nothing: edits keep appearing in `git status`
    and keep being committed, while the rule reads as a protection it is not providing. This is the
    state a file lands in whenever it was committed before the rule was written. Top-level repo only —
    recursing would report third-party submodules, whose tracking is not ours to change. Read-only:
    `git ls-files -i -c` lists the tracked paths the exclude rules match, and `git check-ignore` names
    the rule matching each — it needs `--no-index`, which is what makes it answer for tracked paths at
    all. Returns one block naming each file and its rule; [] when nothing tracked is ignored."""
    listing = subprocess.run(
        ["git", "ls-files", "-i", "-c", "--exclude-standard", "-z"],
        cwd=repo_root,
        capture_output=True,
        text=True,
    )
    paths = [path for path in listing.stdout.split("\0") if path]
    if not paths:
        return []

    matches = subprocess.run(
        ["git", "check-ignore", "--no-index", "-v", "-z", "--stdin"],
        cwd=repo_root,
        input="\0".join(paths) + "\0",
        capture_output=True,
        text=True,
    )
    # `-v -z` emits four NUL-separated fields per match: source file, line number, pattern, pathname.
    fields = matches.stdout.split("\0")
    rule_for: dict[str, str] = {}
    for index in range(0, len(fields) - 3, 4):
        source, line_number, pattern, path = fields[index : index + 4]
        rule_for[path] = f"{source}:{line_number}  {pattern}"

    # Group by rule: one wildcard usually catches a whole set, and the decision (untrack the files, or
    # narrow the rule) is made per rule — so listing the rule once above its files is both shorter and
    # the shape the reader acts on.
    by_rule: dict[str, list[str]] = {}
    for path in paths:
        by_rule.setdefault(rule_for.get(path, "(no rule reported by git check-ignore)"), []).append(path)

    lines = [
        "git tracks these files, but an ignore rule matches them. The rule does nothing while git tracks the file:"
    ]
    for rule, matched in by_rule.items():
        lines.append(f"  {rule}")
        for path in matched:
            lines.append(f"    {path}")
    # Which side is wrong — the tracking or the rule — is intent the doctor cannot know, so offer both.
    lines.append(
        "  Repair: to stop git tracking them, run "
        "`git ls-files -i -c --exclude-standard -z | xargs -0 git rm --cached`, then commit. Your copies stay "
        "on this computer. Other clones DELETE their copies when they pull that commit: the ignore rule does "
        "not keep them. To keep the files in the repository instead, change the ignore rule so it no longer "
        "matches them."
    )
    return ["\n".join(lines)]


# an upgrade annotation names a predecessor that validate compiles: a use of that file no import shows
_UPGRADE_REFERENCE = re.compile(r"@custom:(?:oz|bao)-upgrades-from\s+(\S+\.sol):")
# directories a tool builds by path: bin/sizes builds test/_sizes, the Python tests build test/fixtures
_TOOL_BUILT_DIRECTORIES = ("test/_sizes/", "test/fixtures/")
# one line of `forge tree --charset ascii`: four characters of indent per level below the first, a branch on
# every line below the top level, the source, then its version requirement when it has a pragma (and " (*)"
# on a file already expanded above, not needed here: its imports are read where it was expanded)
_TREE_LINE = re.compile(r"^(?P<indent>(?:\|   |    )*)(?P<branch>[|`]-- )?(?P<path>\S+\.(?:sol|vy|vyi))(?: .*)?$")


def unused_file_problems(repo_root: Path) -> list[str]:
    """Solidity files in the source, test and script directories that nothing reaches. Reached means
    used, transitively, by an entry point: a test (`*.t.sol`), a script (`*.s.sol`), or a file in a
    directory a tool builds by path. A file is used by the files that import it, and by any whose
    `@custom:oz-upgrades-from` / `@custom:bao-upgrades-from` names it. Reachability rather than "imported
    by nothing" lists a chain of unused files in one run, rather than one layer per removal.

    The imports are forge's own, from `forge tree`, already resolved through the remappings, without
    compiling: about 2 s on harbor. A build cache is no substitute, because under `deny = "warnings"`
    forge keeps none (foundry-rs/foundry#17202). `forge tree` does not validate sources — an import that
    does not resolve is left out rather than reported — which the build and the remapping check catch.
    Its top level lists every project source; that list must match the disk, since a source it omits
    would be judged on no data. A failure of `forge tree`, a line it prints that is not understood, or a
    disagreement with the disk is this check's finding: the import graph is then unknown. Returns one
    block listing each unused file; [] when every file is reached."""
    tree = subprocess.run(["forge", "tree", "--charset", "ascii"], cwd=repo_root, capture_output=True, text=True)
    if tree.returncode != 0:
        output = "\n".join(f"  {line}" for line in (tree.stdout + tree.stderr).strip().splitlines())
        return [f"forge tree failed, so doctor cannot tell which files are unused:\n{output}"]
    uses: dict[str, set[str]] = {}
    listed: set[str] = set()
    ancestors: list[str] = []  # the path at each depth above the current line
    for line in tree.stdout.splitlines():
        parsed = _TREE_LINE.match(line)
        depth = 0 if parsed is None or parsed["branch"] is None else len(parsed["indent"]) // 4 + 1
        if parsed is None or (parsed["branch"] is None and parsed["indent"]) or depth > len(ancestors):
            return [
                f"forge tree printed a line doctor does not understand, so doctor cannot tell which files are unused:\n  {line}"
            ]
        if depth == 0:
            listed.add(parsed["path"])
        else:
            uses.setdefault(ancestors[depth - 1], set()).add(parsed["path"])
        del ancestors[depth:]
        ancestors.append(parsed["path"])

    source_directories = tuple(f"{directory}/" for directory in forge_source_directories(repo_root))
    on_disk = {
        path.relative_to(repo_root).as_posix()
        for directory in source_directories
        for path in (repo_root / directory).rglob("*.sol")
    }
    in_tree = {path for path in listed if path.startswith(source_directories)}
    if on_disk != in_tree:
        lines = [
            "forge tree lists different source files from the ones on disk, so doctor cannot tell which files are unused:"
        ]
        lines += [f"  on disk but not in forge tree: {path}" for path in sorted(on_disk - in_tree)]
        lines += [f"  in forge tree but not on disk: {path}" for path in sorted(in_tree - on_disk)]
        return ["\n".join(lines)]

    own = sorted(on_disk)
    for path in own:
        uses.setdefault(path, set()).update(_UPGRADE_REFERENCE.findall((repo_root / path).read_text()))

    reached = {path for path in own if path.endswith((".t.sol", ".s.sol")) or path.startswith(_TOOL_BUILT_DIRECTORIES)}
    pending = list(reached)
    while pending:
        for used in uses.get(pending.pop(), ()):
            if used not in reached:
                reached.add(used)
                pending.append(used)
    unused = [path for path in own if path not in reached]
    if not unused:
        return []

    lines = ["No test, script, test/_sizes/ or test/fixtures/ file uses these, directly or through other files:"]
    for path in unused:
        # every user of an unused file is itself unused, else the file would have been reached
        users = [user for user in unused if path in uses[user]]
        lines.append(f"  {path}" + (f"  (used only by {', '.join(users)})" if users else ""))
    lines.append(
        "  Repair: first check that no other repository uses the file. A repository that depends on this one "
        "may import it, or use it from Python through wake's pytypes, and doctor cannot see either. Then "
        "delete the file, or move it to deprecated/<its path> and record what replaced it. The owner of the "
        "code decides which. A file that only other files in this list use goes with them."
    )
    return ["\n".join(lines)]


def vscode_ruff_settings_problems(repo_root: Path) -> list[str]:
    """Check .vscode/settings.json wires the editor to bao-base's shared ruff, matching bao-base's own
    canonical settings. ruff.path is a per-workspace path (a consumer's under `lib/bao-base/` vs
    bao-base's own) that must RESOLVE to the same file; the [python] block and the other checked ruff.*
    settings (e.g. ruff.configuration) are shared literals matched verbatim. bao-base's own
    .vscode/settings.json is the source of truth: run inside bao-base the two are one file, so it
    compares against itself and passes. Returns the mismatches, or [] when the settings are present and
    agree."""
    bao_base_root = Path(__file__).resolve().parent.parent
    canonical_file = bao_base_root / ".vscode" / "settings.json"
    repo_file = repo_root / ".vscode" / "settings.json"

    if not canonical_file.is_file():
        return [f"bao-base has no {canonical_file} to compare against."]
    if not repo_file.is_file():
        return [f"{repo_file} is missing. The editor needs it to use bao-base's ruff."]

    try:
        repo = json5.loads(repo_file.read_text())
    except ValueError as exc:
        return [f"{repo_file} is not valid JSON5: {exc}"]
    canonical = json5.loads(canonical_file.read_text())

    absent: list[str] = []
    if "[python]" not in repo:
        absent.append('"[python]" block')
    if not any(key.startswith("ruff.") for key in repo):
        absent.append('"ruff.*" settings')
    if absent:
        return [f"{repo_file} is missing " + " and ".join(absent) + "."]

    problems: list[str] = []
    if repo.get("[python]") != canonical.get("[python]"):
        problems.append(f'"[python]" is {repo.get("[python]")!r}, but bao-base has {canonical.get("[python]")!r}')

    # ruff.path is a per-workspace path to the shared ruff, so compare it RESOLVED to an absolute path
    # (a consumer reaches it via lib/bao-base/); the other checked ruff.* keys are shared literals,
    # compared verbatim. ruff.interpreter is the editor's own concern, not shared wiring — not checked.
    resolved_keys = ("ruff.path",)
    for key in sorted(name for name in canonical if name.startswith("ruff.") and name != "ruff.interpreter"):
        canonical_value = canonical.get(key)
        repo_value = repo.get(key)
        if key in resolved_keys:
            canonical_paths = [str((bao_base_root / entry).resolve()) for entry in (canonical_value or [])]
            repo_paths = [str((repo_root / entry).resolve()) for entry in (repo_value or [])]
            if repo_paths != canonical_paths:
                problems.append(
                    f'"{key}" is {repo_value!r}, which leads to {repo_paths}. bao-base has '
                    f"{canonical_value!r}, which leads to {canonical_paths}"
                )
        elif repo_value != canonical_value:
            problems.append(f'"{key}" is {repo_value!r}, but bao-base has {canonical_value!r}')

    return problems


def ruff_settings_problems(repo_root: Path) -> list[str]:
    """Check this repository's ruff settings extend bao-base's, so ruff - in the editor and on the command line -
    checks and formats by bao-base's rules and stays out of lib. ruff reads the first of .ruff.toml, ruff.toml and
    a pyproject.toml holding [tool.ruff] in a folder, so that is the one checked. `extend` is compared RESOLVED,
    as `ruff.path` is: a consumer reaches bao-base through lib/bao-base/. Inside bao-base the shared settings are
    the repository's own, so there is nothing to extend. Returns the problem, or [] when the settings extend
    bao-base's."""
    bao_base_root = Path(__file__).resolve().parent.parent
    shared = bao_base_root / "pyproject.toml"
    root = repo_root.resolve()
    if root == bao_base_root:
        return []
    # bao-base by the folder this repository declares for it, so the repair is the line to write.
    reached = next(
        (entry.path for entry in declared_submodules(root) if (root / entry.path).resolve() == bao_base_root),
        os.path.relpath(bao_base_root, root),
    )
    wanted = f'extend = "{reached}/pyproject.toml"'

    settings: dict[str, Any] | None = None
    where = ""
    for name in (".ruff.toml", "ruff.toml"):
        if (root / name).is_file():
            settings, where = load_toml(root / name), name
            break
    else:
        pyproject = root / "pyproject.toml"
        settings = load_toml(pyproject).get("tool", {}).get("ruff") if pyproject.is_file() else None
        where = "[tool.ruff] in pyproject.toml"
    if settings is None:
        return [
            "This repository has no ruff settings: no .ruff.toml, no ruff.toml and no [tool.ruff] in pyproject.toml.\n"
            f"  Repair: add [tool.ruff] to pyproject.toml, with {wanted}"
        ]
    extend = settings.get("extend")
    if extend is None:
        return [f"{where} does not extend bao-base's ruff settings.\n  Repair: add {wanted} to {where}"]
    leads_to = (root / extend).resolve()
    if leads_to != shared:
        return [
            f'{where} extends "{extend}", which leads to {leads_to}, not to bao-base\'s {shared}.\n'
            f"  Repair: set {wanted} in {where}"
        ]
    return []


_CLAUDE_LOCAL_SETTINGS = ".claude/settings.local.json"

# CLAUDE.md *requires* committing to the plan repo after every plan update, so a rule reaching it is
# the documented working mode rather than an over-grant. Hardcoded rather than left to an ignore
# file: a check that flags its own instructions is one a developer switches off wholesale, and then
# it catches nothing at all.
_CLAUDE_PERMITTED_OUTSIDE_PATHS = (Path.home() / ".claude" / "plans",)

# Commands that change state outside the working tree, or reach the network. A wildcard on one of
# these grants far more than any single task needs; name them explicitly rather than guessing at
# "dangerous", so the check stays predictable and argues its case when it fires.
_STATE_CHANGING_COMMANDS = ("chmod", "chown", "rm", "mv", "dd", "curl", "wget", "sudo", "git push")


def claude_local_settings_problems(repo_root: Path) -> list[str]:
    """`.claude/settings.local.json` is a per-machine override, so it must be untracked AND ignored.
    Committing it publishes one developer's permission grants to everyone and turns them into source
    that outlives the session that needed them. Both halves are checked because each alone is
    insufficient: untracking without ignoring lets the next `git add .` bring it back, and ignoring a
    file already in the index does nothing to it. Returns [] when the file is absent, or present and
    both untracked and ignored."""
    path = repo_root / _CLAUDE_LOCAL_SETTINGS
    problems: list[str] = []

    tracked = (
        subprocess.run(
            ["git", "ls-files", "--error-unmatch", _CLAUDE_LOCAL_SETTINGS],
            cwd=repo_root,
            capture_output=True,
            text=True,
        ).returncode
        == 0
    )
    if tracked:
        problems.append(
            f"git tracks {_CLAUDE_LOCAL_SETTINGS}. It holds this computer's own settings, so it should not "
            f"be in the repository.\n"
            f"  Repair: git rm --cached {_CLAUDE_LOCAL_SETTINGS}  (this removes the file from the repository "
            f"and keeps your copy)"
        )

    if path.is_file():
        # The rule has to live in a .gitignore INSIDE the repo, because that is the only kind that
        # travels with a clone. A personal ~/.gitignore_global covers the author's machine and
        # nobody else's, so `git check-ignore` alone would report the repo protected while every
        # teammate can still commit the file — which is how one gets committed in the first place.
        # --no-index answers from the ignore rules regardless of tracking, keeping the two halves of
        # this check independent. -v names the source of the match, which is what is judged here.
        matched = subprocess.run(
            ["git", "check-ignore", "--no-index", "-v", _CLAUDE_LOCAL_SETTINGS],
            cwd=repo_root,
            capture_output=True,
            text=True,
        )
        source = matched.stdout.split(":", 1)[0] if matched.returncode == 0 else ""
        # `.git/info/exclude` is machine-local too, so it is not accepted either.
        travels = bool(source) and not Path(source).is_absolute() and not source.startswith(".git/")
        if not travels:
            matched_only_by = f" Only {source} matches it, and other clones do not have that file." if source else ""
            problems.append(
                f"{_CLAUDE_LOCAL_SETTINGS} exists, but no ignore rule in this repository matches it."
                f"{matched_only_by} So anyone who clones the repository can commit the file by mistake.\n"
                f"  Repair: echo '{_CLAUDE_LOCAL_SETTINGS}' >> .gitignore"
            )

    return problems


def _permission_rule_reasons(rule: str, repo_root: Path) -> list[str]:
    """Every reason `rule` grants more than work in this repository needs — a rule can fail on more
    than one count, and reporting only the first sends the reader round the loop again after they fix
    it. Scope and portability are independent: a path can be correctly scoped yet still spelled in a
    way that works on one machine only, so the plan-repo exemption suppresses the scope reason alone.
    Returns [] for an adequately scoped rule."""
    parsed = re.fullmatch(r"(\w+)\((.*)\)", rule, re.S)
    if not parsed:
        return []  # a bare tool grant (e.g. `WebSearch`) carries no path or command to over-scope
    tool, argument = parsed.group(1), parsed.group(2)
    reasons: list[str] = []

    if tool in ("Read", "Edit", "Write"):
        # Claude writes an absolute path as `//abs/path`; anything relative is repo-scoped already.
        if not argument.startswith(("//", "/", "~")):
            return []
        # The fixed prefix, before any wildcard. `~` must stay leading for expanduser() to expand it,
        # so only the `//abs/path` form gets its single leading slash restored.
        normalised = argument if argument.startswith("~") else "/" + argument.lstrip("/")
        target = Path(re.split(r"[*?]", normalised)[0]).expanduser()

        permitted = any(target.is_relative_to(allowed) for allowed in _CLAUDE_PERMITTED_OUTSIDE_PATHS)
        if not permitted and not target.is_relative_to(repo_root):
            reasons.append(
                f"reaches {target}, which is outside this repository. Work in this repository does not "
                f"need it, and the rule applies to every future session."
            )
        # A literal /home/<user>/… names one machine and one account, so the file cannot be shared,
        # copied to another checkout, or used by anyone else. `~` is the portable spelling and
        # resolves to the same place. Independent of scope: it applies to permitted paths too.
        if not argument.startswith("~") and target.is_relative_to(Path.home()):
            portable = "~/" + str(target.relative_to(Path.home()))
            reasons.append(
                f"writes out the home folder in full, which exists only for one user on one computer. "
                f"Write it as `{portable}…` instead."
            )

    if tool == "Bash":
        if argument.rstrip().endswith(" *"):
            reasons.append(
                "ends in a space and `*`, so it matches any text after the command, including "
                "`&& rm -rf ~`. Limit the arguments, or name the exact command."
            )
        for command in _STATE_CHANGING_COMMANDS:
            if re.match(rf"^{re.escape(command)}\b.*[:\s]\*", argument):
                reasons.append(
                    f"uses `*` with `{command}`, which can change files outside the repository or use "
                    f"the network. Allow only the exact command you need."
                )

    return reasons


def claude_permission_scope_problems(repo_root: Path) -> list[str]:
    """Allow-rules in `.claude/settings.json` / `.claude/settings.local.json` that grant more than
    work in this repository needs. Four shapes are flagged: a path outside the repo, a path
    hardcoding `/home/<user>/…` where `~` would be portable, a Bash rule ending in ` *` (which
    matches any shell continuation), and a wildcard on a state-changing command. A rule failing on
    several counts reports all of them. Rules reaching the plan repo are exempt from the scope
    check — CLAUDE.md requires them — but not from the others. Returns [] when no settings file
    exists or every rule is adequately scoped."""
    problems: list[str] = []
    for name in ("settings.json", _CLAUDE_LOCAL_SETTINGS.rsplit("/", 1)[1]):
        settings_file = repo_root / ".claude" / name
        if not settings_file.is_file():
            continue
        # Only a TRACKED settings file is this repository's business. The reason to police these
        # grants is that they reach everyone who clones and outlive the session that needed them —
        # true of a file in the index, and of nothing else. Untracked, it is one developer's own
        # machine, and doctor reports on repositories. Checking it anyway would also set the two
        # `.claude` checks against each other: untracking is the fix its sibling asks for, and it
        # would leave this one red for good, which is how a check stops being read.
        tracked = (
            subprocess.run(
                ["git", "ls-files", "--error-unmatch", f".claude/{name}"],
                cwd=repo_root,
                capture_output=True,
                text=True,
                check=False,  # a non-zero return IS the answer: the file is untracked
            ).returncode
            == 0
        )
        if not tracked:
            continue
        try:
            settings = json5.loads(settings_file.read_text())
        except ValueError as exc:
            problems.append(f".claude/{name} is not valid JSON: {exc}")
            continue
        allow = settings.get("permissions", {}).get("allow", [])
        found = [
            f"{rule}\n" + "\n".join(f"    {reason}" for reason in reasons)
            for rule in allow
            if (reasons := _permission_rule_reasons(rule, repo_root))
        ]
        if found:
            problems.append(
                f".claude/{name}: {len(found)} of the {len(allow)} rules in permissions.allow give more access "
                f"than work in this repository needs:\n  " + "\n  ".join(found)
            )
    return problems


def build_checks(
    repo_root: Path, foundry_remappings: list[str], wake_remappings: list[str], unused_files: bool
) -> list[Check]:
    """Every check doctor runs, in report order. Separate from `main` so the list is a value that can
    be asserted on: a check function that is written but never added here silently never runs, and
    reads as covered — which is exactly what happened to `tracked_but_ignored_problems`.

    Each check names what it verifies, why that matters, what a failure costs, and its problems; it
    passes when there are none. `why` and `cost` are read on the failing path, and `yarn doctor -v`
    puts `why` back on every check — see `checks.report`.

    The unused-file check runs only when `unused_files` asks for it (`yarn doctor --unused-files`): it
    sees uses within this repo only, so a file another repo imports, or Python reaches through wake's
    pytypes, is listed as unused, and a plain run would fail on files that are in use.

    The submodule traversal runs once and its findings are split, because it walks every submodule
    and runs git in each; calling it per check would double that to say the same things."""
    # What forge resolves, as `yarn dep` reads it, so the two judge the same nested paths.
    remappings: list[str] = forge_config(repo_root)["remappings"]
    version_problems, leftover_problems = submodule_problems(repo_root, remappings)
    checks = [
        Check(
            "forge uses only the remappings in foundry.toml",
            "When auto_detect_remappings is on, forge adds remappings of its own. It makes them from the "
            "library folders it finds, including folders inside submodules. So an import can use a different "
            "library on each computer, depending on what is checked out there. Also, the wake check below "
            "compares only the remappings that foundry.toml lists",
            "a build can use a library version that this project did not choose, it can differ between "
            "computers, and wake checks a different program from the one forge builds",
            remapping_detection_problems(repo_root),
        ),
        Check(
            "a script's simulation keeps the block gas limit check",
            "disable_block_gas_limit in foundry.toml reaches every forge run, forge script included. A script's "
            "simulation then no longer checks that each transaction fits a block. The test runs need the lift, "
            "one call running a whole deploy or upgrade exceeding a forked block's gas limit, and ask for it on "
            "their command line, where no script sees it",
            "a transaction too large for a block passes simulation and fails when it is sent",
            block_gas_limit_problems(repo_root),
        ),
        Check(
            "a build fails on a compiler warning",
            "yarn test passes --deny never to keep its build cache, and yarn gas passes --deny warnings and is the "
            "run that fails on one. foundry.toml's deny reaches the builds those runs do not make: forge build by "
            "hand, and the build a script makes before it runs",
            "a warning the gas run would fail on passes unseen in a build by hand or in a deploy",
            deny_warnings_problems(repo_root),
        ),
        Check(
            "wake.toml has the same remappings as foundry.toml",
            "wake must find each import in the same file as forge. Otherwise wake checks a different program "
            "from the one forge builds",
            "until they agree, any wake finding may be about code that is not built, or may miss code that is",
            remapping_problems(foundry_remappings, wake_remappings),
        ),
        Check(
            "every remapping points to a folder that exists",
            "A remapping to a folder that no submodule provides cannot work for any import. But it looks like "
            "something the build needs. If the folder is inside a submodule, yarn dep will never check it out",
            "people and tools believe the build uses code that does not exist, and the remapping stays to "
            "confuse the next person who reads it",
            remapping_target_problems(repo_root, remappings),
        ),
        Check(
            "wake compiles only what forge builds",
            "wake compiles every Solidity file in the project unless exclude_paths in wake.toml lists it. forge "
            "builds only its source, test and script folders and the files they import. So wake also checks "
            "files that nothing builds, such as an old file kept in deprecated/, a scratch copy, or a tool's output",
            "the editor shows errors and findings for code that is never built, mixed with those for code that is",
            wake_scope_problems(repo_root),
        ),
        Check(
            "submodule URLs in .git/config match .gitmodules",
            "git fetches a submodule from the URL in .git/config, not from the URL in .gitmodules. If they are "
            "different, your copy comes from a place that other people do not use",
            "your builds work and other people's fail, although the code looks the same",
            submodule_url_drift_problems(repo_root),
        ),
        Check(
            "each submodule folder has the commit this repository points to",
            "Each submodule folder should have the commit that this repository points to. yarn dep update moves "
            "a submodule; git add and git commit record where this repository points. This also applies to a submodule inside "
            "another submodule when a remapping uses it. Doctor does not need you to commit first",
            "if they are different, you build one version but save another, and everyone who clones the "
            "repository gets the saved one",
            version_problems,
        ),
        Check(
            "every commit this repository points to is on a remote",
            "A commit that only this computer has cannot be fetched by anyone else. The check above passes when "
            "the folder has the commit this repository points to, even when no remote holds that commit",
            "once this repository is pushed, CI and every other clone fail to check the submodule out, and only "
            "this computer can repair it",
            unpublished_commit_problems(repo_root, remappings),
        ),
        Check(
            "no git setting makes a push send tags that were not named",
            "verify-audit --push sends only the deployment tags the record derives, each by name. push.followTags "
            "makes git push also send every annotated tag on the commits it pushes. A remote set to mirror is sent "
            "every tag, and loses each tag this clone lacks. A push refspec that covers refs/tags sends every tag it "
            "covers. Each dependency checkout has its own config, so each is read too",
            "a tag made for a moment on one computer is published to everyone, and a mirror push deletes "
            "published tags that this clone does not hold",
            tag_push_setting_problems(repo_root),
        ),
        Check(
            "every deployment tag the record derives is on origin, as it is here",
            "verify-audit and verify-audit --write read only this clone, and CI reads only what was pushed. So a "
            "deployment tag made here and not pushed passes here and fails in CI. git keeps no copy of origin's "
            "tags, so doctor asks origin. A tag origin holds under a name the record no longer derives comes back "
            "with every fetch",
            "CI fails on the next push, and every clone that fetches gets the old tag back",
            deployment_tag_problems(repo_root),
        ),
        Check(
            "no submodule contains old git repositories",
            "When a submodule moves to a version that no longer uses one of its own submodules, git leaves "
            "that folder behind. Nothing removes it",
            "forge and git use the files that are there, not the files that should be there, so an old folder "
            "can still be used by imports",
            leftover_problems,
        ),
        Check(
            "inside each dependency, only the submodules the build reads are checked out",
            "The build reads a submodule inside a dependency only through a remapping. Any other one checked out "
            "there is left from an older recursive checkout, at whatever commit it had then",
            "it can be taken for code the build uses, and every tool that walks the submodules reads it",
            unused_checkout_problems(repo_root, remappings),
        ),
        Check(
            "no foundry.lock",
            "forge writes foundry.lock whenever it installs: on forge install and forge update, to record which "
            "branch or tag each dependency came from, and when build, test, coverage or script finds a dependency "
            "with nothing checked out in its folder, which it then installs with every nested submodule. "
            "Dependencies here are moved with yarn dep, which records that in .gitmodules and in the commit this "
            "repository points to, and leaves the lock as it was. forge reads the lock only when told to, with "
            "--locked. yarn dep sync leaves only the checkouts the build reads",
            "the lock names versions the dependencies left long ago, and forge --locked, or anyone who reads it, "
            "takes them for the current ones",
            foundry_lock_problems(repo_root),
        ),
        Check(
            "no test sets its own fuzz or invariant parameters",
            "yarn test, gas and coverage each choose the fuzz seed and runs and the invariant settings: gas "
            "measures the same calls each time, coverage compares its baseline exactly, and every run fails on a "
            "handler call that reverts. A forge-config comment in a test is applied last and replaces the run's "
            "choice for that test alone, whatever the run passed",
            "a baseline moves with no change to the code, one test's long run slows every run, and a handler "
            "whose calls revert can be made to pass",
            inline_config_problems(repo_root),
        ),
        Check(
            "every endpoint a fork names is in foundry.toml",
            "a test or script names the endpoint of a fork it creates by an alias in [rpc_endpoints], the form that "
            "gives the fork the entry's retries; forge resolves the alias when the fork is created, and fails the "
            "test when no entry has it",
            "every test creating that fork fails at its creation, on every machine without the entry",
            fork_endpoint_problems(repo_root),
        ),
        Check(
            "every fork in test code is at a block the list holds",
            "a fork in test code goes through BaoTest, which takes it only at a block or transaction "
            "test/fork-blocks.toml lists. A cheatcode fork is taken at any block, and the list does not see it: "
            "each block is a cache of its own, fetched from the provider on every machine's first run and a burst "
            "of requests from every suite forking at it",
            "the fork's block is not counted by the list, and at the chain's head is fetched from the provider on "
            "every run, on every machine",
            fork_cheatcode_problems(repo_root),
        ),
        Check(
            "test/fork-blocks.toml lists a default block and few others",
            "BaoTest forks at the block listed under default when a test does not care which, at the highest "
            "listed for latest, and at any other block or transaction only when listed; a block is a number and a "
            "transaction a hash, as BaoTest parses them. Few, because each is a cache and a burst of requests of "
            "its own",
            "a fork fails at its creation, or the provider's quota goes on blocks that could have been one",
            fork_blocks_list_problems(repo_root),
        ),
        Check(
            "forge lets the tests read test/fork-blocks.toml",
            "BaoTest reads the list at every fork a test takes, and forge allows a read only under a path an "
            "fs_permissions entry in foundry.toml grants",
            "every fork in every test fails at its creation",
            fork_blocks_permission_problems(repo_root),
        ),
        workflow_copy.check(repo_root),
        Check(
            ".vscode/settings.json uses bao-base's ruff",
            "with a different ruff, or none, the editor formats and checks Python by different rules from CI. "
            "Then the editor says a file is clean and CI says it is not",
            "CI fails on formatting in files the editor said were clean, and you find each one only after a push",
            vscode_ruff_settings_problems(repo_root),
        ),
        Check(
            "ruff's settings extend bao-base's",
            "ruff takes its settings from this repository: .ruff.toml, ruff.toml or [tool.ruff] in pyproject.toml. "
            "Extending bao-base's settings gives it bao-base's rules and keeps it out of lib, where a dependency's "
            "own settings can extend a file that yarn dep does not check out",
            "the editor checks Python by rules other than bao-base's, and logs an error for each dependency whose "
            "settings it cannot load",
            ruff_settings_problems(repo_root),
        ),
        Check(
            "git does not track .claude/settings.local.json, and an ignore rule matches it",
            "the file holds the permissions one developer gave Claude on one computer. If it is committed, "
            "everyone who clones the repository gets those permissions, and they stay after the task that "
            "needed them is finished",
            "every clone gets one developer's permissions, and reviewers read them as code instead of asking "
            "whether each one is still needed",
            claude_local_settings_problems(repo_root),
        ),
        Check(
            "committed .claude allow rules give no more access than this repository needs",
            "a committed rule applies to everyone who clones the repository, and it stays after the task that "
            "needed it is finished. A rule that reaches outside the repository, ends in ` *`, or uses `*` with a "
            "command that changes files allows much more than any one task needs. A rule with a full "
            "/home/<user>/ path also works for only one user on one computer. doctor does not read a settings "
            "file that git does not track, because it belongs to one developer",
            "each rule below was approved once, for one task, and now applies to every session. Delete the rules "
            "whose task is finished. Change the others to allow only the path or command that is needed",
            claude_permission_scope_problems(repo_root),
        ),
        Check(
            "no file that git tracks matches an ignore rule",
            "an ignore rule applies only to files that git does not track. When git tracks a file, the rule "
            "does nothing: the file still shows in git status and is still committed. But the rule looks as "
            "if it keeps the file out of the repository",
            "someone wrote the rule to keep the file out of the repository, and it is still committed. Either "
            "the rule or the tracking is wrong, and the file is committed against someone's intention",
            tracked_but_ignored_problems(repo_root),
        ),
    ]
    if unused_files:
        checks.append(
            Check(
                "no unused Solidity files",
                "nothing tests or uses a file that no test, script, test/_sizes/ or test/fixtures/ file reaches. "
                "It is still compiled and still read as part of the code, so it gets more out of date with every "
                "change around it. doctor sees only the uses in this repository. It does not see imports from "
                "other repositories, or uses from Python through wake's pytypes",
                "once you find that no other repository uses a file, delete it or move it to deprecated/. Until "
                "then it costs build time and review time, and offers code that nothing has checked to anyone "
                "who reuses it",
                unused_file_problems(repo_root),
            )
        )
    return checks


def main() -> None:
    parser = argparse.ArgumentParser(description="Check this repository for settings and files that are always wrong.")
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="say what every check is for, not only the ones that failed",
    )
    parser.add_argument(
        "--unused-files",
        action="store_true",
        help="also list Solidity files that nothing in this repository uses; doctor does not see uses from other "
        "repositories or from Python",
    )
    arguments = parser.parse_args()
    repo_root = Path(
        subprocess.run(
            ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True
        ).stdout.strip()
    )
    foundry_remappings, wake_remappings = load_remappings(repo_root)
    report(
        build_checks(repo_root, foundry_remappings, wake_remappings, arguments.unused_files),
        verbose=arguments.verbose,
    )


if __name__ == "__main__":
    main()
