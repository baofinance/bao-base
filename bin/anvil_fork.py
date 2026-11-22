"""anvil: a local node forked from a network at the block or the transaction the command names, with the local state
folder made to describe it.

`anvil --network <alias> (--block <block> | --tx <transaction>) [--before | --after] [--state empty|copy|keep]
[anvil options]` starts anvil forking the network foundry.toml's alias names, impersonating every account, its requests
to the provider paced and retried. Any other option goes to anvil as given.

A block is a number, which may hold `_`; `latest`, the chain's head; a name test/fork-blocks.toml lists, in `[blocks]`
(the blocks tests fork at) or `[anvil.blocks]` (blocks only a node forks at); `today`, the last block before the day
began, a day beginning at 06:00 local time so that every run on a day forks the same block; `yesterday` and `today-N`,
counted back from today; a date, 06:00 on it; or a time, local unless it names a zone. A block means the state after
it, as forge's fork at a block does; `--before` gives the block before.

A transaction is a hash, or a name test/fork-blocks.toml lists in `[transactions]` or `[anvil.transactions]`. It means
the state before it, as forge's fork at a transaction does; `--after` applies it.

The local state folder, `deployments/local/<network>/`, must describe the node: a state file an earlier node left
records contracts this node does not hold. `--state` empties it, makes it a copy of `deployments/<network>/`'s state
files, or keeps it. Without `--state` the question is asked, and it has no default answer. Emptying it and copying into
it each clear its batch folder too.

A node that mines on a timer is never started: run-batch mines each batch into one block, and refuses one.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import tomllib
from datetime import datetime, timedelta
from pathlib import Path

FORK_BLOCKS = Path("test") / "fork-blocks.toml"
DAY_BEGINS_AT = 6  # o'clock, local time
DATE_FORMS = ("%Y-%m-%d", "%d-%b-%Y", "%b-%d-%Y")
TIME_FORMS = ("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M%z", "%Y-%m-%dT%H:%M")
TRANSACTION_HASH = re.compile(r"0x[0-9a-fA-F]{64}")

# anvil's requests to the provider are paced and retried with a backoff when the provider refuses them (HTTP 429): on a
# fork of the head, a burst of fetches is refused otherwise, and the one request that fails reverts whatever needed it.
# Any of these options given, or --no-rate-limit, replaces all three.
PACING = ("--retries", "100", "--fork-retry-backoff", "5000", "--compute-units-per-second", "50")
PACING_OPTIONS = {"--retries", "--fork-retry-backoff", "--compute-units-per-second", "--no-rate-limit"}
TIMER_OPTIONS = {"--block-time", "-b"}


def _cast(arguments: list[str]) -> str:
    """What `cast <arguments>` printed. A cast that fails stops the run, with cast's own error."""
    done = subprocess.run(["cast", *arguments], capture_output=True, text=True, check=False)
    if done.returncode != 0:
        sys.exit(f"❌ cast {' '.join(arguments)} failed: {done.stderr.strip() or f'exit {done.returncode}'}")
    return done.stdout.strip()


class _ArgumentParser(argparse.ArgumentParser):
    """argparse that fails as the rest of anvil does: one ❌ line, exit 1."""

    def error(self, message: str) -> None:  # type: ignore[override]
        sys.exit(f"❌ {message}")


