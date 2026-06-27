#!/usr/bin/env python3
from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any, cast

try:
    import tomllib as _toml_loader

    def load_toml(path: Path) -> dict[str, Any]:
        with path.open("rb") as stream:
            return _toml_loader.load(stream)

except ModuleNotFoundError:
    try:
        import toml as _toml_loader
    except ModuleNotFoundError as exc:  # pragma: no cover - dependency should be present via pyproject
        raise SystemExit(
            "doctor.py requires either the stdlib tomllib (Python >=3.11) or the third-party toml package."
        ) from exc

    def load_toml(path: Path) -> dict[str, Any]:
        with path.open("r", encoding="utf-8") as stream:
            return _toml_loader.load(stream)


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


def submodule_url_drift(repo_dir: Path, prefix: str = "") -> list[tuple[str, str, str]]:
    """Find submodules whose initialized URL in .git/config disagrees with the committed
    .gitmodules. `git submodule update` trusts .git/config (written once at init/sync) and
    never reconciles it when .gitmodules changes, so a stale .git/config silently clones the
    wrong URL. Read-only: compares the two configs, recursing into populated submodules so
    drift at any nesting level is reported. Returns (display path, .gitmodules url, .git/config url)."""
    gitmodules = repo_dir / ".gitmodules"
    if not gitmodules.is_file():
        return []

    listing = subprocess.run(
        ["git", "config", "-f", ".gitmodules", "--get-regexp", r"^submodule\..*\.url$"],
        cwd=repo_dir, capture_output=True, text=True,
    )

    drift: list[tuple[str, str, str]] = []
    for line in listing.stdout.splitlines():
        key, _, gitmodules_url = line.partition(" ")
        gitmodules_url = gitmodules_url.strip()
        name = key[len("submodule.") : -len(".url")]

        path_result = subprocess.run(
            ["git", "config", "-f", ".gitmodules", "--get", f"submodule.{name}.path"],
            cwd=repo_dir, capture_output=True, text=True,
        )
        sub_path = path_result.stdout.strip() or name
        display = f"{prefix}{sub_path}"

        # --local is the .git/config that `submodule update` reads. A non-zero return means
        # this submodule isn't initialized in this clone, so there is no stored URL to drift.
        local = subprocess.run(
            ["git", "config", "--local", "--get", f"submodule.{name}.url"],
            cwd=repo_dir, capture_output=True, text=True,
        )
        if local.returncode == 0:
            gitconfig_url = local.stdout.strip()
            if gitconfig_url != gitmodules_url:
                drift.append((display, gitmodules_url, gitconfig_url))

        nested = repo_dir / sub_path
        if (nested / ".git").exists():
            drift.extend(submodule_url_drift(nested, prefix=f"{display}/"))

    return drift


def submodule_status_problems(repo_root: Path) -> list[str]:
    """Inconsistencies across the recursive submodule tree, read from the leading flag of
    `git submodule status --recursive`:
      '-'  uninitialized — recorded in the tree but not checked out (an import into it resolves to a
           missing file; this is exactly what a non-`--recursive` clone/update leaves behind).
      '+'  the checked-out commit differs from the gitlink the parent records. This is also how a
           detached-HEAD submodule carrying *local commits* shows up — a plain detached HEAD at the
           pinned commit is the normal state for a submodule and is deliberately NOT flagged.
      'U'  merge conflict.
    Read-only. Returns '<path>: <description>' lines."""
    labels = {
        "-": "uninitialized (not checked out)",
        "+": "revision mismatch (working tree != recorded gitlink)",
        "U": "merge conflict",
    }
    status = subprocess.run(
        ["git", "submodule", "status", "--recursive"],
        cwd=repo_root, capture_output=True, text=True,
    )
    out: list[str] = []
    for line in status.stdout.splitlines():
        if not line:
            continue
        flag, body = line[0], line[1:]
        if flag in labels:
            parts = body.split()
            path = parts[1] if len(parts) > 1 else body.strip()
            out.append(f"{path}: {labels[flag]}")
    return out


