#!/usr/bin/env python3
"""One check: the GitHub workflows a repo copied from bao-base still match their originals.

A consumer cannot point `uses:` at bao-base's workflow, since GitHub resolves a workflow against the
repository being built, so each consumer holds a hand-copy. A hand-copy stops tracking its original
the moment either side changes, silently and with nothing to notice it.

Two ways in, which is why the check has its own module rather than living inside either caller:

- `doctor` lists it among every other repo-health check, for a developer at a keyboard.
- run directly (`lib/bao-base/run workflow_copy`) it reports just this check, which is what the
  test-foundry action calls. `run` provisions itself — bin/run-python installs uv and runs against
  bin/pyproject.toml — so the action reaches it with nothing but bash, python3 and curl, before node
  exists and without every consuming repo wiring a package.json entry.

**This is the only check the action runs, and adding a second is a decision, not a tidy-up.** doctor
runs on one machine, against a checkout that developer controls, where a false alarm costs a minute.
A check reached from the action runs on every consumer's runner, on every operating system in the
matrix, against whatever a fresh checkout looks like there — so it has to be shown true and checkable
in all of those before it can fail a build. None of doctor's others has been. An earlier version of
this ran all of them and so called `load_remappings`, which exits when `wake.toml` is absent: a
condition with nothing to do with workflows, in a repo that might reasonably not have one. If a
second check ever earns its place, give it its own module and its own entry in the action.
"""

from __future__ import annotations

import difflib
import subprocess
from pathlib import Path

from checks import Check, report

# bin/ sits directly under the repo root, so bao-base is this file's grandparent.
BAO_BASE_ROOT = Path(__file__).resolve().parent.parent

# Where bao-base's own workflows reach its actions. A consumer's copy says the same thing by its own
# relative path to bao-base, and normalising one to the other is what makes every other difference
# meaningful.
CANONICAL_ACTION_PREFIX = "./.github/actions/"


def normalised_lines(path: Path, action_prefix: str) -> list[str]:
    """A workflow file's lines, ready to compare against another copy of it: the leading comment
    block dropped and the action path normalised to the form bao-base itself uses.

    The leading block is where a copy records that it IS a copy, so it exists on one side only;
    comments further down are content and are kept. `action_prefix` is where THIS file expects the
    action to live, which is the one difference two copies are entitled to."""
    lines = path.read_text().splitlines()
    start = 0
    while start < len(lines) and (not lines[start].strip() or lines[start].lstrip().startswith("#")):
        start += 1
    return [line.replace(action_prefix, CANONICAL_ACTION_PREFIX) for line in lines[start:]]


def split_env_block(lines: list[str]) -> tuple[list[str], list[str]]:
    """A workflow's lines split into (the entries inside its top-level `env:` block, everything
    else).

    The block runs from a column-0 `env:` to the next line that is non-blank and also at column 0.
    The `env:` key itself stays with everything else: it is structure, and a copy that dropped it
    would otherwise be indistinguishable from one whose additions happened to be none.

    Env is the one part of a copied workflow a consumer genuinely owns. A composite action cannot
    read the `secrets` context, so the workflow file is the only place a repo's own RPC endpoints can
    be spelled, and which endpoints exist differs per repo because `foundry.toml` does. Splitting on
    lines rather than parsing YAML keeps this check free of a parser it would otherwise need on every
    consumer's runner, on every operating system in the matrix."""
    inside: list[str] = []
    outside: list[str] = []
    in_env = False
    for line in lines:
        at_top_level = bool(line) and not line[0].isspace()
        if at_top_level:
            in_env = line.rstrip() == "env:"
            outside.append(line)
            continue
        if in_env:
            inside.append(line)
        else:
            outside.append(line)
    return inside, outside


