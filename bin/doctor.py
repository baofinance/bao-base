#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import subprocess
import textwrap
import tomllib
from pathlib import Path
from typing import Any, NamedTuple, cast

import json5


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
        display = f"{prefix}{sub_path}"

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
        cwd=repo_root,
        capture_output=True,
        text=True,
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
        cwd=repo_dir,
        capture_output=True,
        text=True,
    )
    for line in status.stdout.splitlines():
        if line.startswith("?? "):
            entry = line[3:].strip().strip('"').rstrip("/")
            if (repo_dir / entry / ".git").exists():
                ghosts.append(f"{prefix}{entry}")

    listing = subprocess.run(
        ["git", "config", "-f", ".gitmodules", "--get-regexp", r"^submodule\..*\.path$"],
        cwd=repo_dir,
        capture_output=True,
        text=True,
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
                    f"Order mismatch at index {index}: foundry.toml has {pair[0]!r} while wake.toml has {pair[1]!r}."
                )
                break
        if len(normalized_foundry) != len(wake_remappings):
            mismatch_details.append(
                f"The lists have different lengths: {len(normalized_foundry)} vs {len(wake_remappings)}."
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
        + "\n  Repair: uninitialized → `git submodule update --init --recursive`; revision mismatch → commit & "
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
        ["git", "submodule", "status"],
        cwd=repo_root,
        capture_output=True,
        text=True,
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

    lines = ["Tracked files that the ignore rules match — the rule has no effect while the file is tracked:"]
    for rule, matched in by_rule.items():
        lines.append(f"  {rule}")
        for path in matched:
            lines.append(f"    {path}")
    # Which side is wrong — the tracking or the rule — is intent the doctor cannot know, so offer both.
    lines.append(
        "  Repair: to untrack them (keeps your working-tree copies) "
        "`git ls-files -i -c --exclude-standard -z | xargs -0 git rm --cached` then commit — note the "
        "commit DELETES them from every other clone on pull, being ignored does not protect them. "
        "To keep them in the repo instead, narrow the ignore rule so it no longer matches."
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
        return [f"{repo_file} is missing (the editor needs it to use bao-base's ruff)."]

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
        problems.append(f'"[python]" differs from bao-base: {repo.get("[python]")!r} vs {canonical.get("[python]")!r}')

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
                    f'"{key}" resolves to {repo_paths} (from {repo_value!r}), '
                    f"but bao-base's is {canonical_paths} (from {canonical_value!r})"
                )
        elif repo_value != canonical_value:
            problems.append(f'"{key}" is {repo_value!r} but bao-base has {canonical_value!r}')

    return problems


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
            f"{_CLAUDE_LOCAL_SETTINGS} is tracked by git. It is a machine-local override, so it "
            f"should exist only on this machine.\n"
            f"  Repair: git rm --cached {_CLAUDE_LOCAL_SETTINGS}  (keeps your copy, drops it from the repo)"
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
            covered_by = f" (only by {source}, which is not part of the repository)" if source else ""
            problems.append(
                f"{_CLAUDE_LOCAL_SETTINGS} exists but no ignore rule in this repository covers "
                f"it{covered_by}, so anyone cloning it can commit the file by accident.\n"
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
                f"reaches {target}, which is outside this repository. Work in this repo does not "
                f"need it, and the grant persists for every future session."
            )
        # A literal /home/<user>/… names one machine and one account, so the file cannot be shared,
        # copied to another checkout, or used by anyone else. `~` is the portable spelling and
        # resolves to the same place. Independent of scope: it applies to permitted paths too.
        if not argument.startswith("~") and target.is_relative_to(Path.home()):
            portable = "~/" + str(target.relative_to(Path.home()))
            reasons.append(
                f"hardcodes a machine-specific path. Write it as `{portable}…` so the rule does not "
                f"name one machine and one account."
            )

    if tool == "Bash":
        if argument.rstrip().endswith(" *"):
            reasons.append(
                "ends in a space then `*`, so it matches any continuation — including "
                "`&& rm -rf ~`. Bound the arguments instead, or name the exact command."
            )
        for command in _STATE_CHANGING_COMMANDS:
            if re.match(rf"^{re.escape(command)}\b.*[:\s]\*", argument):
                reasons.append(
                    f"is a wildcard on `{command}`, which changes state outside the working "
                    f"tree or reaches the network. Grant the specific invocation you need."
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
                f".claude/{name} — {len(found)} of {len(allow)} allow-rules are broader than this repo:\n  "
                + "\n  ".join(found)
            )
    return problems


class Check(NamedTuple):
    """One doctor check, ready to render. `why` states what it is for and prints on every run;
    `cost` states what leaving it unfixed costs and prints only when it fired, which is the one
    place that extra reading earns its space."""

    name: str
    why: str
    cost: str
    problems: list[str]


def _wrap(text: str, indent: str, width: int, marker: str = "") -> list[str]:
    """One line of `text` wrapped to `width` under `indent`, ready to print.

    `width` is the console's own width: wrap wider than that and rich re-wraps the result at the true
    edge, dropping the indent from every continuation line and leaving the output ragged. Any leading
    whitespace `text` already carries is preserved and added to `indent`, so a problem block's own
    structure survives.

    `marker` is a list bullet ("* ", "- ") placed once, on the first line; continuations align past
    it rather than stepping in further. Separating items by bullet rather than by blank line keeps
    each one visibly distinct without the vertical gaps, and a continuation that aligned under the
    bullet — or indented past it — would read as a nested item instead of the same one. An empty
    line stays empty."""
    own_indent = " " * (len(text) - len(text.lstrip()))
    prefix = indent + own_indent
    body = text.strip()
    if not body:
        return [""]
    return textwrap.wrap(
        body,
        width=max(width, len(prefix) + len(marker) + 20),
        initial_indent=prefix + marker,
        subsequent_indent=prefix + " " * len(marker),
    )


def build_checks(repo_root: Path, foundry_remappings: list[str], wake_remappings: list[str]) -> list[Check]:
    """Every check doctor runs, in report order. Separate from `main` so the list is a value that can
    be asserted on: a check function that is written but never added here silently never runs, and
    reads as covered — which is exactly what happened to `tracked_but_ignored_problems`.

    Each check names what it verifies, why that matters, what a failure costs, and its problems; it
    passes when there are none. `why` prints identically on both paths — a check whose purpose is
    visible only when it fires teaches nothing while it is green, and a reader who does not know
    what a check is FOR cannot judge whether its failure is urgent or cosmetic. `cost` is the only
    part that differs, added on failure: the consequence of leaving it unfixed, which is worth the
    lines only once something is actually broken."""
    return [
        Check(
            "foundry/wake remappings agree",
            "wake and forge must resolve every import to the same file — otherwise wake analyses a "
            "different program from the one that compiles, and its findings apply to neither",
            "until they agree, every wake detection is suspect: it may be reporting on code that "
            "does not build, or missing code that does",
            remapping_problems(foundry_remappings, wake_remappings),
        ),
        Check(
            "submodule URLs (.git/config vs .gitmodules)",
            "a drifted URL means your checkout tracks a different remote from the one committed, so "
            "you build code that no one else can fetch",
            "your builds pass and everyone else's fail, on source that looks identical in the diff",
            submodule_url_drift_problems(repo_root),
        ),
        Check(
            "submodule tree (initialised, at gitlink, no ghosts)",
            "an uninitialised or off-gitlink submodule builds against the wrong source; a ghost is a "
            "nested repo nothing tracks, so its contents are invisible to everyone else",
            "what you compile and test is not what the commit describes, so a green run here says "
            "nothing about the tree anyone else will get",
            submodule_tree_problems(repo_root),
        ),
        Check(
            "submodule commits match foundry.lock",
            "forge only warns on this drift, so a stale pin ships silently — the lock and the "
            "gitlink are two independent pins and both must name the same commit",
            "the two pins disagree about which commit is the dependency, and which one wins depends "
            "on whether git or forge updated the checkout last",
            foundry_lock_problems(repo_root),
        ),
        Check(
            ".vscode/settings.json uses bao-base's ruff",
            "a different ruff, or none, formats and lints Python to a different standard than CI "
            "enforces, so the editor tells you the file is clean and CI disagrees",
            "you will keep discovering formatting failures in CI on files the editor called clean, one push at a time",
            vscode_ruff_settings_problems(repo_root),
        ),
        Check(
            ".claude/settings.local.json is untracked and ignored",
            "it holds per-machine permission grants; committing it publishes one developer's grants "
            "to everyone and turns them into source that outlives the session that needed them",
            "every clone inherits one developer's grants, and each is reviewed as source rather than "
            "reconsidered as a permission",
            claude_local_settings_problems(repo_root),
        ),
        Check(
            "committed .claude allow-rules are scoped to this repo",
            "a COMMITTED rule reaches everyone who clones and outlives the session that needed it, "
            "so one reaching outside the repo, ending in a bare ` *`, or wildcarding a "
            "state-changing command grants far more than any one task needs; one spelling an "
            "absolute /home/<user>/ path also ties the file to a single machine and account. An "
            "untracked settings file is a developer's own business and is not read",
            "each rule below was approved once for one task and now stands permanently. Delete the "
            "ones whose task is finished; narrow the rest to the path or command actually needed",
            claude_permission_scope_problems(repo_root),
        ),
        Check(
            "no tracked file is matched by an ignore rule",
            "ignore rules apply only to untracked paths, so once a file is in the index the rule "
            "does nothing — the file keeps appearing in `git status` and keeps being committed, "
            "while the rule reads as a protection it is not providing",
            "someone has written a rule believing the file is now private, and it is not; whichever "
            "side is wrong, the file is being committed against somebody's intent",
            tracked_but_ignored_problems(repo_root),
        ),
    ]


def main() -> None:
    from rich.console import Console

    repo_root = Path(
        subprocess.run(
            ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True
        ).stdout.strip()
    )
    foundry_remappings, wake_remappings = load_remappings(repo_root)
    console = Console()
    checks = build_checks(repo_root, foundry_remappings, wake_remappings)

    failed = False
    for check in checks:
        mark, style = ("✗", "red") if check.problems else ("✓", "green")
        console.print(f"{mark} {check.name}", style=f"bold {style}" if check.problems else style, markup=False)
        # Identical shape on both paths, so the reason for a check reads the same whether or not it
        # fired; only `cost` and the problems themselves are added when it did.
        prose = check.why if not check.problems else f"{check.why}. {check.cost}"
        for line in _wrap(prose, indent="    ", width=console.width):
            console.print(line, style=style if check.problems else "dim", markup=False)
        if not check.problems:
            continue
        failed = True
        # Bulleted rather than blank-line separated: each problem stays visibly distinct without the
        # vertical gaps, and a block's own indentation still carries its structure. `*` opens a
        # problem, `-` its details, so depth is readable at a glance rather than counted in spaces.
        for block in check.problems:
            for line in block.splitlines():
                marker = "* " if line == line.lstrip() else "- "
                for wrapped in _wrap(line, indent="    ", width=console.width, marker=marker):
                    console.print(wrapped, style=style, markup=False)

    if failed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
