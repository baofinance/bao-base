#!/usr/bin/env python3
"""What each function in regression/gas.txt that changes state costs in US dollars, at mainnet's prices: what
`yarn gas:usd` prints.

Run from the project's folder after `yarn gas`: it reads gas.txt and the build that gas run left, and runs
neither again. Each function a transaction pays for is shown with its gas, and that gas in dollars to the cent
at two gas prices: the gas price now, and the day average. gas.txt's figure is the most gas any test call to the
function used, so each dollar figure is the cost of that call.

Which rows are shown:

- Only functions that change state: nonpayable or payable in the contract's ABI. A view or pure function costs
  nothing called on its own, and inside a transaction its gas is part of the function that called it. The ABI
  comes from the gas run's build (forge_test_runs.GAS_BUILD), the build gas.txt was measured on: the one build
  file there compiled from the contract's source. A contract without exactly one stops the run before any
  chain read.
- A row whose function is not in its contract's ABI is left out and named. forge records a call to a selector
  the contract lacks - a probe for an optional function - under the name another contract gives that selector.
- A row whose figures both round to $0.00, below half a cent, is left out. Cents round half up.
- Contracts under test/ are left out: they are never deployed.
- A contract with no row left is not shown.

The output ends saying how many of each were left out, and naming each row whose function its ABI lacks.

The prices come from mainnet, read with `cast --rpc-url mainnet`: foundry finds the endpoint and loads the
project's .env, which this never reads. Etherscan has a daily average gas price and a daily ETH price too,
but only on its paid plan.

- ETH/USD: Chainlink's ETH/USD feed, its latest answer scaled by its own decimals.
- The gas price now: `cast gas-price`, the provider's quote for a transaction sent now.
- The day average: the mean over the last 7,200 blocks (a day, at 12 seconds a block) of each block's base
  fee plus its median tip, from eth_feeHistory in requests of at most 1,024 blocks, the most a provider
  serves. A mean over blocks is a mean over time: the price paid by a transaction sent at a random moment of
  the day. A provider that returns fewer blocks than asked stops the run, since summing what it did return
  would leave blocks out of the day.

The block is read first, and the feed and the block's time are read at it, so the figures belong to one
moment. Everything is read before anything is printed, so a run that stops prints no figures.

The header gives the prices and the 21,000 gas every transaction pays before any code runs. gas.txt's figures
leave it out - `owner` reads 612 - and the rows here match gas.txt's, since a function called inside another's
transaction pays no second 21,000.

A cast call whose failure reads as the provider's (provider_failures says which those are) runs once more,
and says so; a second failure, or any other, stops the run with the command and cast's words. Prices change
by the hour, so this writes no regression file: one would change on every run with no code change.
"""

from __future__ import annotations

import argparse
import json
import math
import shlex
import subprocess
import sys
from collections.abc import Sequence
from datetime import datetime, timezone
from decimal import Context, Decimal
from fractions import Fraction
from pathlib import Path

from tabulate import tabulate

import columns
import compare
from forge_test_runs import GAS_BUILD
from provider_failures import reads_as_the_providers

_GAS_REPORT = Path("regression/gas.txt")
# the state mutabilities of a function a transaction pays to run
_STATE_CHANGING = ("nonpayable", "payable")
# Chainlink's ETH/USD price feed on mainnet, as data.chain.link lists it
_ETH_USD_FEED = "0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419"
# the gas every transaction pays before any code runs
_TRANSACTION_GAS = 21_000
# a day of blocks at 12 seconds a block, and the most blocks a provider serves in one eth_feeHistory request
_DAY_BLOCKS = 7_200
_FEE_HISTORY_BLOCKS = 1_024
_WEI_PER_GWEI = 10**9
_WEI_PER_ETH = 10**18
_FOUR_FIGURES = Context(prec=4)


class _ChainReadFailed(Exception):
    """A read of the chain that did not answer, in words naming the read."""


