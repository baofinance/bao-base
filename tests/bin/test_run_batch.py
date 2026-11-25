"""Tests for bin/run-batch: Safe batch files executed on the local node as their signer would, each batch mined into
one block and applied whole or not at all, as a Safe transaction is.

The pure parts (`read_batch`, `send_command`, `block_problem`) are asserted as values. The entry runs against a stub
`cast` on PATH, `run_batch_node.py`, which keeps a small node in a file: a test reads the node run-batch leaves behind,
the commands it sent, and what it printed.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

import run_batch

BIN = Path(__file__).resolve().parents[2] / "bin"
NODE_STUB = Path(__file__).resolve().parent / "run_batch_node.py"

# The owner every target answers, and its count of mined transactions on the node.
OWNER = "0x000000000000000000000000000000000000dead"
FIRST_NONCE = 7
REVERT_REASON = "execution reverted: NotEnoughBalance"
FOREIGN = "0x" + "f" * 64


def target(index: int) -> str:
    """The target of call `index`."""
    return f"0x{index:040x}"


def batch_file(folder: Path, name: str, targets: range) -> Path:
    """A batch file in Safe's Transaction Builder format, as Deployer saves one: a call to each of `targets`."""
    file = folder / f"{name}.json"
    transactions = [{"to": target(i), "value": "0", "data": f"0x{i:08x}"} for i in targets]
    meta = {"name": "harbor_v1", "description": f"batch {name}"}
    file.write_text(json.dumps({"version": "1.0", "chainId": "1", "meta": meta, "transactions": transactions}))
    return file


def run(
    tmp_path: Path, files: list[Path], *arguments: str, **node: object
) -> tuple[subprocess.CompletedProcess, dict, list[list[str]]]:
    """Run bin/run-batch on `files` against a node at block 100 whose fields `node` overrides, and return what it did,
    the node after it, and each command the stub was handed (without its `--rpc-url local`)."""
    state = {
        "block": 100,
        "blocks": {},
        "transactions": {},
        "receipts": {},
        "nonces": {OWNER: FIRST_NONCE},
        "pending": [],
        "automine": True,
        "interval": None,
        "block_capacity": 1000,
        "foreign": None,
        "refused": [],
        "failing": [],
        "ownerless": [],
        "owner": OWNER,
        "snapshots": {},
        "next_snapshot": 0,
        **node,
    }
    stubs = tmp_path / "stubs"
    stubs.mkdir()
    cast = stubs / "cast"
    cast.write_text(f"#!{sys.executable}\n{NODE_STUB.read_text()}")
    cast.chmod(0o755)
    node_file = tmp_path / "node.json"
    node_file.write_text(json.dumps(state))
    log = tmp_path / "cast.log"
    done = subprocess.run(
        [sys.executable, str(BIN / "run-batch"), *map(str, files), *arguments],
        cwd=tmp_path,
        env={
            **os.environ,
            "PATH": f"{stubs}{os.pathsep}{os.environ['PATH']}",
            "STUB_NODE": str(node_file),
            "STUB_LOG": str(log),
        },
        capture_output=True,
        text=True,
        check=False,
    )
    commands = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
    for command in commands:
        assert command[-2:] == ["--rpc-url", "local"], command
    return done, json.loads(node_file.read_text()), [command[:-2] for command in commands]


def mined(node: dict, block: int) -> list[tuple[str, str, int]]:
    """Each transaction of `block`: its sender, its target and its nonce."""
    transactions = [node["transactions"][transaction] for transaction in node["blocks"].get(str(block), [])]
    return [(transaction["from"], transaction["to"], transaction["nonce"]) for transaction in transactions]


def sent(commands: list[list[str]]) -> list[str]:
    """The target of each `cast send`, in the order sent."""
    return [command[1] for command in commands if command[0] == "send"]


# ── The pure parts ────────────────────────────────────────────────────────────────────────────────


def test_a_batch_file_reads_as_its_calls_in_order(tmp_path):
    batch = run_batch.read_batch(batch_file(tmp_path, "a", range(1, 4)))

    assert batch.description == "batch a"
    assert batch.calls == tuple(run_batch.Call(to=target(i), data=f"0x{i:08x}", value="0") for i in range(1, 4))


def test_a_call_is_sent_as_the_signer_at_its_nonce_without_waiting():
    # --async returns once the node holds the transaction, so the next call is sent before this one is mined. cast
    # counts only mined transactions for a nonce, so each call is given its own. A legacy transaction needs no fee
    # estimate, which a fork of an old block cannot answer.
    command = run_batch.send_command(run_batch.Call(to=target(1), data="0x01", value="0"), OWNER, 9)

    assert command == [
        "cast", "send", target(1), "0x01", "--value", "0", "--from", OWNER, "--unlocked", "--legacy",
        "--nonce", "9", "--async", "--rpc-url", "local",
    ]  # fmt: skip


