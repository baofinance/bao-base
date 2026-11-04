"""Tests for bin/gas-usd, built by bin/gas_usd.py: what each function in regression/gas.txt that changes state
costs in US dollars, at mainnet's prices.

Each test runs the entry point from a throwaway working directory holding a regression/gas.txt and, under
out/_gas, the build files a gas run leaves: each contract's ABI and the source it was compiled from. A stub
`cast` first on PATH records every call and answers it from a chain the test describes, in the words cast
1.9.0 uses, so nothing reaches a network. Each test names the single behaviour it verifies.
"""

import json
import os
import pathlib
import subprocess
import sys

import pytest

_BIN = pathlib.Path(__file__).resolve().parents[2] / "bin"
_GWEI = 10**9
_BLOCK = 20_000_000

# a chain at block 20,000,000 (2027-01-15 08:00 UTC): ETH at $2,000 from a feed of 8 decimals updated at
# 07:45, a quoted gas price of 4 gwei, and fees whose mean over the day's 7,200 blocks is 0.6 gwei - the last
# 1,800 blocks at a base fee of 1.2 and a tip of 0.6, the 5,400 before them at 0.15 and 0.05, so
# (1,800 x 1.8 + 5,400 x 0.2) / 7,200. The base fee of the block after the last is 1,000 gwei, which would
# move the mean to 0.7392 if it were counted with the other next-block base fees the responses carry.
# So a unit of gas costs $0.000008 now and $0.0000012 at the day average.
_CHAIN = {
    "block": _BLOCK,
    "timestamp": 1_800_000_000,
    "gas_price": 4 * _GWEI,
    "decimals": 8,
    "answer": 2_000 * 10**8,
    "updated_at": 1_800_000_000 - 15 * 60,
    # [first block, base fee, tip]: each block takes the last entry starting at or before it
    "fees": [[0, 150_000_000, 50_000_000], [_BLOCK - 1_799, 1_200_000_000, 600_000_000]],
    "next_base_fee": 1_000 * _GWEI,
}

_UINT256 = {"name": "amount", "type": "uint256", "internalType": "uint256"}
_ADDRESS = {"name": "to", "type": "address", "internalType": "address"}
_ORDERS = {
    "name": "orders",
    "type": "tuple[]",
    "internalType": "struct C.Order[]",
    "components": [_UINT256, _ADDRESS],
}
# entries an ABI holds beside its functions, which carry no name or no state mutability
_CONSTRUCTOR = {"type": "constructor", "inputs": [], "stateMutability": "nonpayable"}
_EVENT = {"type": "event", "name": "Deposit", "inputs": [_UINT256], "anonymous": False}


def _function(name: str, mutability: str, *inputs: dict) -> dict:
    """An ABI entry for the function `name` taking `inputs`, marked `mutability`."""
    return {"type": "function", "name": name, "inputs": list(inputs), "outputs": [], "stateMutability": mutability}


_GAS = {
    "src/A.sol:A": {"deposit": 250_000, "owner": 612, "withdraw": 125_000},
    "src/B.sol:B": {"claim()": 1_000_000, "claim(address,uint256)": 50_000},
}
_ABIS = {
    "src/A.sol:A": [
        _CONSTRUCTOR,
        _function("deposit", "nonpayable", _UINT256),
        _function("owner", "view"),
        _function("withdraw", "nonpayable", _UINT256),
        _EVENT,
    ],
    "src/B.sol:B": [_function("claim", "nonpayable"), _function("claim", "payable", _ADDRESS, _UINT256)],
}
# each function that changes state, its gas at $0.000008 and at $0.0000012: deposit is 250,000 x 0.000008 = $2
# and 250,000 x 0.0000012 = 30 cents; owner is a view
_ROWS_A = [["deposit", "250000", "$2.00", "30¢"], ["withdraw", "125000", "$1.00", "15¢"]]
_ROWS_B = [["claim()", "1000000", "$8.00", "$1.20"], ["claim(address,uint256)", "50000", "40¢", "6¢"]]

# cast 1.9.0's words for the provider's JSON-RPC error, and for a failure that is not the provider's
_PROVIDERS_ERROR = "Error: server returned an error response: error code -32603: Internal error"
_NO_CODE = "Error: contract 0x5f4ec3df9cbd43714fe2740f5e3616155c5b8419 does not have any code"