def _cast(*arguments: str) -> str:
    """What `cast <arguments> --rpc-url mainnet` printed; run once more when its failure reads as the
    provider's. Raises `_ChainReadFailed` naming the command and cast's words when it did not answer."""
    command = ["cast", *arguments, "--rpc-url", "mainnet"]
    done = subprocess.run(command, capture_output=True, text=True, check=False)
    if done.returncode != 0 and reads_as_the_providers(done.stderr):
        print(f"`{shlex.join(command)}`: {done.stderr.strip()}; running it once more", file=sys.stderr, flush=True)
        done = subprocess.run(command, capture_output=True, text=True, check=False)
    if done.returncode != 0:
        raise _ChainReadFailed(f"`{shlex.join(command)}` failed: {done.stderr.strip()}")
    return done.stdout.strip()


def _type(parameter: dict) -> str:
    """An ABI parameter's type as a signature spells it: a tuple as its members' types, in brackets."""
    if parameter["type"].startswith("tuple"):
        members = ",".join(_type(member) for member in parameter["components"])
        return f"({members}){parameter['type'][len('tuple') :]}"
    return parameter["type"]


def _figures(value: Fraction) -> str:
    """`value` to four significant figures, in plain digits: 2.000, 0.0007344, 12,350."""
    rounded = _FOUR_FIGURES.create_decimal(Decimal(value.numerator) / Decimal(value.denominator))
    return f"{rounded.quantize(Decimal(1).scaleb(rounded.adjusted() - 3)):,f}"


def _cents(gas: int, wei_per_gas: Fraction, eth_usd: Fraction) -> int:
    """`gas` at `wei_per_gas` with ETH at `eth_usd`, in whole cents, rounding half up."""
    return math.floor(gas * wei_per_gas * eth_usd * 100 / _WEI_PER_ETH + Fraction(1, 2))


def _dollars(cents: int) -> str:
    """`cents` in dollars: $0.41, $1,234.57."""
    return f"${cents // 100:,}.{cents % 100:02d}"


def _time(timestamp: int) -> str:
    """The Unix `timestamp` as a UTC date and time to the minute."""
    return datetime.fromtimestamp(timestamp, timezone.utc).strftime("%Y-%m-%d %H:%M UTC")