def problems(repo_root: Path, bao_base_root: Path) -> list[str]:
    """Every workflow in `repo_root` that has drifted from its original in `bao_base_root`.

    A copy is entitled to two differences. Where the action lives, which is normalised away. And the
    contents of its top-level `env:` block, where it may ADD to what upstream has — see
    `split_env_block` for why that one is the consumer's own.

    Everything else is drift, reported in both directions: a line the copy is missing is a fix that
    never arrived, and a line only the copy has is an addition upstream never took. Inside `env:`
    only the first of those counts, so an upstream entry the copy has dropped is still reported while
    its own additions are not.

    Scope is opt-in by presence: only a workflow BOTH repos have is compared. Adopting one of
    bao-base's workflows is a deliberate act, so a consumer carrying one of three is not told it is
    missing two; keeping an adopted one current is not optional, which is what this checks.

    Run inside bao-base there is nothing to compare, since it holds the originals. `bao_base_root` is
    a parameter rather than `BAO_BASE_ROOT` read directly so a test can point both roots at fixtures.
    Returns one entry per drifted workflow, or [] when every copy matches."""
    if bao_base_root == repo_root:
        return []
    if not bao_base_root.is_relative_to(repo_root):
        return [
            f"bao-base is at {bao_base_root}, outside the repo at {repo_root}, so there is no "
            f"action path a copy in this repo could be expected to use."
        ]

    canonical_dir = bao_base_root / ".github" / "workflows"
    repo_dir = repo_root / ".github" / "workflows"
    if not repo_dir.is_dir():
        return []

    # Derived, not spelled `lib/bao-base`: a repo that vendors bao-base at another path normalises
    # against ITS path, so the check does not quietly stop applying when the layout changes.
    consumer_prefix = f"./{bao_base_root.relative_to(repo_root)}/.github/actions/"

    drifted: list[str] = []
    for repo_file in sorted(repo_dir.glob("*.yml")):
        canonical_file = canonical_dir / repo_file.name
        if not canonical_file.is_file():
            continue
        canonical_lines = normalised_lines(canonical_file, CANONICAL_ACTION_PREFIX)
        repo_lines = normalised_lines(repo_file, consumer_prefix)
        if canonical_lines == repo_lines:
            continue

        canonical_env, canonical_rest = split_env_block(canonical_lines)
        repo_env, repo_rest = split_env_block(repo_lines)

        # Reported as labelled lines rather than as a diff: the report is already bulleted, so a
        # diff's own `-`/`+` markers would sit next to bullet markers meaning something else
        # entirely. `n=0` drops context, leaving only the lines that actually differ, and the first
        # two entries are unified_diff's empty `---`/`+++` headers.
        rest_changed = list(difflib.unified_diff(canonical_rest, repo_rest, n=0, lineterm=""))[2:]
        env_changed = list(difflib.unified_diff(canonical_env, repo_env, n=0, lineterm=""))[2:]

        # Both diffs contribute what upstream has and the copy lacks; only the one outside env
        # contributes the copy's own additions. A line upstream merely MOVED still shows up as
        # missing, which is intended — reordering upstream's entries is a change to the copied part,
        # not an addition to it, and matching by position is what lets this work line by line.
        upstream_only = [line[1:].strip() for line in rest_changed + env_changed if line.startswith("-")]
        here_only = [line[1:].strip() for line in rest_changed if line.startswith("+")]
        if not upstream_only and not here_only:
            continue

        detail: list[str] = []
        if upstream_only:
            detail.append("  in bao-base and missing here:")
            detail.extend(f"    {line}" for line in upstream_only)
        if here_only:
            detail.append("  here and not in bao-base:")
            detail.extend(f"    {line}" for line in here_only)
        drifted.append(
            f"{repo_file.relative_to(repo_root)} has drifted from "
            f"{canonical_file.relative_to(repo_root)}:\n" + "\n".join(detail)
        )
    return drifted


def check(repo_root: Path) -> Check:
    """The check as both entrypoints report it — one definition of the name and the reasons, so
    `doctor` and a direct run cannot describe the same check differently."""
    return Check(
        "workflows copied from bao-base match their originals",
        "a workflow here is a hand-copy of bao-base's, entitled to differ only in where the action "
        "lives and in what its own env: block adds; every other difference means the copy has "
        "stopped tracking the original, in whichever direction",
        "an upstream fix does not reach this repo and nothing says so — the copy keeps passing CI "
        "while running the version of the workflow that had the bug",
        problems(repo_root, BAO_BASE_ROOT),
    )


def main() -> None:
    repo_root = Path(
        subprocess.run(
            ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True
        ).stdout.strip()
    )
    report([check(repo_root)])


if __name__ == "__main__":
    main()
