#!/usr/bin/env python3
"""The check framework, shared by the two entrypoints that run checks.

`bin/doctor.py` is developer-facing and runs every check. `bin/workflow_copy.py` reports just its own
when run directly, which is how the test-foundry action reaches it — through `run`, so a CI workflow
needs no yarn, no node and no package.json script.

Both render through here rather than each printing its own way, so a check reads identically wherever
it fired — the same mark, the same wrapping, the same order of reasons. A second renderer would drift
from this one the first time either was touched.
"""

from __future__ import annotations

import textwrap
from typing import NamedTuple

from rich.console import Console


class Check(NamedTuple):
    """One check, ready to render. `why` states what it is for and prints on every run; `cost` states
    what leaving it unfixed costs and prints only when it fired, which is the one place that extra
    reading earns its space."""

    name: str
    why: str
    cost: str
    problems: list[str]


def wrap(text: str, indent: str, width: int, marker: str = "") -> list[str]:
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


def report(checks: list[Check]) -> None:
    """Print every check in the order given, then exit non-zero if any of them fired.

    Exiting from here rather than returning a flag is deliberate: every caller is a command whose
    exit status IS its result, and a caller that forgot to re-raise would report a clean run while
    printing failures."""
    console = Console()

    failed = False
    for check in checks:
        mark, style = ("✗", "red") if check.problems else ("✓", "green")
        console.print(f"{mark} {check.name}", style=f"bold {style}" if check.problems else style, markup=False)
        # Identical shape on both paths, so the reason for a check reads the same whether or not it
        # fired; only `cost` and the problems themselves are added when it did.
        prose = check.why if not check.problems else f"{check.why}. {check.cost}"
        for line in wrap(prose, indent="    ", width=console.width):
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
                for wrapped in wrap(line, indent="    ", width=console.width, marker=marker):
                    console.print(wrapped, style=style, markup=False)

    if failed:
        raise SystemExit(1)
