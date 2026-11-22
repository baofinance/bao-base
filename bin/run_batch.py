"""run-batch: Safe batch files executed on the local node as their signer would, each batch in one block, applied whole
or not at all.

On a network a batch is one Safe transaction: its calls land together in one block, or none of them does. On the local
node, foundry.toml's `local`, run-batch stands in for the signers: it sends each call of the batch as its own
transaction, from the batch's signer, impersonated, and then mines them all into one block. The signer is `owner()` of
the first call's target, or the address `--from` gives.

Each call is sent at its own nonce, counted on from the signer's, without waiting for the one before it, with automatic
mining off: the node estimates each call's gas on the state the calls before it leave. Then one block is mined. It must
hold exactly the batch's calls, in order, and each must succeed. Otherwise the batch's pending calls are dropped and the
node goes back to a snapshot taken before the batch, so nothing of it is applied, and the batches after it are not run.
The node's mining mode is restored after each batch, whatever happened.

The files are executed in the order given, each batch in a block of its own. Every file is read before any batch is
sent. A node that mines on a timer is refused: it can mine a block while a batch's calls are being sent.

`read_batch`, `send_command` and `block_problem` decide without running anything; `main` runs cast.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

RPC = "local"


@dataclass(frozen=True)
class Call:
    """One call of a batch."""

    to: str
    data: str
    value: str


@dataclass(frozen=True)
class Batch:
    """A batch file: its calls, in order."""

    path: Path
    description: str
    chain_id: str
    calls: tuple[Call, ...]


class BatchFailed(Exception):
    """A batch that did not land whole: what went wrong."""


def read_batch(path: Path) -> Batch:
    """The batch a Safe Transaction Builder file holds. A file that is not there, or holds no call, stops the run."""
    if not path.is_file():
        sys.exit(f"❌ {path}: no such file")
    content = json.loads(path.read_text())
    calls = tuple(
        Call(to=transaction["to"], data=transaction["data"], value=transaction.get("value", "0"))
        for transaction in content["transactions"]
    )
    if not calls:
        sys.exit(f"❌ {path} holds no calls")
    return Batch(
        path=path,
        description=content.get("meta", {}).get("description", "-"),
        chain_id=content.get("chainId", "-"),
        calls=calls,
    )


def send_command(call: Call, signer: str, nonce: int) -> list[str]:
    """The cast command that sends `call` as `signer` at `nonce`, returning once the node holds it.

    cast counts only mined transactions for a nonce, so each call is given its own. A legacy transaction needs no fee
    estimate, which a fork of an old block cannot answer."""
    return [
        "cast", "send", call.to, call.data, "--value", call.value, "--from", signer, "--unlocked", "--legacy",
        "--nonce", str(nonce), "--async", "--rpc-url", RPC,
    ]  # fmt: skip


def block_problem(held: list[str], sent: list[str]) -> str | None:
    """What is wrong with a block holding the transactions `held`, for a batch whose calls were sent as `sent`; None
    when it holds exactly those calls, in the order sent."""
    if held == sent:
        return None
    foreign = [transaction for transaction in held if transaction not in sent]
    if foreign:
        return f"holds transactions not in the batch: {', '.join(foreign)}"
    if len(held) < len(sent):
        return f"holds {len(held)} of the batch's {len(sent)} calls"
    return "holds the batch's calls in another order"


def _ask(arguments: list[str]) -> str:
    """What `cast <arguments>` printed for the node. A cast that fails stops the run, with cast's own error."""
    done = subprocess.run(["cast", *arguments, "--rpc-url", RPC], capture_output=True, text=True, check=False)
    if done.returncode != 0:
        sys.exit(f"❌ cast {' '.join(arguments)} failed: {done.stderr.strip() or f'exit {done.returncode}'}")
    return done.stdout.strip()


def _rpc(method: str, *parameters: str) -> object:
    """The node's answer to `method`."""
    return json.loads(_ask(["rpc", method, *parameters]))


