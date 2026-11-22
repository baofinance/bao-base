"""Tests for bin/anvil: a local node forked from a network at a block or a transaction the command names, and the
local state folder made to describe it.

A block is a number, `latest` (the chain's head), a name `test/fork-blocks.toml` lists (in `[blocks]`, which tests fork
at, or `[anvil.blocks]`, which only a node does), a day, a date or a time. A day starts at 06:00 local time:
`--block today` is the last block before the start of today, so every run on a day forks the same block; `yesterday`
and `today-N` count days back from it, and a plain date is 06:00 on that date. A value with a time keeps its time. A
block means the state after it; `--before` gives the block before. A transaction means the state before it, as forge's
fork at a transaction does; `--after` applies it.

Hermetic: the entry runs in a made-up project folder, with `anvil` and `cast` stubs on PATH that record each command
they are handed. The cast stub answers a time with FOUND_BLOCK, and a transaction with TRANSACTION_BLOCK, the position
STUB_INDEX gives (3 by default), and PREVIOUS as the transaction ahead of it.
"""

import json
import os
import subprocess
import sys
from datetime import datetime, time, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

BIN = Path(__file__).resolve().parents[2] / "bin"

FOUND_BLOCK = 26309019
TRANSACTION_BLOCK = 26204584
PREVIOUS = "0x" + "9" * 64
HASH = "0x" + "1" * 64
LISTED_TRANSACTION = "0xb8701591c0fa3ee44a9f42379d167261f70e0532f7c0cea6fcda26ef999df3db"
NODE_TRANSACTION = "0x14ce80309b26d251b5e1e71c8aa03df677917cd627cf35b825767c97b3fcb84f"
DAY_STARTS_AT = time(6)
PACING = ["--retries", "100", "--fork-retry-backoff", "5000", "--compute-units-per-second", "50"]

FORK_BLOCKS = f"""
[blocks]
default = 24699497
usd-oracles-live = 26_308_489

[transactions]
btc-steth-exploit = "{LISTED_TRANSACTION}"

[anvil.blocks]
factory = 24046017

[anvil.transactions]
eur-steth-exploit = "{NODE_TRANSACTION}"
"""

NETWORK_FILE = {"saltPrefix": "harbor_v1", "writtenBy": "a mainnet run"}
EARLIER_LOCAL_FILE = {"saltPrefix": "harbor_v1", "writtenBy": "an earlier node"}
LOCAL_ONLY_FILE = {"saltPrefix": "pre1_3", "writtenBy": "an earlier node"}

STUB = """import json, os, sys
with open(os.environ["STUB_LOG"], "a") as log:
    log.write(json.dumps([{name!r}, *sys.argv[1:]]) + "\\n")
{body}"""

CAST_ANSWERS = f"""arguments = sys.argv[1:]
if arguments[0] == "find-block":
    print({FOUND_BLOCK})
elif arguments[0] == "tx" and arguments[2] == "blockNumber":
    print({TRANSACTION_BLOCK})
elif arguments[0] == "tx" and arguments[2] == "transactionIndex":
    print(os.environ.get("STUB_INDEX", "3"))
elif arguments[:2] == ["rpc", "eth_getTransactionByBlockNumberAndIndex"]:
    print(json.dumps({{"hash": "{PREVIOUS}"}}))
"""