# records each call's arguments as a line of JSON, then answers it from the chain STUB_CAST_CHAIN describes,
# or fails with the next of that kind's "failures"
_STUB_CAST = r"""#!/usr/bin/env python3
import json, os, sys

argv = sys.argv[1:]
with open(os.environ["STUB_CAST_RECORD"], "a") as record:
    record.write(json.dumps(argv) + "\n")
with open(os.environ["STUB_CAST_CHAIN"]) as described:
    chain = json.load(described)


def kind(arguments):
    if arguments[0] == "call":
        return arguments[2].split("(")[0]
    if arguments[0] == "rpc":
        return arguments[1]
    return arguments[0]


with open(os.environ["STUB_CAST_RECORD"]) as record:
    made = sum(1 for line in record if kind(json.loads(line)) == kind(argv))
failures = chain.get("failures", {}).get(kind(argv), [])
if made <= len(failures):
    print(failures[made - 1], file=sys.stderr)
    sys.exit(1)


def fees(block):
    return [[base, tip] for first, base, tip in chain["fees"] if first <= block][-1]


def sized(value):
    return f"{value} [{value:.3e}]".replace("e+", "e")


what = kind(argv)
if what == "block-number":
    print(chain["block"])
elif what == "block":
    print(chain["timestamp"])
elif what == "gas-price":
    print(chain["gas_price"])
elif what == "decimals":
    print(chain["decimals"])
elif what == "latestRoundData":
    for value in (129127208515966896657, chain["answer"], chain["updated_at"], chain["updated_at"], 129127208515966896657):
        print(sized(value))
elif what == "eth_feeHistory":
    count, newest = int(argv[2]), int(argv[3], 16)
    count = min(count, chain.get("served", count))
    blocks = range(newest - count + 1, newest + 1)
    following = fees(newest + 1)[0] if newest < chain["block"] else chain["next_base_fee"]
    print(json.dumps({
        "oldestBlock": hex(blocks[0]),
        "reward": [[hex(fees(block)[1])] for block in blocks],
        "baseFeePerGas": [hex(fees(block)[0]) for block in blocks] + [hex(following)],
        "gasUsedRatio": [0.5 for _ in blocks],
    }, separators=(",", ":")))
else:
    print(f"stub cast: no answer for {argv}", file=sys.stderr)
    sys.exit(2)
"""


def _gas_txt(contracts: dict[str, dict[str, int]]) -> str:
    """A regression/gas.txt holding `contracts`, each a `file:Contract` to its functions' gas."""
    parts = ["# regression: better=lower abs=500 rel=0.001 display={:.3e} ratchet=on\n"]
    for contract, functions in contracts.items():
        parts.append(f"\n{contract}\n| function name | max | display |\n|---------------|-----|---------|\n")
        parts.extend(f"| {function} | {gas} | {gas:.3e} |\n" for function, gas in functions.items())
    return "".join(parts)


def _builds(abis: dict[str, list[dict]]) -> dict[str, tuple[str, list[dict]]]:
    """The build files a gas run leaves for `abis`, each a `file:Contract` to its ABI: by where forge writes
    each under out/_gas, `<File>.sol/<Contract>.json`, to the contract and its ABI."""
    built = {}
    for contract, abi in abis.items():
        path, name = contract.split(":")
        built[f"{pathlib.Path(path).name}/{name}.json"] = (contract, abi)
    return built


def _run(
    folder: pathlib.Path,
    chain: dict | None = None,
    gas: dict[str, dict[str, int]] | None = _GAS,
    builds: dict[str, tuple[str, list[dict]]] | None = None,
) -> tuple[subprocess.CompletedProcess, list[list[str]]]:
    """Run bin/gas-usd in `folder`/work, holding `gas` as regression/gas.txt (none when None) and `builds` under
    out/_gas (`_ABIS`' when None), with a stub cast answering from `_CHAIN` updated by `chain`; the finished
    process, and the arguments of every call cast got."""
    stub_dir = folder / "stub"
    stub_dir.mkdir(parents=True)
    stub = stub_dir / "cast"
    stub.write_text(_STUB_CAST)
    stub.chmod(0o755)
    work = folder / "work"
    (work / "regression").mkdir(parents=True)
    if gas is not None:
        (work / "regression" / "gas.txt").write_text(_gas_txt(gas))
    for relative, (contract, abi) in (_builds(_ABIS) if builds is None else builds).items():
        path, name = contract.split(":")
        build = work / "out" / "_gas" / relative
        build.parent.mkdir(parents=True, exist_ok=True)
        build.write_text(json.dumps({"abi": abi, "metadata": {"settings": {"compilationTarget": {path: name}}}}))
    described = folder / "chain.json"
    described.write_text(json.dumps(_CHAIN | (chain or {})))
    record = folder / "cast.jsonl"
    env = {
        **os.environ,
        "PATH": f"{stub_dir}{os.pathsep}{os.environ['PATH']}",
        "STUB_CAST_RECORD": str(record),
        "STUB_CAST_CHAIN": str(described),
    }
    ran = subprocess.run(
        [sys.executable, str(_BIN / "gas-usd")], cwd=work, env=env, capture_output=True, text=True, check=False
    )
    calls = [json.loads(line) for line in record.read_text().splitlines()] if record.exists() else []
    return ran, calls