def ghost_submodules(repo_dir: Path, prefix: str = "") -> list[str]:
    """Nested git repositories present in the working tree that no .gitmodules registers — e.g. a
    stray `forge install`/clone run in the wrong directory (the bao-factory-in-bao-factory we hit).
    Each repo's untracked entries are scanned with `--untracked-files=all`, so a ghost nested inside
    an otherwise-untracked directory is listed individually (`?? lib/ghost/`) instead of collapsed
    onto its parent (`?? lib/`); entries that themselves contain a `.git` are the ghosts. Using
    `git status` rather than a raw filesystem walk means `.gitignore` is honoured — so gitignored
    tooling caches (e.g. uv's `.tools/` sdist repos) are not mistaken for ghosts. Recurses into
    registered submodules so a ghost at any depth is found. Read-only. Returns display paths."""
    ghosts: list[str] = []

    status = subprocess.run(
        ["git", "status", "--porcelain", "--untracked-files=all"],
        cwd=repo_dir, capture_output=True, text=True,
    )
    for line in status.stdout.splitlines():
        if line.startswith("?? "):
            entry = line[3:].strip().strip('"').rstrip("/")
            if (repo_dir / entry / ".git").exists():
                ghosts.append(f"{prefix}{entry}")

    listing = subprocess.run(
        ["git", "config", "-f", ".gitmodules", "--get-regexp", r"^submodule\..*\.path$"],
        cwd=repo_dir, capture_output=True, text=True,
    )
    for line in listing.stdout.splitlines():
        sub_path = line.partition(" ")[2].strip()
        nested = repo_dir / sub_path
        if (nested / ".git").exists():
            ghosts.extend(ghost_submodules(nested, prefix=f"{prefix}{sub_path}/"))

    return ghosts


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
                f"wake.toml has `{entry}` — Wake does not support foundry's context remappings; "
                f"use the bare form `{bare}`."
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
                    f"Order mismatch at index {index}: "
                    f"foundry.toml has {pair[0]!r} while wake.toml has {pair[1]!r}."
                )
                break
        if len(normalized_foundry) != len(wake_remappings):
            mismatch_details.append(
                "The lists have different lengths: " f"{len(normalized_foundry)} vs {len(wake_remappings)}."
            )

    if not mismatch_details:
        mismatch_details.append("Remapping lists differ but no specific difference found.")

    return ["Remapping mismatch detected:\n" + "\n".join(mismatch_details)]


def submodule_tree_problems(repo_root: Path) -> list[str]:
    """Status-flag inconsistencies (`submodule_status_problems`) + ghosts (`ghost_submodules`) across
    the recursive submodule tree, formatted as one problem block. Returns [] when the tree is clean."""
    lines = submodule_status_problems(repo_root)
    lines += [f"{ghost}: ghost (untracked nested git repo, in no .gitmodules)" for ghost in ghost_submodules(repo_root)]
    if not lines:
        return []
    return [
        "Submodule tree inconsistencies:\n  "
        + "\n  ".join(lines)
        + "\nRepair: uninitialized → `git submodule update --init --recursive`; revision mismatch → commit & "
        "`git add` it (or `git submodule update` to reset); ghost → delete its worktree and its "
        "`.git/modules/.../<path>` gitdir. (A plain detached HEAD at the pinned commit is normal, not listed.)"
    ]


def submodule_url_drift_problems(repo_root: Path) -> list[str]:
    """`submodule_url_drift` formatted as a problem block. Returns [] when URLs agree."""
    drift = submodule_url_drift(repo_root)
    if not drift:
        return []
    lines = ["Submodule URL drift — .git/config disagrees with the committed .gitmodules:"]
    for display, gitmodules_url, gitconfig_url in drift:
        lines.append(f"  {display}")
        lines.append(f"    .git/config: {gitconfig_url}")
        lines.append(f"    .gitmodules: {gitmodules_url}")
    lines.append("Repair (rewrites .git/config from .gitmodules): git submodule sync")
    return ["\n".join(lines)]