def run(
    tmp_path: Path,
    *arguments: str,
    answer: str = "",
    zone: str | None = None,
    index: int = 3,
    fork_blocks: str = FORK_BLOCKS,
) -> tuple[subprocess.CompletedProcess, Path, list[list[str]]]:
    """Run bin/anvil in a project folder whose test/fork-blocks.toml is `fork_blocks`, answering its question with
    `answer`, in the time zone `zone`, and return what it did, the local state folder, and each command the stubs were
    handed.

    deployments/mainnet holds one state file; deployments/local/mainnet an older copy of it, a file of its own, and a
    batch folder."""
    project = tmp_path / "project"
    (project / "test").mkdir(parents=True)
    (project / "foundry.toml").write_text("[profile.default]\n")
    (project / "test" / "fork-blocks.toml").write_text(fork_blocks)
    network = project / "deployments" / "mainnet"
    local = project / "deployments" / "local" / "mainnet"
    network.mkdir(parents=True)
    (local / "batch").mkdir(parents=True)
    (network / "harbor_v1.state.json").write_text(json.dumps(NETWORK_FILE))
    (local / "harbor_v1.state.json").write_text(json.dumps(EARLIER_LOCAL_FILE))
    (local / "pre1_3.state.json").write_text(json.dumps(LOCAL_ONLY_FILE))
    (local / "batch" / "Deploy.json").write_text("{}")

    stubs = tmp_path / "stubs"
    stubs.mkdir()
    for name, body in (("anvil", ""), ("cast", CAST_ANSWERS)):
        stub = stubs / name
        stub.write_text(f"#!{sys.executable}\n" + STUB.format(name=name, body=body))
        stub.chmod(0o755)

    log = tmp_path / "stub.log"
    environment = {
        **os.environ,
        "PATH": f"{stubs}{os.pathsep}{os.environ['PATH']}",
        "STUB_LOG": str(log),
        "STUB_INDEX": str(index),
    }
    if zone is not None:
        environment["TZ"] = zone
    done = subprocess.run(
        [sys.executable, str(BIN / "anvil"), *arguments],
        cwd=project,
        input=answer,
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )
    commands = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
    return done, local, commands


def anvil(commands: list[list[str]]) -> list[str]:
    """The arguments anvil was started with, the one time it was."""
    started = [command[1:] for command in commands if command[0] == "anvil"]
    assert len(started) == 1, commands
    return started[0]


def forked_at(commands: list[list[str]], network: str = "mainnet") -> list[str]:
    """The fork point anvil was started at: its arguments between the fork URL and impersonation, and the pacing."""
    arguments = anvil(commands)
    assert arguments[:3] == ["--fork-url", network, "--auto-impersonate"], arguments
    assert arguments[-len(PACING) :] == PACING, arguments
    return arguments[3 : -len(PACING)]


def state_files(local: Path) -> dict[str, dict]:
    return {file.name: json.loads(file.read_text()) for file in sorted(local.glob("*.json"))}


ON_MAINNET = ("--network", "mainnet", "--state", "keep")


# ── Blocks ────────────────────────────────────────────────────────────────────────────────────────


def test_a_block_number_forks_at_it(tmp_path):
    done, _, commands = run(tmp_path, *ON_MAINNET, "--block", "26_204_584")

    assert done.returncode == 0, done.stderr
    assert forked_at(commands) == ["--fork-block-number", "26204584"]
    assert "Forking mainnet at block 26204584" in done.stdout.splitlines(), done.stdout


def test_latest_forks_the_head(tmp_path):
    # anvil forks the head when given no block, and counts a negative block back from it
    for case, (arguments, fork_point, said) in enumerate(
        (
            ([], [], "Forking mainnet at the latest block"),
            (["--before"], ["--fork-block-number", "-1"], "Forking mainnet at the block before the latest"),
        )
    ):
        done, _, commands = run(tmp_path / str(case), *ON_MAINNET, "--block", "latest", *arguments)

        assert done.returncode == 0, done.stderr
        assert forked_at(commands) == fork_point, arguments
        assert said in done.stdout.splitlines(), done.stdout


def test_before_a_block_forks_the_block_before_it(tmp_path):
    done, _, commands = run(tmp_path, *ON_MAINNET, "--block", "26204584", "--before")

    assert done.returncode == 0, done.stderr
    assert forked_at(commands) == ["--fork-block-number", "26204583"]
    assert "Forking mainnet at block 26204583, the block before 26204584" in done.stdout.splitlines(), done.stdout


def test_a_named_block_is_read_from_fork_blocks_toml(tmp_path):
    # a block tests fork at, and a block only a node forks at; no cast lookup for either
    for case, (name, block) in enumerate((("usd-oracles-live", "26308489"), ("factory", "24046017"))):
        done, _, commands = run(tmp_path / str(case), *ON_MAINNET, "--block", name)

        assert done.returncode == 0, done.stderr
        assert forked_at(commands) == ["--fork-block-number", block], name
        assert [command for command in commands if command[0] == "cast"] == [], name


