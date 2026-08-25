#!/usr/bin/env python3
"""Forge script runner, shared by every repo that builds on bao-base.

Runs a Solidity script with standardised environment and forge arguments: it resolves the network to
an RPC URL and chain id, hands the script its deployment state files, and promotes or discards the
pending state depending on whether the run broadcast.

Nothing here is specific to one repo's contracts — a repo adds its own arguments in a thin wrapper
that delegates here (see harbor's script/deploy, which adds --peg/--collateral). That is why it lives
in bao-base rather than in any one consumer: a second copy would drift from the first.

Default entry point: run(string,string) — the salt prefix and the network, the two arguments this
runner requires. Use `--` to override the forge --sig for a script on a different signature.

The work is split so that what gets run is decided by functions that decide nothing else:
`forge_arguments`, `forge_command` and `solidity_environment` are pure, take no processes and touch
no filesystem, so a test asserts the exact command and environment directly. Only `main` runs
anything.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

# The signer anvil funds and impersonates in local mode, and the account the state files are written
# against. Both are anvil's own well-known development addresses, never used anywhere else.
ANVIL_SENDER = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
ANVIL_FUNDED_ACCOUNT = "0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2"
ANVIL_FUNDED_WEI = "0xDE0B6B3A7640000"

# Safe rejects a longer description, so an over-long one is truncated rather than failing the batch
# at the end of a deployment.
MAX_DESCRIPTION = 256


@dataclass(frozen=True)
class Invocation:
    """One invocation of the runner, as the command line described it."""

    script_name: str
    salt: str
    network: str
    local: bool = False
    timestamp: bool = False
    broadcast: bool = False
    resume: bool = False
    account: str | None = None
    message: str | None = None
    # Everything after `--`, handed to forge verbatim. When it is non-empty the caller owns the
    # entry point and the default --sig is not applied.
    passthrough: tuple[str, ...] = ()

    @property
    def script_path(self) -> Path:
        """Where the script must live. The runner passes the same name to forge as `--tc`, so the
        file and the contract it holds have to agree — a rename of one is a rename of both."""
        return Path("script") / f"{self.script_name}.s.sol"

    @property
    def rpc_url(self) -> str:
        return "local" if self.local else self.network


class ArgumentParser(argparse.ArgumentParser):
    """argparse that fails the way the rest of this runner does: one ❌ line, exit 1.

    argparse's own default is a usage dump and exit 2, which reads as a different class of problem
    from the runner's own validation failures when both reach the same terminal."""

    def error(self, message: str) -> None:  # type: ignore[override]
        sys.exit(f"❌ {message}")