def _tables(output: str) -> list[tuple[str, list[list[str]]]]:
    """The tables in `output`, in order: each as the line naming its contract and the cells of each row below
    the table's heading."""
    tables = []
    for block in output.split("\n\n"):
        lines = block.strip("\n").splitlines()
        if len(lines) > 1 and lines[1].startswith("|"):
            rows = [[cell.strip() for cell in line.strip().strip("|").split("|")] for line in lines[3:]]
            tables.append((lines[0], rows))
    return tables


def _line(output: str, label: str) -> str:
    """The line of `output` that starts with `label`."""
    [line] = [line for line in output.splitlines() if line.startswith(label)]
    return line


def _closing(output: str) -> list[str]:
    """The lines `output` ends with, after its last blank line."""
    return output.rstrip("\n").split("\n\n")[-1].splitlines()


def _fee_requests(calls: list[list[str]]) -> list[list[str]]:
    """The eth_feeHistory calls among `calls`."""
    return [call for call in calls if call[:2] == ["rpc", "eth_feeHistory"]]


# ── the figures ──
def test_each_row_is_its_gas_priced_at_the_gas_price_now_and_the_day_average(tmp_path):
    ran, _ = _run(tmp_path, gas={"src/A.sol:A": {"deposit": 250_000}})
    assert ran.returncode == 0, ran.stderr
    assert _tables(ran.stdout) == [("src/A.sol:A", [["deposit", "250000", "$2.00", "30¢"]])]


@pytest.mark.parametrize(
    ("gas", "expected"),
    [
        ({}, []),
        ({"src/A.sol:A": _GAS["src/A.sol:A"]}, [("src/A.sol:A", _ROWS_A)]),
        (_GAS, [("src/A.sol:A", _ROWS_A), ("src/B.sol:B", _ROWS_B)]),
    ],
    ids=["no contracts", "one contract", "two contracts"],
)
def test_every_contract_and_function_is_priced_in_gas_txt_order(tmp_path, gas, expected):
    ran, _ = _run(tmp_path, gas=gas)
    assert ran.returncode == 0, ran.stderr
    assert _tables(ran.stdout) == expected
    assert _line(ran.stdout, "ETH/USD")


def test_a_cost_from_a_dollar_is_in_dollars_to_the_cent_and_one_below_a_dollar_in_cents(tmp_path):
    # 154,320,975 x 0.000008 = $1,234.5678 and x 0.0000012 = $185.18517; 51,250 x 0.000008 = $0.41 and
    # x 0.0000012 = $0.0615
    gas = {"src/C.sol:C": {"big": 154_320_975, "small": 51_250}}
    abis = {"src/C.sol:C": [_function("big", "nonpayable"), _function("small", "nonpayable")]}
    ran, _ = _run(tmp_path, gas=gas, builds=_builds(abis))
    assert _tables(ran.stdout) == [
        ("src/C.sol:C", [["big", "154320975", "$1,234.57", "$185.19"], ["small", "51250", "41¢", "6¢"]])
    ]


def test_a_cost_that_rounds_to_a_dollar_is_in_dollars(tmp_path):
    # 124,375 x 0.000008 = $0.995, which rounds up to a dollar, and 124,374 x 0.000008 = $0.994992 to 99 cents;
    # at the day average they are $0.14925 and $0.1492488, both 15 cents
    gas = {"src/C.sol:C": {"dollar": 124_375, "under": 124_374}}
    abis = {"src/C.sol:C": [_function("dollar", "nonpayable"), _function("under", "nonpayable")]}
    ran, _ = _run(tmp_path, gas=gas, builds=_builds(abis))
    assert _tables(ran.stdout) == [
        ("src/C.sol:C", [["dollar", "124375", "$1.00", "15¢"], ["under", "124374", "99¢", "15¢"]])
    ]