def _execute(batch: Batch, signer: str | None, automine: bool) -> None:
    """Send every call of `batch` and mine them into one block, or leave nothing of it applied."""
    if signer is None:
        first = batch.calls[0].to
        done = subprocess.run(
            ["cast", "call", first, "owner()(address)", "--rpc-url", RPC], capture_output=True, text=True, check=False
        )
        if done.returncode != 0:
            sys.exit(
                f"❌ {first}, the first call's target in {batch.path}, did not answer owner(): {done.stderr.strip()}\n"
                "   --from <address> names the batch's signer"
            )
        signer = done.stdout.strip()

    count = len(batch.calls)
    rule = "=" * 54
    print(rule, f"  RUN BATCH: {batch.path}", rule, sep="\n", file=sys.stderr)
    print(f"  Description: {batch.description}", file=sys.stderr)
    print(f"  Chain ID:    {batch.chain_id}", file=sys.stderr)
    print(f"  Signer:      {signer}", file=sys.stderr)
    print(f"  Calls:       {count}", file=sys.stderr)

    before = int(_ask(["block-number"]))
    snapshot = _rpc("evm_snapshot")
    _rpc("evm_setAutomine", "false")
    try:
        nonce = int(_ask(["nonce", signer]))
        transactions = []
        for number, call in enumerate(batch.calls, start=1):
            done = subprocess.run(send_command(call, signer, nonce + number - 1), capture_output=True, text=True)
            if done.returncode != 0:
                raise BatchFailed(f"call {number} of {count}, to {call.to}, was refused: {done.stderr.strip()}")
            transactions.append(done.stdout.strip())
            print(f"  [{number}/{count}] {call.to} {call.data[:10]} sent", file=sys.stderr)
        _rpc("evm_mine")
        block = int(_ask(["block-number"]))
        held = _rpc("eth_getBlockByNumber", hex(block), "false")["transactions"]  # type: ignore[index]
        problem = block_problem(held, transactions)
        if problem:
            raise BatchFailed(f"block {block} {problem}")
        for number, (call, transaction) in enumerate(zip(batch.calls, transactions), start=1):
            if _rpc("eth_getTransactionReceipt", transaction)["status"] != "0x1":  # type: ignore[index]
                raise BatchFailed(f"call {number} of {count}, to {call.to}, failed in block {block}")
    except BatchFailed as failure:
        _rpc("anvil_dropAllTransactions")
        reverted = _rpc("evm_revert", str(snapshot))
        if reverted is not True:
            sys.exit(f"❌ {failure}\n❌ evm_revert {snapshot} answered {json.dumps(reverted)}")
        raise BatchFailed(
            f"{failure}\n  Nothing of the batch is applied: the node is back at block {before}."
        ) from None
    finally:
        _rpc("evm_setAutomine", json.dumps(automine))
    calls = "1 call" if count == 1 else f"{count} calls"
    print(f"  COMPLETE: block {block} holds the batch's {calls}", file=sys.stderr)
    print(rule, file=sys.stderr)


class _ArgumentParser(argparse.ArgumentParser):
    """argparse that fails as the rest of run-batch does: one ❌ line, exit 1."""

    def error(self, message: str) -> None:  # type: ignore[override]
        sys.exit(f"❌ {message}")


def main(argv: list[str]) -> int:
    """Execute each batch file in `argv`, in order, and return the exit status: 0 when every batch landed whole."""
    parser = _ArgumentParser(
        prog="run-batch",
        description="Execute Safe batch files on the local node as their signer, each batch in one block.",
    )
    parser.add_argument("file", nargs="+", type=Path, help="a Safe Transaction Builder batch file, as run-script saves")
    parser.add_argument("--from", dest="signer", help="the signer, when not owner() of each batch's first target")
    arguments = parser.parse_args(argv)

    batches = [read_batch(path) for path in arguments.file]
    interval = _rpc("anvil_getIntervalMining")
    if interval:
        sys.exit(
            f"❌ the local node mines a block every {interval} seconds (anvil_getIntervalMining): a batch is mined into "
            "one block only on a node that mines when told to"
        )
    automine = _rpc("anvil_getAutomine")
    for index, batch in enumerate(batches):
        try:
            _execute(batch, arguments.signer, automine is True)
        except BatchFailed as failure:
            print(f"  FAILED: {failure}", file=sys.stderr)
            not_run = [str(later.path) for later in batches[index + 1 :]]
            if not_run:
                print(f"  Not run: {' '.join(not_run)}", file=sys.stderr)
            print("=" * 54, file=sys.stderr)
            return 1
    return 0