def test_a_name_listed_for_tests_and_for_a_node_is_refused(tmp_path):
    # One name, two values: which one a node forks at would depend on the order the tables are read in
    for case, (fork_blocks, refusal) in enumerate(
        (
            (
                "[blocks]\nfactory = 1\n[anvil.blocks]\nfactory = 2\n",
                "❌ test/fork-blocks.toml names factory in [blocks] and in [anvil.blocks]",
            ),
            (
                f'[transactions]\nexploit = "{HASH}"\n[anvil.transactions]\nexploit = "{PREVIOUS}"\n',
                "❌ test/fork-blocks.toml names exploit in [transactions] and in [anvil.transactions]",
            ),
        )
    ):
        done, _, commands = run(tmp_path / str(case), *ON_MAINNET, "--block", "latest", fork_blocks=fork_blocks)

        assert done.returncode == 1, fork_blocks
        assert refusal in done.stderr.splitlines(), done.stderr
        assert commands == [], fork_blocks


# ── Transactions ──────────────────────────────────────────────────────────────────────────────────


def test_a_transaction_means_the_state_before_it(tmp_path):
    # anvil forks at the state after a transaction: the state before one is the state after the transaction ahead of it
    # in its block, and for a block's first transaction the end of the block before. A hash, and the names
    # test/fork-blocks.toml gives, for a test's fork and for a node's.
    for case, (spec, transaction) in enumerate(
        ((HASH, HASH), ("btc-steth-exploit", LISTED_TRANSACTION), ("eur-steth-exploit", NODE_TRANSACTION))
    ):
        done, _, commands = run(tmp_path / str(case), *ON_MAINNET, "--tx", spec)

        assert done.returncode == 0, done.stderr
        assert forked_at(commands) == ["--fork-transaction-hash", PREVIOUS], spec
        assert ["cast", "tx", transaction, "blockNumber", "--rpc-url", "mainnet"] in commands, commands
        assert (
            f"Forking mainnet after transaction {PREVIOUS}, just ahead of transaction {transaction}"
            in done.stdout.splitlines()
        ), done.stdout

    done, _, commands = run(tmp_path / "first", *ON_MAINNET, "--tx", HASH, index=0)

    assert done.returncode == 0, done.stderr
    assert forked_at(commands) == ["--fork-block-number", str(TRANSACTION_BLOCK - 1)]
    assert (
        f"Forking mainnet at block {TRANSACTION_BLOCK - 1}, the end of the block before transaction {HASH}"
        in done.stdout.splitlines()
    ), done.stdout


def test_after_a_transaction_applies_it(tmp_path):
    done, _, commands = run(tmp_path, *ON_MAINNET, "--transaction", "btc-steth-exploit", "--after")

    assert done.returncode == 0, done.stderr
    assert forked_at(commands) == ["--fork-transaction-hash", LISTED_TRANSACTION]
    assert [command for command in commands if command[0] == "cast"] == []
    assert f"Forking mainnet after transaction {LISTED_TRANSACTION}" in done.stdout.splitlines(), done.stdout


# ── What a run needs ──────────────────────────────────────────────────────────────────────────────


def test_a_block_or_a_transaction_is_required(tmp_path):
    for case, arguments in enumerate(([], ["--block", "latest", "--tx", HASH])):
        done, _, commands = run(tmp_path / str(case), *ON_MAINNET, *arguments)

        assert done.returncode == 1, arguments
        assert "❌ give --block or --tx, one of them: the node forks at it" in done.stderr.splitlines(), done.stderr
        assert commands == [], arguments


def test_a_network_is_required(tmp_path):
    done, _, commands = run(tmp_path, "--block", "latest", "--state", "keep")

    assert done.returncode == 1
    assert "❌ the following arguments are required: --network" in done.stderr.splitlines(), done.stderr
    assert commands == []


def test_a_value_that_is_not_a_block_day_date_or_time_is_refused(tmp_path):
    done, _, commands = run(tmp_path, *ON_MAINNET, "--block", "someday", zone="Europe/London")

    assert done.returncode == 1
    assert (
        "❌ 'someday' is not a block number, latest, a block test/fork-blocks.toml names (default, usd-oracles-live, "
        "factory), today, yesterday, today-N, a date (2026-07-04, 4-Jul-2026, Jul-4-2026) or a time "
        "(2025-12-01T12:00:00Z)"
    ) in done.stderr.splitlines(), done.stderr
    assert commands == []

    done, _, commands = run(tmp_path / "tx", *ON_MAINNET, "--tx", "0x1234")

    assert done.returncode == 1
    assert (
        "❌ '0x1234' is not a transaction hash or a transaction test/fork-blocks.toml names (btc-steth-exploit, "
        "eur-steth-exploit)"
    ) in done.stderr.splitlines(), done.stderr
    assert commands == []