def test_the_last_digit_of_a_cost_in_cents_is_under_that_of_a_cost_in_dollars(tmp_path):
    # a cost in dollars is followed by a space, where a cost in cents has its ¢
    ran, _ = _run(tmp_path, gas={"src/B.sol:B": _GAS["src/B.sol:B"]})
    dollars = _line(ran.stdout, "| claim() ")
    cents = _line(ran.stdout, "| claim(address,uint256) ")
    for in_dollars, in_cents in (("$8.00", "40¢"), ("$1.20", "6¢")):
        # the column after each figure's last digit
        assert dollars.index(in_dollars) + len(in_dollars) == cents.index(in_cents) + len(in_cents) - len("¢"), (
            f"{dollars}\n{cents}"
        )


def test_the_header_states_the_block_the_prices_and_the_fixed_transaction_cost(tmp_path):
    # 21,000 gas at 4 gwei with ETH at $2,000 is $0.168, and at 0.6 gwei $0.0252
    ran, _ = _run(tmp_path)
    assert "block 20000000 (2027-01-15 08:00 UTC)" in ran.stdout.splitlines()[0], ran.stdout
    assert "$2,000.00" in _line(ran.stdout, "ETH/USD")
    assert "updated 2027-01-15 07:45 UTC" in _line(ran.stdout, "ETH/USD")
    assert "4.000 gwei" in _line(ran.stdout, "gas price now")
    assert "0.6000 gwei" in _line(ran.stdout, "gas price, day average")
    fixed = _line(ran.stdout, "fixed transaction cost")
    assert "21000 gas" in fixed and "17¢ now, 3¢ at the day average" in fixed, fixed


def test_a_fixed_transaction_cost_in_dollars_is_followed_by_its_words_alone(tmp_path):
    # 21,000 gas at 40 gwei with ETH at $2,000 is $1.68
    ran, _ = _run(tmp_path, chain={"gas_price": 40 * _GWEI})
    fixed = _line(ran.stdout, "fixed transaction cost")
    assert "$1.68 now, 3¢ at the day average" in fixed, fixed


# ── which rows are shown ──
def test_only_functions_that_change_state_are_shown(tmp_path):
    gas = {"src/C.sol:C": {"burn": 250_000, "pay": 250_000, "peek": 250_000, "price": 250_000}}
    abis = {
        "src/C.sol:C": [
            _function("burn", "nonpayable"),
            _function("pay", "payable"),
            _function("peek", "view"),
            _function("price", "pure"),
        ]
    }
    ran, _ = _run(tmp_path, gas=gas, builds=_builds(abis))
    assert [row[0] for row in _tables(ran.stdout)[0][1]] == ["burn", "pay"]


def test_an_overloaded_function_is_matched_by_its_signature(tmp_path):
    # forge names an overloaded function by its signature, a tuple by its members' types
    gas = {
        "src/C.sol:C": {
            "claim()": 250_000,
            "claim(address,uint256)": 250_000,
            "settle((uint256,address)[])": 250_000,
            "settle(uint256)": 250_000,
        }
    }
    abis = {
        "src/C.sol:C": [
            _function("claim", "nonpayable"),
            _function("claim", "view", _ADDRESS, _UINT256),
            _function("settle", "nonpayable", _ORDERS),
            _function("settle", "view", _UINT256),
        ]
    }
    ran, _ = _run(tmp_path, gas=gas, builds=_builds(abis))
    assert [row[0] for row in _tables(ran.stdout)[0][1]] == ["claim()", "settle((uint256,address)[])"]


def test_a_row_whose_function_the_contract_lacks_is_left_out_and_named(tmp_path):
    # forge records a call to a selector the contract does not have - a probe for an optional function - under
    # the name another contract gives that selector
    gas = {"src/C.sol:C": {"ASSET_TOKEN": 2_000, "burn": 250_000}}
    ran, _ = _run(tmp_path, gas=gas, builds=_builds({"src/C.sol:C": [_function("burn", "nonpayable")]}))
    assert [row[0] for row in _tables(ran.stdout)[0][1]] == ["burn"]
    assert _closing(ran.stdout)[-1] == "left out - not a function of its contract: src/C.sol:C ASSET_TOKEN"