def main(arguments: Sequence[str]) -> int:
    """Print gas.txt's functions that change state in dollars; 0, or 1 when gas.txt or a contract's build file
    is missing or a chain read did not answer."""
    argparse.ArgumentParser(prog="gas-usd", description=(__doc__ or "").splitlines()[0]).parse_args(arguments)
    if not _GAS_REPORT.is_file():
        print(f"no {_GAS_REPORT} in {Path.cwd()}: `yarn gas` writes it", file=sys.stderr)
        return 1
    # each deployed contract's functions that change state, with their gas, and what is left out
    changing: dict[str, dict[str, int]] = {}
    views = 0
    tests = 0
    absent: list[str] = []
    for contract, functions in compare.parse_tables(_GAS_REPORT.read_text()).items():
        path, name = contract.rsplit(":", 1)
        if path.startswith("test/"):
            tests += 1
            continue
        builds = [
            build
            for build in Path(GAS_BUILD).rglob(f"{name}.json")
            if json.loads(build.read_text())["metadata"]["settings"]["compilationTarget"] == {path: name}
        ]
        if len(builds) != 1:
            print(
                f"{contract}: {len(builds)} build files in {GAS_BUILD} compiled from {path}, not one; `yarn gas` "
                "builds it",
                file=sys.stderr,
            )
            return 1
        abi = [entry for entry in json.loads(builds[0].read_text())["abi"] if entry["type"] == "function"]
        changing[contract] = {}
        for function, gas in functions.items():
            # forge names a function by its name, or by its signature where the name is overloaded
            matching = [
                entry
                for entry in abi
                if function in (entry["name"], f"{entry['name']}({','.join(map(_type, entry['inputs']))})")
            ]
            if not matching:
                absent.append(f"{contract} {function}")
            elif any(entry["stateMutability"] in _STATE_CHANGING for entry in matching):
                changing[contract][function] = int(gas)
            else:
                views += 1
    try:
        block = int(_cast("block-number"))
        timestamp = int(_cast("block", str(block), "--field", "timestamp"))
        decimals = int(_cast("call", _ETH_USD_FEED, "decimals()(uint8)", "--block", str(block)))
        # roundId, answer, startedAt, updatedAt, answeredInRound; cast follows a large value with its size, as
        # in `243759790000 [2.437e11]`
        latest = _cast(
            "call", _ETH_USD_FEED, "latestRoundData()(uint80,int256,uint256,uint256,uint80)", "--block", str(block)
        )
        _, answer, _, updated_at, _ = (int(line.split()[0]) for line in latest.splitlines())
        now = Fraction(int(_cast("gas-price")))
        paid = 0
        newest = block
        while newest > block - _DAY_BLOCKS:
            count = min(_FEE_HISTORY_BLOCKS, newest - (block - _DAY_BLOCKS))
            history = json.loads(_cast("rpc", "eth_feeHistory", str(count), hex(newest), "[50]"))
            if len(history["reward"]) != count:
                raise _ChainReadFailed(
                    f"eth_feeHistory returned {len(history['reward'])} blocks of the {count} asked for, ending "
                    f"at block {newest}"
                )
            # baseFeePerGas holds one more than asked for: the base fee of the block after `newest`
            paid += sum(int(fee, 16) for fee in history["baseFeePerGas"][:count])
            paid += sum(int(reward[0], 16) for reward in history["reward"])
            newest -= count
    except _ChainReadFailed as failed:
        print(failed, file=sys.stderr)
        return 1
    day = Fraction(paid, _DAY_BLOCKS)
    eth_usd = Fraction(answer, 10**decimals)

    tables = []
    cheap = 0
    for contract, functions in changing.items():
        rows = []
        for function, gas in functions.items():
            cents_now, cents_day = _cents(gas, now, eth_usd), _cents(gas, day, eth_usd)
            if cents_now or cents_day:
                rows.append([function, str(gas), _dollars(cents_now), _dollars(cents_day)])
            else:
                cheap += 1
        if rows:
            tables.append((contract, rows))

    print(f"{_GAS_REPORT} in US dollars, at mainnet block {block} ({_time(timestamp)})")
    print()
    header = [
        ["ETH/USD", f"${eth_usd:,.2f}", f"Chainlink's ETH/USD feed, updated {_time(updated_at)}"],
        ["gas price now", f"{_figures(now / _WEI_PER_GWEI)} gwei", "the provider's quote"],
        [
            "gas price, day average",
            f"{_figures(day / _WEI_PER_GWEI)} gwei",
            f"base fee plus median tip, the mean of the {_DAY_BLOCKS} blocks to {block}",
        ],
        [
            "fixed transaction cost",
            f"{_TRANSACTION_GAS} gas",
            f"{_dollars(_cents(_TRANSACTION_GAS, now, eth_usd))} now, "
            f"{_dollars(_cents(_TRANSACTION_GAS, day, eth_usd))} at the day average; not in the rows below",
        ],
    ]
    for line in columns.rows(header):
        print(line)
    for contract, rows in tables:
        print()
        print(contract)
        print(
            tabulate(
                rows,
                headers=["function name", "gas", "now", "day average"],
                tablefmt="github",
                disable_numparse=True,
                colalign=("left", "right", "right", "right"),
            )
        )
    print()
    print(f"left out - view or pure: {views}, below a cent at both prices: {cheap}, contracts under test/: {tests}")
    if absent:
        print(f"left out - not a function of its contract: {', '.join(absent)}")
    return 0