# ── Days, dates and times ─────────────────────────────────────────────────────────────────────────


def zone_where_the_hour_is_now(hour: int) -> str:
    """A zone in which the local time is now in the given hour. The Etc/GMT zones keep no summer time and span every
    whole-hour offset from -12 to +14, so one of them is at any hour at any moment. (Their sign is inverted: Etc/GMT-9
    is nine hours ahead of UTC.)"""
    offset = (hour - datetime.now(timezone.utc).hour) % 24
    if offset > 14:
        offset -= 24
    return "Etc/GMT" if offset == 0 else f"Etc/GMT{-offset:+d}"


def start_of_day(zone: str, day) -> int:
    """The second at which a day began in a zone, as anvil hands it to `cast find-block`."""
    return int(datetime.combine(day, DAY_STARTS_AT, tzinfo=ZoneInfo(zone)).timestamp())


def found_block_from(commands: list[list[str]], second: int) -> None:
    """Assert that the block before `second` was looked up, and the node forked at the block the lookup answered."""
    assert commands[0] == ["cast", "find-block", str(second), "--rpc-url", "mainnet"], commands
    assert forked_at(commands) == ["--fork-block-number", str(FOUND_BLOCK)], commands


def test_today_is_the_last_block_before_six_this_morning(tmp_path):
    # In a zone where it is now midday, today began at 06:00 on today's date there
    zone = zone_where_the_hour_is_now(12)
    done, _, commands = run(tmp_path, *ON_MAINNET, "--block", "today", zone=zone)

    assert done.returncode == 0, done.stderr
    found_block_from(commands, start_of_day(zone, datetime.now(ZoneInfo(zone)).date()))


def test_before_six_in_the_morning_today_is_the_day_that_began_yesterday(tmp_path):
    # In a zone where it is now 03:00, the day that began at 06:00 yesterday is still today
    zone = zone_where_the_hour_is_now(3)
    done, _, commands = run(tmp_path, *ON_MAINNET, "--block", "today", zone=zone)

    assert done.returncode == 0, done.stderr
    found_block_from(commands, start_of_day(zone, datetime.now(ZoneInfo(zone)).date() - timedelta(days=1)))


def test_yesterday_and_today_minus_n_count_days_back_from_today(tmp_path):
    zone = zone_where_the_hour_is_now(12)
    today = datetime.now(ZoneInfo(zone)).date()

    for spec, days_back in (("yesterday", 1), ("today-1", 1), ("today-7", 7)):
        done, _, commands = run(tmp_path / spec, *ON_MAINNET, "--block", spec, zone=zone)

        assert done.returncode == 0, done.stderr
        found_block_from(commands, start_of_day(zone, today - timedelta(days=days_back)))


def test_a_plain_date_starts_at_six_in_the_morning_local_time(tmp_path):
    # London keeps summer time in July, so 06:00 there is 05:00 UTC: the time is local, not UTC
    for spec in ("2026-07-04", "4-Jul-2026", "Jul-4-2026"):
        done, _, commands = run(tmp_path / spec, *ON_MAINNET, "--block", spec, zone="Europe/London")

        assert done.returncode == 0, done.stderr
        found_block_from(commands, start_of_day("Europe/London", datetime(2026, 7, 4).date()))
        assert (
            f"Forking mainnet at block {FOUND_BLOCK}, the last block before 2026-07-04 06:00 +0100"
            in done.stdout.splitlines()
        ), done.stdout


def test_a_time_keeps_its_time(tmp_path):
    done, _, commands = run(tmp_path, *ON_MAINNET, "--block", "2025-12-01T12:00:00Z", zone="Europe/London")

    assert done.returncode == 0, done.stderr
    found_block_from(commands, int(datetime(2025, 12, 1, 12, tzinfo=timezone.utc).timestamp()))


def test_a_time_in_the_future_is_refused(tmp_path):
    done, _, commands = run(tmp_path, *ON_MAINNET, "--block", "2099-01-01", zone="Europe/London")

    assert done.returncode == 1
    assert "❌ 2099-01-01 06:00 +0000 is in the future" in done.stderr.splitlines(), done.stderr
    assert commands == []


# ── What anvil is started with ────────────────────────────────────────────────────────────────────