def test_a_block_is_the_batch_only_when_it_holds_exactly_its_calls_in_order():
    calls = ["0xa", "0xb", "0xc"]

    assert run_batch.block_problem(calls, calls) is None
    assert run_batch.block_problem(["0xa", "0xb"], calls) == "holds 2 of the batch's 3 calls"
    assert run_batch.block_problem(["0xf", "0xa", "0xb", "0xc"], calls) == "holds transactions not in the batch: 0xf"
    assert run_batch.block_problem(["0xb", "0xa", "0xc"], calls) == "holds the batch's calls in another order"


# ── A batch, executed ─────────────────────────────────────────────────────────────────────────────


def test_each_batch_is_mined_into_one_block_with_its_calls_in_order(tmp_path):
    # One call and three: every call in block 101, in the file's order, sent by owner() of the first call's target, at
    # the nonces counted on from its own.
    for count in (1, 3):
        case = tmp_path / str(count)
        case.mkdir()
        done, node, _ = run(case, [batch_file(case, "a", range(1, count + 1))])

        assert done.returncode == 0, done.stderr
        assert node["block"] == 101, count
        assert mined(node, 101) == [(OWNER, target(i), FIRST_NONCE + i - 1) for i in range(1, count + 1)]
        calls = "1 call" if count == 1 else f"{count} calls"
        assert f"  COMPLETE: block 101 holds the batch's {calls}" in done.stderr.splitlines(), done.stderr


def test_a_completed_batch_prints_its_transactions_for_a_check(tmp_path):
    # The transactions of its block, in the order sent, comma-separated as run-campaign-test's --transactions takes
    # them: a check of the batch where it ran replays them. One call and three.
    for count in (1, 3):
        case = tmp_path / str(count)
        case.mkdir()
        done, node, _ = run(case, [batch_file(case, "a", range(1, count + 1))])

        assert done.returncode == 0, done.stderr
        listed = ",".join(node["blocks"]["101"])
        assert len(node["blocks"]["101"]) == count
        line = f"  Transactions: {listed}   (for a check: --transactions <NAME>={listed})"
        assert line in done.stderr.splitlines(), done.stderr


def test_a_transactions_file_holds_a_line_for_each_batch_that_landed(tmp_path):
    # The file a script reads the transactions from: a line per batch that landed whole, in the order run, its
    # transactions comma-separated as --transactions takes them. A batch that failed, and those not run after it, have
    # none. What an earlier run left in the file is gone.
    record = tmp_path / "transactions.txt"
    record.write_text("0x" + "e" * 64 + "\n")
    files = [batch_file(tmp_path, "a", range(1, 3)), batch_file(tmp_path, "b", range(3, 4))]
    done, node, _ = run(tmp_path, files, "--transactions-file", str(record))

    assert done.returncode == 0, done.stderr
    assert record.read_text() == f"{','.join(node['blocks']['101'])}\n{','.join(node['blocks']['102'])}\n"

    failing = tmp_path / "failing"
    failing.mkdir()
    record.write_text("0x" + "e" * 64 + "\n")
    files = [
        batch_file(failing, "a", range(1, 2)),
        batch_file(failing, "b", range(2, 3)),
        batch_file(failing, "c", range(3, 4)),
    ]
    done, node, _ = run(failing, files, "--transactions-file", str(record), failing=[target(2)])

    assert done.returncode == 1
    assert record.read_text() == f"{','.join(node['blocks']['101'])}\n"


def test_a_failed_batch_prints_no_transactions(tmp_path):
    # Nothing of it is applied, so there is nothing for a check to replay.
    done, _, _ = run(tmp_path, [batch_file(tmp_path, "a", range(1, 3))], failing=[target(2)])

    assert done.returncode == 1
    assert "Transactions:" not in done.stderr, done.stderr


def test_several_batches_each_take_a_block_of_their_own_in_the_order_given(tmp_path):
    done, node, _ = run(tmp_path, [batch_file(tmp_path, "a", range(1, 3)), batch_file(tmp_path, "b", range(3, 4))])

    assert done.returncode == 0, done.stderr
    assert mined(node, 101) == [(OWNER, target(1), 7), (OWNER, target(2), 8)]
    assert mined(node, 102) == [(OWNER, target(3), 9)]
    assert node["block"] == 102


def test_every_file_is_read_before_any_batch_runs(tmp_path):
    # A second file that is not there, or holds no call, stops the run before the first batch is sent.
    first = batch_file(tmp_path, "a", range(1, 2))
    missing = tmp_path / "missing.json"
    empty = batch_file(tmp_path, "empty", range(0))
    for case, (second, refusal) in enumerate(
        ((missing, f"❌ {missing}: no such file"), (empty, f"❌ {empty} holds no calls"))
    ):
        folder = tmp_path / str(case)
        folder.mkdir()
        done, node, commands = run(folder, [first, second])

        assert done.returncode == 1, second
        assert refusal in done.stderr.splitlines(), done.stderr
        assert commands == [], second
        assert node["block"] == 100, second