def parse_arguments(argv: list[str]) -> Invocation:
    """The command line, as an `Invocation`.

    `--` is split off before argparse sees it: argparse's own REMAINDER handling is order-sensitive
    and would swallow flags meant for the runner when they follow the script name."""
    if "--" in argv:
        split = argv.index("--")
        argv, passthrough = argv[:split], tuple(argv[split + 1 :])
    else:
        passthrough = ()

    parser = ArgumentParser(
        prog="run-script",
        description="Run a Solidity script with standardised environment and forge arguments.",
        epilog=(
            "Examples:\n"
            "  run-script Deploy_ETH_mainnet --salt harbor_v1 --network mainnet --broadcast\n"
            "  run-script Deploy_Legacy_mainnet --salt harbor_v1 --network mainnet "
            "-- --sig 'run(string,bool)' harbor_v1 false"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("script_name", help="Solidity script contract name, e.g. Deploy_ETH_mainnet")
    parser.add_argument("--network", required=True, help="Network name (mainnet, arbitrum, base)")
    parser.add_argument("--salt", required=True, help="Salt prefix, e.g. harbor_v1")
    parser.add_argument("--broadcast", action="store_true", help="Broadcast transactions on-chain")
    parser.add_argument("--account", help="Foundry keystore account name (required for non-local broadcast)")
    parser.add_argument("--local", action="store_true", help="Use a local anvil node, impersonating the sender")
    parser.add_argument("--timestamp", action="store_true", help="Timestamp the local state directory")
    parser.add_argument("--resume", action="store_true", help="Resume a previous broadcast")
    parser.add_argument("-m", "--message", help=f"Safe batch description (max {MAX_DESCRIPTION} chars)")

    parsed = parser.parse_args(argv)
    if parsed.timestamp and not parsed.local:
        sys.exit("❌ --timestamp requires --local")

    return Invocation(
        script_name=parsed.script_name,
        salt=parsed.salt,
        network=parsed.network,
        local=parsed.local,
        timestamp=parsed.timestamp,
        broadcast=parsed.broadcast,
        resume=parsed.resume,
        account=parsed.account,
        message=parsed.message,
        passthrough=passthrough,
    )


def deploy_state_dir(invocation: Invocation, root: Path, now: datetime) -> Path:
    """Where this run reads and writes deployment state.

    Local runs are kept apart from real ones so a throwaway anvil deployment can never be read back
    as the state of a real network; `--timestamp` separates successive local runs from each other."""
    if not invocation.local:
        return root / "deployments" / invocation.network
    subdir = "local"
    if invocation.timestamp:
        subdir = f"local-{now.strftime('%Y-%m-%dT%H:%M:%SZ')}"
    return root / "deployments" / subdir / invocation.network


def forge_arguments(invocation: Invocation) -> list[str]:
    """The mode flags for forge — everything decided by how the run was asked for rather than by
    which script it runs."""
    arguments = ["--rpc-url", invocation.rpc_url]

    if invocation.local:
        # Local accounts are impersonated rather than signed for, so forge is told to accept an
        # unlocked sender; an explicit --account still wins if one was given.
        arguments.append("--unlocked")
        if not invocation.account:
            arguments += ["--sender", ANVIL_SENDER]
    if invocation.account:
        arguments += ["--account", invocation.account]

    if invocation.broadcast:
        arguments.append("--broadcast")
        # Neither applies locally: there is no explorer to verify against, and no reason to pace
        # transactions for a node that mines them instantly.
        if not invocation.local:
            arguments += ["--slow", "--verify"]

    if invocation.resume:
        arguments.append("--resume")

    arguments.append("--ffi")
    return arguments


def forge_command(invocation: Invocation) -> list[str]:
    """The complete forge command line.

    With a `--` pass-through the caller owns the entry point and the default signature is not added —
    two --sig flags would leave forge running whichever it saw last."""
    command = ["forge", "script", str(invocation.script_path), "--tc", invocation.script_name]
    if invocation.passthrough:
        command += list(invocation.passthrough)
    else:
        command += ["--sig", "run(string,string)", invocation.salt, invocation.network]
    return command + forge_arguments(invocation)


def safe_batch_description(invocation: Invocation) -> str:
    """The description recorded against a Safe batch, truncated to what Safe accepts."""
    description = invocation.message or f"{invocation.script_name} --salt {invocation.salt}"
    if len(description) > MAX_DESCRIPTION:
        description = description[: MAX_DESCRIPTION - 3] + "..."
    return description


def solidity_environment(invocation: Invocation, state_dir: Path, now: datetime) -> dict[str, str]:
    """The environment the Solidity script reads.

    It reads state from one file and writes it to a `.pending` sibling, so that forge's simulation
    pass cannot pollute the file the broadcast pass reads — see `promote_or_discard`."""
    environment = {
        "NETWORK": invocation.network,
        "DEPLOY_STATE_DIR": str(state_dir),
        "DEPLOY_STATE_FILE_READ": str(state_dir / f"{invocation.salt}.state.json"),
        "DEPLOY_STATE_FILE_WRITE": str(state_dir / f"{invocation.salt}.state.json.pending"),
        "SAFE_BATCH_NAME": invocation.script_name,
        "SAFE_BATCH_TIMESTAMP": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "SAFE_BATCH_DESCRIPTION": safe_batch_description(invocation),
    }
    if invocation.local:
        environment["EXECUTE_LOCAL"] = "true"
    return environment


def promote_or_discard(pending: Path, final: Path, broadcast: bool) -> str | None:
    """Settle the pending state file a successful run left behind, and say what was done.

    Only a broadcast run produces state worth keeping: a dry run's addresses were never deployed, so
    keeping them would leave a state file describing a chain that does not exist. Returns None when
    there was no pending file."""
    if not pending.is_file():
        return None
    if not broadcast:
        pending.unlink()
        return "removed .pending (dry run)"
    pending.replace(final)
    return f"promoted .pending -> {final}"


def _capture(command: list[str]) -> str:
    """Run a command that must succeed and whose output is wanted."""
    return subprocess.run(command, capture_output=True, text=True, check=True).stdout.strip()


def _banner(lines: list[str]) -> None:
    rule = "=" * 54
    print(rule, file=sys.stderr)
    for line in lines:
        print(line, file=sys.stderr)
    print(rule, file=sys.stderr)


def main() -> None:
    if not Path("foundry.toml").is_file():
        sys.exit("❌ Run from project root")

    invocation = parse_arguments(sys.argv[1:])
    if not invocation.script_path.is_file():
        sys.exit(f"❌ Script not found: {invocation.script_path}")

    now = datetime.now(timezone.utc)
    state_dir = deploy_state_dir(invocation, Path.cwd(), now)

    try:
        chain_id = _capture(["cast", "chain-id", "--rpc-url", invocation.rpc_url])
    except subprocess.CalledProcessError:
        sys.exit(f"❌ RPC failed: {invocation.rpc_url}")

    if invocation.local:
        # Fund the account the local deployments are made from; anvil starts it empty.
        subprocess.run(
            ["cast", "rpc", "anvil_setBalance", ANVIL_FUNDED_ACCOUNT, ANVIL_FUNDED_WEI, "--rpc-url", "local"],
            check=True,
        )

    command = forge_command(invocation)
    _banner(
        [
            f"  RUN SCRIPT: {invocation.script_name}",
            f"  Salt:       {invocation.salt}",
            f"  Network:    {invocation.network} ({invocation.rpc_url}, chainId: {chain_id})",
            f"  Broadcast:  {invocation.broadcast}",
            f"  Local:      {invocation.local}",
        ]
        + ([f"  Account:    {invocation.account}"] if invocation.account else [])
        + [f"  forge args: {' '.join(command[5:])}"]
    )

    environment = solidity_environment(invocation, state_dir, now)
    pending = Path(environment["DEPLOY_STATE_FILE_WRITE"])
    final = Path(environment["DEPLOY_STATE_FILE_READ"])
    if pending.is_file():
        print("  State:      cleaning up stale .pending from prior run", file=sys.stderr)
        pending.unlink()

    started = time.monotonic()
    completed = subprocess.run(command, env={**os.environ, **environment})
    if completed.returncode != 0:
        if pending.is_file():
            print(f"  State:      .pending left for debugging at {pending}", file=sys.stderr)
        _banner(["  FAILED"])
        sys.exit(1)

    settled = promote_or_discard(pending, final, invocation.broadcast)
    if settled:
        print(f"  State:      {settled}", file=sys.stderr)

    elapsed = int(time.monotonic() - started)
    _banner(["  COMPLETE", f"  Elapsed:    {elapsed // 60}m {elapsed % 60}s"])


if __name__ == "__main__":
    main()
