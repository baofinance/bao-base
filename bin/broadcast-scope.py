#!/usr/bin/env python3
"""broadcast-scope: reject config objects created inside a forge broadcast.

A deploy script's config objects are script-side inputs: the script creates them so it can read
market parameters from them, and nothing on-chain ever refers to them. `vm.startBroadcast()` records
every contract creation the script makes until `vm.stopBroadcast()`, so a config created inside that
region is deployed as a real transaction — a `--broadcast` run spends gas deploying contracts that
only the script itself reads. Harbor's Deploy_StabilityPool_v3_mainnet did exactly this: 17 config
contracts, 22M gas, all of them throwaway.

Nothing about the failure is visible in a dry run's console output, which reports the deployment as
having worked; the waste only shows up by reading the broadcast transaction list. Hence this check.

The fix is always the same shape: create the configs BEFORE `vm.startBroadcast()`, keep the returned
values, and leave only the deployment calls inside the broadcast.

`violations` is pure — source text in, (line number, line) pairs out — so the rule is unit-testable
without a filesystem (tests/bin/test_broadcast_scope.py). `main` walks the roots, honours the
`--ignore` paths bin/validate passes it from `.validate-ignore`, and reports.

Exit 0 if no config object is created inside a broadcast; 1 otherwise.
"""

import argparse
import pathlib
import re
import sys

from rich.console import Console

_START_BROADCAST = re.compile(r"vm\.startBroadcast\s*\(")
_STOP_BROADCAST = re.compile(r"vm\.stopBroadcast\s*\(")
_SINGLE_SHOT_BROADCAST = re.compile(r"vm\.broadcast\s*\(")
# a config object is created directly (`new ConfigPeg_ETH()`) or returned by a factory helper
# (`createBTCMintersConfig()`, `createMarketConfig()`)
_CREATES_CONFIG = re.compile(r"\bnew\s+Config\w*\s*\(|\bcreate\w*Config\w*\s*\(")


def code_lines(source):
    """The source with comments and string literals blanked out, one entry per original line.

    Blanked rather than deleted so line numbers still address the original file. String literals go
    too, which buys both directions: a `//` inside a URL cannot swallow the rest of a real line, and
    a config name quoted inside a log message cannot be mistaken for a creation.
    """
    lines = []
    current = []
    state = "code"
    quote = ""
    index = 0
    length = len(source)

    while index < length:
        char = source[index]
        following = source[index + 1] if index + 1 < length else ""

        if char == "\n":
            lines.append("".join(current))
            current = []
            if state == "line_comment":
                state = "code"
            index += 1
            continue

        if state == "code":
            if char == "/" and following == "/":
                state = "line_comment"
                current.append("  ")
                index += 2
            elif char == "/" and following == "*":
                state = "block_comment"
                current.append("  ")
                index += 2
            elif char in "\"'":
                state = "string"
                quote = char
                current.append(" ")
                index += 1
            else:
                current.append(char)
                index += 1
            continue

        if state == "string":
            # an escape hides the next character, so a `\"` cannot close the literal
            if char == "\\" and following and following != "\n":
                current.append("  ")
                index += 2
                continue
            if char == quote:
                state = "code"
            current.append(" ")
            index += 1
            continue

        if state == "block_comment":
            if char == "*" and following == "/":
                state = "code"
                current.append("  ")
                index += 2
            else:
                current.append(" ")
                index += 1
            continue

        # line_comment: everything up to the newline is dead
        current.append(" ")
        index += 1

    lines.append("".join(current))
    return lines


def violations(source):
    """(line number, original line) for every config object created inside a broadcast."""
    found = []
    in_broadcast = False
    after_single_shot = False

    for index, (code, original) in enumerate(zip(code_lines(source), source.splitlines())):
        if not code.strip():
            continue

        creates_config = bool(_CREATES_CONFIG.search(code))

        if _START_BROADCAST.search(code):
            in_broadcast = True
        if _STOP_BROADCAST.search(code):
            in_broadcast = False

        if creates_config and (in_broadcast or after_single_shot):
            found.append((index + 1, original.rstrip()))

        # vm.broadcast() broadcasts the next call only, so it puts just the following line in scope
        after_single_shot = bool(_SINGLE_SHOT_BROADCAST.search(code))

    return found


def main(argv=None):
    parser = argparse.ArgumentParser(description="reject config objects created inside a forge broadcast")
    parser.add_argument("roots", nargs="*", default=["src", "script", "test"], help="directories to scan")
    parser.add_argument("--ignore", action="append", default=[], help="a file exempted via .validate-ignore")
    args = parser.parse_args(argv)

    console = Console()
    ignored = {str(pathlib.Path(path)) for path in args.ignore}

    failed = False
    for root in args.roots:
        for path in sorted(pathlib.Path(root).rglob("*.sol")):
            if str(path) in ignored:
                console.print(
                    f"⚠ {path}: broadcast-scope check ignored via .validate-ignore", style="dim", markup=False
                )
                continue
            for lineno, line in violations(path.read_text(encoding="utf-8")):
                console.print(f"✗ {path}:{lineno}: {line.strip()}", style="bold red", markup=False)
                failed = True

    if failed:
        console.print(
            "config objects created inside a broadcast are deployed as real transactions — create them before "
            "vm.startBroadcast(), keep the results, and leave only the deployment calls inside the broadcast",
            style="bold red",
            markup=False,
        )
        return 1

    console.print("✓ no config objects created inside a broadcast", style="green", markup=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