def test_a_row_below_a_cent_at_both_prices_is_left_out(tmp_path):
    # 625 x 0.000008 is $0.005, which rounds up to a cent; 624 is $0.004992 now and $0.0007488 at the day
    # average, both below half a cent
    gas = {"src/C.sol:C": {"edge": 625, "under": 624}}
    abis = {"src/C.sol:C": [_function("edge", "nonpayable"), _function("under", "nonpayable")]}
    ran, _ = _run(tmp_path, gas=gas, builds=_builds(abis))
    assert _tables(ran.stdout) == [("src/C.sol:C", [["edge", "625", "1¢", "0¢"]])]


def test_a_row_reaching_a_cent_at_one_price_only_is_shown(tmp_path):
    # with gas quoted at 0.1 gwei, 10,000 gas is $0.002 now and $0.012 at the day average
    gas = {"src/C.sol:C": {"probe": 10_000}}
    builds = _builds({"src/C.sol:C": [_function("probe", "nonpayable")]})
    ran, _ = _run(tmp_path, chain={"gas_price": _GWEI // 10}, gas=gas, builds=builds)
    assert _tables(ran.stdout) == [("src/C.sol:C", [["probe", "10000", "0¢", "1¢"]])]


@pytest.mark.parametrize(("left", "functions"), [(0, ["peek"]), (1, ["burn", "peek"]), (2, ["burn", "mint", "peek"])])
def test_a_contract_with_no_row_left_is_not_shown(tmp_path, left, functions):
    gas = {"src/C.sol:C": dict.fromkeys(functions, 250_000)}
    abis = {
        "src/C.sol:C": [_function("burn", "nonpayable"), _function("mint", "nonpayable"), _function("peek", "view")]
    }
    ran, _ = _run(tmp_path, gas=gas, builds=_builds(abis))
    shown = [["burn", "250000", "$2.00", "30¢"], ["mint", "250000", "$2.00", "30¢"]][:left]
    assert _tables(ran.stdout) == ([("src/C.sol:C", shown)] if left else [])


def test_contracts_under_test_are_left_out(tmp_path):
    # a test's contracts are never deployed; none has a build file here, so none is looked for
    gas = {"src/A.sol:A": _GAS["src/A.sol:A"], "test/mocks/M.sol:M": {"deposit": 250_000}}
    ran, _ = _run(tmp_path, gas=gas, builds=_builds({"src/A.sol:A": _ABIS["src/A.sol:A"]}))
    assert ran.returncode == 0, ran.stderr
    assert [contract for contract, _ in _tables(ran.stdout)] == ["src/A.sol:A"]
    assert _closing(ran.stdout) == [
        "left out - view or pure: 1, below a cent at both prices: 0, contracts under test/: 1"
    ]


def test_the_closing_lines_count_what_was_left_out(tmp_path):
    gas = {
        "src/C.sol:C": {"ASSET_TOKEN": 2_000, "VERSION": 300, "burn": 250_000, "peek": 250_000, "tiny": 100},
        "test/mocks/M.sol:M": {"deposit": 250_000},
        "test/mocks/N.sol:N": {"deposit": 250_000},
    }
    abis = {"src/C.sol:C": [_function("burn", "nonpayable"), _function("peek", "view"), _function("tiny", "payable")]}
    ran, _ = _run(tmp_path, gas=gas, builds=_builds(abis))
    assert _closing(ran.stdout) == [
        "left out - view or pure: 1, below a cent at both prices: 1, contracts under test/: 2",
        "left out - not a function of its contract: src/C.sol:C ASSET_TOKEN, src/C.sol:C VERSION",
    ]


@pytest.mark.parametrize(
    ("builds", "found"),
    [
        # a contract of the same name compiled from another source is not its build
        ({"A.sol/A.json": ("src/other/A.sol:A", _ABIS["src/A.sol:A"])}, 0),
        (_builds(_ABIS) | {"nested/A.sol/A.json": ("src/A.sol:A", _ABIS["src/A.sol:A"])}, 2),
    ],
    ids=["none", "two"],
)
def test_a_contract_without_one_build_file_stops_the_run(tmp_path, builds, found):
    ran, calls = _run(tmp_path, gas={"src/A.sol:A": _GAS["src/A.sol:A"]}, builds=builds)
    assert ran.returncode == 1
    assert f"src/A.sol:A: {found} build files" in ran.stderr, ran.stderr
    assert ran.stdout == ""
    assert calls == []


# ── the day average ──
def test_the_day_average_reads_7200_blocks_back_from_the_read_block_in_requests_of_at_most_1024(tmp_path):
    # seven of 1,024 and one of 32, each ending where the one before began: blocks 19,992,801 to 20,000,000
    ran, calls = _run(tmp_path)
    assert ran.returncode == 0, ran.stderr
    requests = [(int(call[2]), int(call[3], 16), call[4]) for call in _fee_requests(calls)]
    assert requests == [(1024, _BLOCK - 1024 * i, "[50]") for i in range(7)] + [(32, 19_992_832, "[50]")]


def test_the_day_average_is_the_mean_of_each_blocks_base_fee_plus_median_tip(tmp_path):
    # (1,800 x 1.8 + 5,400 x 0.2) / 7,200 = 0.6 gwei. Counting the next block's base fee each response carries
    # gives 0.7392, the base fee alone 0.4125, the last 1,024 blocks alone 1.8, and the 7,200 blocks before the
    # block read 0.5998.
    ran, _ = _run(tmp_path)
    assert "0.6000 gwei" in _line(ran.stdout, "gas price, day average")


def test_a_provider_that_returns_fewer_blocks_than_asked_stops_the_run(tmp_path):
    # a provider that caps a request lower than 1,024 returns the newest it serves; summing those would leave
    # blocks out of the day without a word
    ran, _ = _run(tmp_path, chain={"served": 500})
    assert ran.returncode == 1
    assert "500" in ran.stderr and "1024" in ran.stderr, ran.stderr
    assert ran.stdout == ""


# ── the ETH price ──
@pytest.mark.parametrize("decimals", [8, 18])
def test_the_eth_price_is_scaled_by_the_feeds_own_decimals(tmp_path, decimals):
    ran, _ = _run(tmp_path, chain={"decimals": decimals, "answer": 2_000 * 10**decimals})
    assert "$2,000.00" in _line(ran.stdout, "ETH/USD")
    assert _tables(ran.stdout)[0][1][0] == ["deposit", "250000", "$2.00", "30¢"]


def test_the_price_feed_and_the_block_time_are_read_at_the_block_read(tmp_path):
    _, calls = _run(tmp_path)
    pinned = [call for call in calls if call[0] in ("call", "block")]
    assert len(pinned) == 3, calls
    for call in pinned:
        assert "20000000" in call, call
        if call[0] == "call":
            assert call[call.index("--block") + 1] == "20000000", call


def test_every_chain_read_is_of_mainnet(tmp_path):
    _, calls = _run(tmp_path)
    assert calls
    for call in calls:
        assert call[-2:] == ["--rpc-url", "mainnet"], call


# ── failures ──
def test_a_provider_error_is_retried_once_and_the_run_succeeds(tmp_path):
    clean, _ = _run(tmp_path / "clean")
    ran, calls = _run(tmp_path / "failed", chain={"failures": {"eth_feeHistory": [_PROVIDERS_ERROR]}})
    assert ran.returncode == 0, ran.stderr
    requests = _fee_requests(calls)
    assert len(requests) == 9 and requests[0] == requests[1], requests
    assert ran.stdout == clean.stdout
    assert _PROVIDERS_ERROR in ran.stderr


def test_a_second_provider_error_stops_the_run_naming_the_command_and_the_error(tmp_path):
    ran, calls = _run(tmp_path, chain={"failures": {"eth_feeHistory": [_PROVIDERS_ERROR, _PROVIDERS_ERROR]}})
    assert ran.returncode == 1
    assert len(_fee_requests(calls)) == 2
    assert "cast rpc eth_feeHistory 1024 0x1312d00 '[50]' --rpc-url mainnet" in ran.stderr, ran.stderr
    assert ran.stderr.strip().endswith(_PROVIDERS_ERROR), ran.stderr
    assert ran.stdout == ""


def test_any_other_cast_failure_stops_the_run_without_a_retry(tmp_path):
    ran, calls = _run(tmp_path, chain={"failures": {"latestRoundData": [_NO_CODE]}})
    assert ran.returncode == 1
    assert len([call for call in calls if "latestRoundData()(uint80,int256,uint256,uint256,uint80)" in call]) == 1
    assert ran.stderr.strip().endswith(_NO_CODE), ran.stderr
    assert ran.stdout == ""


def test_a_missing_gas_txt_stops_the_run_naming_the_path(tmp_path):
    ran, calls = _run(tmp_path, gas=None)
    assert ran.returncode == 1
    assert "regression/gas.txt" in ran.stderr, ran.stderr
    assert calls == []