def test_the_provider_is_paced_unless_pacing_is_given(tmp_path):
    # A burst of requests to the provider is refused (HTTP 429), and the one request that fails reverts whatever needed
    # it: anvil's requests are paced and retried. Any of the pacing options, or --no-rate-limit, replaces all three.
    for case, given in enumerate(
        (["--retries", "5"], ["--fork-retry-backoff", "1"], ["--compute-units-per-second=9"], ["--no-rate-limit"])
    ):
        done, _, commands = run(tmp_path / str(case), *ON_MAINNET, "--block", "latest", *given)

        assert done.returncode == 0, done.stderr
        assert anvil(commands) == ["--fork-url", "mainnet", "--auto-impersonate", *given], given


def test_anvil_options_are_passed_on(tmp_path):
    done, _, commands = run(tmp_path, *ON_MAINNET, "--block", "latest", "--port", "8546", "--silent")

    assert done.returncode == 0, done.stderr
    assert anvil(commands) == ["--fork-url", "mainnet", "--auto-impersonate", *PACING, "--port", "8546", "--silent"]


def test_a_node_that_mines_on_a_timer_is_never_started(tmp_path):
    # run-batch mines each batch into one block, and refuses a node that mines on a timer
    for case, given in enumerate((["--block-time", "3"], ["-b", "3"], ["--block-time=3"])):
        done, _, commands = run(tmp_path / str(case), *ON_MAINNET, "--block", "latest", *given)

        assert done.returncode == 1, given
        assert (
            "❌ --block-time: a node that mines on a timer can mine a block while run-batch sends a batch, and "
            "run-batch refuses one"
        ) in done.stderr.splitlines(), done.stderr
        assert commands == [], given


# ── The local state folder ────────────────────────────────────────────────────────────────────────


def test_empty_removes_the_local_state_files_and_batches(tmp_path):
    done, local, commands = run(tmp_path, "--network", "mainnet", "--block", "factory", "--state", "empty")

    assert done.returncode == 0, done.stderr
    assert state_files(local) == {}
    assert not (local / "batch").exists()
    anvil(commands)


def test_copy_replaces_the_local_state_files_with_the_networks(tmp_path):
    # mainnet's file replaces the older copy, the file mainnet has no counterpart of goes, and so do the batches: a
    # state file an earlier node left records contracts the new node does not hold
    done, local, commands = run(tmp_path, "--network", "mainnet", "--block", "latest", "--state", "copy")

    assert done.returncode == 0, done.stderr
    assert state_files(local) == {"harbor_v1.state.json": NETWORK_FILE}
    assert not (local / "batch").exists()
    anvil(commands)


def test_keep_leaves_the_local_state_folder_as_it_is(tmp_path):
    done, local, commands = run(tmp_path, "--network", "mainnet", "--block", "latest", "--state", "keep")

    assert done.returncode == 0, done.stderr
    assert state_files(local) == {"harbor_v1.state.json": EARLIER_LOCAL_FILE, "pre1_3.state.json": LOCAL_ONLY_FILE}
    assert (local / "batch" / "Deploy.json").exists()
    anvil(commands)


def test_without_state_the_question_is_asked_and_nothing_starts_without_an_answer(tmp_path):
    # There is no default answer: only the one starting the node knows what its block holds of the deployments.
    question = (
        "deployments/local/mainnet/ must describe the node: empty it, copy deployments/mainnet/'s state files into it, "
        "or keep it? [empty/copy/keep] "
    )
    done, local, commands = run(tmp_path / "answered", "--network", "mainnet", "--block", "latest", answer="copy\n")

    assert done.returncode == 0, done.stderr
    assert question in done.stdout, done.stdout
    assert state_files(local) == {"harbor_v1.state.json": NETWORK_FILE}
    anvil(commands)

    for case, (answer, refusal) in enumerate(
        (
            ("", "❌ no answer: the node was not started. --state empty|copy|keep answers without asking"),
            ("yes\n", "❌ 'yes' is not empty, copy or keep: the node was not started"),
        )
    ):
        done, local, commands = run(tmp_path / str(case), "--network", "mainnet", "--block", "latest", answer=answer)

        assert done.returncode == 1, answer
        assert refusal in done.stderr.splitlines(), done.stderr
        assert state_files(local) == {
            "harbor_v1.state.json": EARLIER_LOCAL_FILE,
            "pre1_3.state.json": LOCAL_ONLY_FILE,
        }, answer
        assert commands == [], answer