def foundry_lock_problems(repo_root: Path) -> list[str]:
    """Verify each submodule's checked-out commit matches the rev pinned in foundry.lock — forge only
    *warns* on this drift, so a stale pin is easy to miss. foundry.lock maps a submodule path to
    {tag|branch: {name, rev}}. Read-only. Returns '<path>: checked out X but foundry.lock pins Y (ref)'
    lines; [] when there is no foundry.lock or every pin matches. (Replaces bin/check_gitmodules_lock.sh,
    which checked a separate .gitmodules.commitlock that this repo does not use.)"""
    lock_path = repo_root / "foundry.lock"
    if not lock_path.is_file():
        return []
    try:
        lock = cast("dict[str, dict[str, dict[str, str]]]", json.loads(lock_path.read_text()))
    except json.JSONDecodeError as exc:
        return [f"foundry.lock is not valid JSON: {exc}"]

    status = subprocess.run(
        ["git", "submodule", "status"], cwd=repo_root, capture_output=True, text=True,
    )
    checked_out: dict[str, str] = {}
    for line in status.stdout.splitlines():
        parts = line[1:].split()  # drop the leading status flag (' ', '+', '-', 'U')
        if len(parts) >= 2:
            checked_out[parts[1]] = parts[0]

    problems: list[str] = []
    for path, entry in lock.items():
        pin: dict[str, str] = entry.get("tag") or entry.get("branch") or {}
        expected = pin.get("rev")
        actual = checked_out.get(path)
        if expected and actual and actual != expected:
            kind = "branch" if "branch" in entry else "tag" if "tag" in entry else "ref"
            # The checked-out commit and foundry.lock's rev are two independent pins (git's gitlink vs
            # forge's lock); the doctor cannot know which is authoritative — that is intent. So offer both
            # resolutions rather than guessing. `forge update` is forge's (it re-fetches the ref and
            # rewrites the lock — for a branch that follows HEAD); `git checkout <lock rev>` adopts the
            # commit the lock already records. `git add`/`git submodule update` alone can't fix it: they
            # only move the gitlink, never the forge lock (the real-world failure that surfaced this).
            problems.append(
                f"{path}: checked out {actual[:10]} but foundry.lock pins {expected[:10]} ({kind} "
                f"{pin.get('name', '?')}). Two independent pins — pick which to keep: `forge update {path}` "
                f"lets forge re-fetch the {kind} and rewrite the lock, or "
                f"`git -C {path} checkout {expected} && git add {path}` adopts the locked commit."
            )
    return problems


def main() -> None:
    from rich.console import Console

    repo_root = Path(
        subprocess.run(
            ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True
        ).stdout.strip()
    )
    foundry_remappings, wake_remappings = load_remappings(repo_root)
    console = Console()

    # Each check is (name, problems); it passes when it returns no problems. One uniform colored
    # pass/fail line per check keeps the report consistent however many sub-checks each one runs.
    checks: list[tuple[str, list[str]]] = [
        ("foundry/wake remappings agree", remapping_problems(foundry_remappings, wake_remappings)),
        ("submodule URLs (.git/config vs .gitmodules)", submodule_url_drift_problems(repo_root)),
        ("submodule tree (initialised, at gitlink, no ghosts)", submodule_tree_problems(repo_root)),
        ("submodule commits match foundry.lock", foundry_lock_problems(repo_root)),
    ]

    failed = False
    for name, problems in checks:
        if problems:
            failed = True
            console.print(f"✗ {name}", style="bold red", markup=False)
            for block in problems:
                for line in block.splitlines():
                    console.print(f"    {line}", style="red", markup=False)
        else:
            console.print(f"✓ {name}", style="green", markup=False)

    if failed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