def test_a_call_refused_at_its_estimate_leaves_nothing_of_its_batch_applied(tmp_path):
    # Batch b's second call is refused at its estimate. Its first call, sent and pending, is dropped, and the node goes
    # back to the block before b, as a Safe transaction that reverts leaves nothing. Batch a, before it, stays applied;
    # c, after it, is not run.
    a, b, c = (
        batch_file(tmp_path, name, targets)
        for name, targets in (("a", range(1, 2)), ("b", range(2, 5)), ("c", range(5, 6)))
    )
    done, node, commands = run(tmp_path, [a, b, c], refused=[target(3)])

    assert done.returncode == 1
    assert node["block"] == 101
    assert mined(node, 101) == [(OWNER, target(1), 7)]
    assert node["pending"] == []
    assert node["nonces"][OWNER] == 8
    assert sent(commands) == [target(1), target(2), target(3)]
    lines = done.stderr.splitlines()
    assert (
        f"  FAILED: call 2 of 3, to {target(3)}, was refused: Error: Failed to estimate gas: server returned an error "
        f"response: error code 3: {REVERT_REASON}"
    ) in lines, done.stderr
    assert "  Nothing of the batch is applied: the node is back at block 101." in lines, done.stderr
    assert f"  Not run: {c}" in lines, done.stderr


def test_a_call_that_fails_in_the_block_leaves_nothing_of_its_batch_applied(tmp_path):
    a, b = batch_file(tmp_path, "a", range(1, 2)), batch_file(tmp_path, "b", range(2, 5))
    done, node, _ = run(tmp_path, [a, b], failing=[target(3)])

    assert done.returncode == 1
    assert node["block"] == 101
    assert "102" not in node["blocks"]
    assert node["nonces"][OWNER] == 8
    lines = done.stderr.splitlines()
    assert f"  FAILED: call 2 of 3, to {target(3)}, failed in block 102" in lines, done.stderr
    assert "  Nothing of the batch is applied: the node is back at block 101." in lines, done.stderr


def test_a_block_that_does_not_hold_exactly_the_batch_leaves_nothing_applied(tmp_path):
    # A block's gas holds only some of the calls, the rest left pending; or someone else's transaction is in it.
    for case, (setting, problem) in enumerate(
        (
            ({"block_capacity": 2}, "block 101 holds 2 of the batch's 3 calls"),
            ({"foreign": FOREIGN}, f"block 101 holds transactions not in the batch: {FOREIGN}"),
        )
    ):
        folder = tmp_path / str(case)
        folder.mkdir()
        done, node, _ = run(folder, [batch_file(folder, "a", range(1, 4))], **setting)

        assert done.returncode == 1, setting
        assert (node["block"], node["blocks"], node["pending"]) == (100, {}, []), setting
        assert f"  FAILED: {problem}" in done.stderr.splitlines(), done.stderr


def test_the_mining_mode_is_restored_whatever_happens(tmp_path):
    # On a node that mines each transaction at once, and on one that mines when told to: after a batch completed, one
    # refused, and one that failed in its block. Each batch is mined as one block, so automatic mining is off for it.
    outcomes = {"completed": {}, "refused": {"refused": [target(2)]}, "failed": {"failing": [target(2)]}}
    for automine in (True, False):
        for outcome, setting in outcomes.items():
            folder = tmp_path / f"{automine}-{outcome}"
            folder.mkdir()
            done, node, commands = run(folder, [batch_file(folder, "a", range(1, 3))], automine=automine, **setting)

            assert node["automine"] is automine, (automine, outcome, done.stderr)
            assert ["rpc", "evm_setAutomine", "false"] in commands, (automine, outcome)


def test_a_node_that_mines_on_a_timer_is_refused(tmp_path):
    done, node, commands = run(tmp_path, [batch_file(tmp_path, "a", range(1, 2))], automine=False, interval=3)

    assert done.returncode == 1
    assert (
        "❌ the local node mines a block every 3 seconds (anvil_getIntervalMining): a batch is mined into one block only "
        "on a node that mines when told to"
    ) in done.stderr.splitlines(), done.stderr
    assert sent(commands) == []
    assert node["automine"] is False
    assert [command for command in commands if command[:2] == ["rpc", "evm_setAutomine"]] == []


def test_from_names_the_signer(tmp_path):
    signer = "0x00000000000000000000000000000000000000aa"
    done, node, commands = run(tmp_path, [batch_file(tmp_path, "a", range(1, 2))], "--from", signer, nonces={signer: 3})

    assert done.returncode == 0, done.stderr
    assert mined(node, 101) == [(signer, target(1), 3)]
    assert [command for command in commands if command[0] == "call"] == []


def test_a_first_target_without_an_owner_is_refused(tmp_path):
    file = batch_file(tmp_path, "a", range(1, 3))
    done, node, commands = run(tmp_path, [file], ownerless=[target(1)])

    assert done.returncode == 1
    lines = done.stderr.splitlines()
    assert (
        f"❌ {target(1)}, the first call's target in {file}, did not answer owner(): Error: could not decode output; "
        "did you specify the wrong function return data type?"
    ) in lines, done.stderr
    assert "   --from <address> names the batch's signer" in lines, done.stderr
    assert sent(commands) == []
    assert node["automine"] is True


def test_without_a_file_nothing_runs(tmp_path):
    done, _, commands = run(tmp_path, [])

    assert done.returncode == 1
    assert "❌ the following arguments are required: file" in done.stderr, done.stderr
    assert commands == []