def main(argv: list[str]) -> None:
    """Start anvil at the fork point `argv` names, once the local state folder describes it. Returns only on a
    refusal, which exits."""
    if not Path("foundry.toml").is_file():
        sys.exit("❌ Run from project root")
    parser = _ArgumentParser(
        prog="anvil", allow_abbrev=False, description="A local node forked from a network at a block or a transaction."
    )
    parser.add_argument("--network", required=True, help="the foundry.toml alias of the network forked, e.g. mainnet")
    parser.add_argument("--block", help="the block forked at: see the module's description")
    parser.add_argument("--tx", "--transaction", dest="transaction", help="the transaction forked before")
    around = parser.add_mutually_exclusive_group()
    around.add_argument("--before", dest="around", action="store_const", const="before", help="the state before it")
    around.add_argument("--after", dest="around", action="store_const", const="after", help="the state after it")
    parser.add_argument("--state", choices=("empty", "copy", "keep"), help="what becomes of the local state folder")
    arguments, passthrough = parser.parse_known_args(argv)
    network = arguments.network

    if any(word.split("=", 1)[0] in TIMER_OPTIONS for word in passthrough):
        sys.exit(
            "❌ --block-time: a node that mines on a timer can mine a block while run-batch sends a batch, and "
            "run-batch refuses one"
        )
    if (arguments.block is None) == (arguments.transaction is None):
        sys.exit("❌ give --block or --tx, one of them: the node forks at it")

    listed = tomllib.loads(FORK_BLOCKS.read_text()) if FORK_BLOCKS.is_file() else {}
    own = listed.get("anvil", {})
    for kind in ("blocks", "transactions"):
        twice = sorted(set(listed.get(kind, {})) & set(own.get(kind, {})))
        if twice:
            sys.exit(f"❌ {FORK_BLOCKS} names {', '.join(twice)} in [{kind}] and in [anvil.{kind}]")
    blocks = {**listed.get("blocks", {}), **own.get("blocks", {})}
    transactions = {**listed.get("transactions", {}), **own.get("transactions", {})}

    if arguments.transaction is not None:
        spec = arguments.transaction
        transaction = transactions.get(spec, spec)
        if not TRANSACTION_HASH.fullmatch(transaction):
            sys.exit(
                f"❌ '{spec}' is not a transaction hash or a transaction {FORK_BLOCKS} names "
                f"({', '.join(transactions) or 'none'})"
            )
        if arguments.around == "after":
            fork = ["--fork-transaction-hash", transaction]
            point = f"after transaction {transaction}"
        else:
            # anvil forks at the state after a transaction: the state before one is the state after the transaction
            # just ahead of it in its block, and for a block's first transaction the end of the block before
            block = int(_cast(["tx", transaction, "blockNumber", "--rpc-url", network]))
            index = int(_cast(["tx", transaction, "transactionIndex", "--rpc-url", network]))
            if index == 0:
                fork = ["--fork-block-number", str(block - 1)]
                point = f"at block {block - 1}, the end of the block before transaction {transaction}"
            else:
                ahead = _cast(
                    ["rpc", "eth_getTransactionByBlockNumberAndIndex", hex(block), hex(index - 1), "--rpc-url", network]
                )
                previous = json.loads(ahead)["hash"]
                fork = ["--fork-transaction-hash", previous]
                point = f"after transaction {previous}, just ahead of transaction {transaction}"
    else:
        spec = arguments.block
        found = ""
        if spec == "latest":
            block = None
        elif re.fullmatch(r"[0-9][0-9_]*", spec):
            block = int(spec.replace("_", ""))
        elif spec in blocks:
            block = blocks[spec]
        else:
            # A day begins at 06:00 local time: today is the latest 06:00 that has passed, yesterday and today-N count
            # days back from it, and a plain date is 06:00 on that date. A value with a time keeps its time.
            day = re.fullmatch(r"today(?:-(\d+))?|yesterday", spec)
            when = None
            if day:
                days_back = 1 if spec == "yesterday" else int(day.group(1) or 0)
                now = datetime.now()
                today = now.replace(hour=DAY_BEGINS_AT, minute=0, second=0, microsecond=0)
                if today > now:
                    today -= timedelta(days=1)
                when = today - timedelta(days=days_back)
            for form in () if day else DATE_FORMS + TIME_FORMS:
                try:
                    parsed = datetime.strptime(spec, form)
                except ValueError:
                    continue
                when = parsed.replace(hour=DAY_BEGINS_AT) if form in DATE_FORMS else parsed
                break
            if when is None:
                sys.exit(
                    f"❌ '{spec}' is not a block number, latest, a block {FORK_BLOCKS} names "
                    f"({', '.join(blocks) or 'none'}), today, yesterday, today-N, a date (2026-07-04, 4-Jul-2026, "
                    "Jul-4-2026) or a time (2025-12-01T12:00:00Z)"
                )
            when = when.astimezone()  # a time that names no zone is local time
            if when.timestamp() > time.time():
                sys.exit(f"❌ {when:%Y-%m-%d %H:%M %z} is in the future")
            block = int(_cast(["find-block", str(int(when.timestamp())), "--rpc-url", network]))
            found = f", the last block before {when:%Y-%m-%d %H:%M %z}"
        if block is None and arguments.around == "before":
            # anvil counts a negative block back from the head
            fork, point = ["--fork-block-number", "-1"], "at the block before the latest"
        elif block is None:
            fork, point = [], "at the latest block"
        elif arguments.around == "before":
            fork, point = (
                ["--fork-block-number", str(block - 1)],
                f"at block {block - 1}, the block before {block}{found}",
            )
        else:
            fork, point = ["--fork-block-number", str(block)], f"at block {block}{found}"
    print(f"Forking {network} {point}")

    local = Path("deployments") / "local" / network
    source = Path("deployments") / network
    answer = arguments.state
    if answer is None:
        print(
            f"{local}/ must describe the node: empty it, copy {source}/'s state files into it, or keep it? "
            "[empty/copy/keep] ",
            end="",
            flush=True,
        )
        given = sys.stdin.readline().strip()
        print()
        if not given:
            sys.exit("❌ no answer: the node was not started. --state empty|copy|keep answers without asking")
        if given not in ("empty", "copy", "keep"):
            sys.exit(f"❌ '{given}' is not empty, copy or keep: the node was not started")
        answer = given
    if answer in ("empty", "copy"):
        for file in local.glob("*.json"):
            file.unlink()
        if (local / "batch").is_dir():
            shutil.rmtree(local / "batch")
    if answer == "copy":
        local.mkdir(parents=True, exist_ok=True)
        copied = sorted(source.glob("*.json"))
        for file in copied:
            shutil.copy2(file, local / file.name)
        print(f"Made {local}/ a copy of {source}/'s {len(copied)} state files, its batch folder cleared")
    if answer == "empty":
        print(f"Emptied {local}/ of its state files and its batch folder")
    if answer == "keep":
        print(f"Kept {local}/ as it is")

    pacing = [] if any(word.split("=", 1)[0] in PACING_OPTIONS for word in passthrough) else list(PACING)
    sys.stdout.flush()
    os.execvp("anvil", ["anvil", "--fork-url", network, "--auto-impersonate", *fork, *pacing, *passthrough])
