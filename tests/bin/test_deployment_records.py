"""bin/deployment_records.py reads two record formats written by two unrelated writers.

The fixtures reproduce the SHAPES found in the five repos on 2026-09-09, not their contents: each one
is a real trap that a reader keyed on filenames or on a fixed depth falls into. They are built here
rather than pointed at the repos so the tests stay reproducible - the real files change with every
deploy, and a test that read them would pass or fail on what someone shipped that morning.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "bin"))

from deployment_records import read_records  # noqa: E402


def git(where: Path, *arguments: str) -> None:
    subprocess.run(["git", *arguments], cwd=where, capture_output=True, text=True, check=True)


def write(repo: Path, relative: str, document: dict, track: bool = True) -> None:
    """Write a record and, unless asked not to, put it in the index - which is what makes it a record
    of this repository rather than one machine's scratch."""
    path = repo / "deployments" / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(document, indent=2))
    if track:
        git(repo, "add", str(path.relative_to(repo)))


@pytest.fixture
def repo(tmp_path):
    git(tmp_path, "init", "-q", "-b", "main")
    git(tmp_path, "config", "user.email", "t@t")
    git(tmp_path, "config", "user.name", "test")
    (tmp_path / "deployments").mkdir()
    return tmp_path


def by_name(entries):
    return {e.name: e for e in entries}


def test_a_repository_with_no_deployments_records_nothing(repo):
    assert read_records(repo) == []


def test_an_ignored_record_is_not_this_repositorys_claim(repo):
    # harbor gitignores `deployments/local*/`, where a local fork deploy leaves a state file that
    # looks exactly like the real one. Reading it reported findings against one machine's scratch.
    #
    # The rule is IGNORED, not untracked: this is read by a manually-run script, which must see a
    # record that has been written but not yet staged. Using the index for that would hide a fresh
    # deploy's own output from the tool that has to check it.
    (repo / ".gitignore").write_text("deployments/local*/\n")
    write(
        repo,
        "mainnet/real.state.json",
        {"implementations": {"0xAA": {"contractSource": "src/Real.sol", "contractType": "Real"}}},
    )
    write(
        repo,
        "local/mainnet/scratch.state.json",
        {"implementations": {"0xBB": {"contractSource": "src/Scratch.sol", "contractType": "Scratch"}}},
        track=False,
    )
    write(
        repo,
        "mainnet/fresh.state.json",
        {"implementations": {"0xCC": {"contractSource": "src/Fresh.sol", "contractType": "Fresh"}}},
        track=False,
    )

    assert sorted(e.name for e in read_records(repo)) == ["Fresh", "Real"]


def test_format_a_pairs_the_address_it_is_keyed_by_with_the_source_it_names(repo):
    # harbor's *.state.json, bao-base's state.json, the aggregators' v3/v4-aggregators.json - one
    # writer, the shared Solidity serializer, which is why four repos agree on this shape.
    write(
        repo,
        "mainnet/harbor_v1.state.json",
        {
            "network": "mainnet",
            "implementations": {
                "0xd8785d5C51aaDEb3AD1D015Cd67C8A34dBf58f61": {
                    "contractSource": "@bao/BaoPauser_v1.sol",
                    "contractType": "BaoPauser_v1",
                    "deploymentTime": "2026-03-21T13:44:18Z",
                }
            },
        },
    )

    found = read_records(repo)

    assert len(found) == 1
    entry = found[0]
    assert entry.address == "0xd8785d5C51aaDEb3AD1D015Cd67C8A34dBf58f61"
    assert (entry.name, entry.recorded_path) == ("BaoPauser_v1", "@bao/BaoPauser_v1.sol")
    assert entry.chain == "mainnet"
    assert entry.manifest == "deployments/mainnet/harbor_v1.state.json"


def test_format_b_splits_the_path_and_name_it_fuses(repo):
    # The aggregators' oracle manifests fuse them with a colon and key by symbol, carrying the address
    # inside the entry - so both halves of the identity live somewhere different from format A.
    write(
        repo,
        "mainnet/v4-oracles.json",
        {
            "chainName": "mainnet",
            "oracles": {
                "STETH_USD": {
                    "name": "stETH/USD",
                    "address": "0x28bBAaf05dEE8A06d4206089bCd17c1129e6Edca",
                    "contractPath": "src/mainnet/Aggregator_stETH_USD_mainnet.sol:Aggregator_stETH_USD_mainnet",
                }
            },
        },
    )

    entry = read_records(repo)[0]

    assert entry.address == "0x28bBAaf05dEE8A06d4206089bCd17c1129e6Edca"
    assert entry.name == "Aggregator_stETH_USD_mainnet"
    assert entry.recorded_path == "src/mainnet/Aggregator_stETH_USD_mainnet.sol"
    assert ":" not in entry.recorded_path, "the fused suffix belongs to the name, not the path"


def test_one_file_carrying_both_sections_yields_both(repo):
    # v3-oracles.json's actual shape, and the trap: it has BOTH sections, and its `implementations`
    # entries carry a contractName and NO path. A reader that dispatches on the filename reads one
    # section and silently returns nothing for the other.
    write(
        repo,
        "mainnet/v3-oracles.json",
        {
            "chainName": "mainnet",
            "oracles": {
                "FXUSD_BTC": {
                    "address": "0x9f62503D61cdA530216ad46c1d239258bd201034",
                    "contractPath": "src/Aggregator_fxUSD_BTC_mainnet.sol:Aggregator_fxUSD_BTC_mainnet",
                }
            },
            "implementations": {
                "0xbE19765f4711Ba7e88D98Eec096d7f21a3E0eeCf": {
                    "contractName": "Aggregator_fxUSD_STRC_mainnet",
                    "deployedAt": "2026-08-17T21:24:13Z",
                }
            },
        },
    )

    found = by_name(read_records(repo))

    assert set(found) == {"Aggregator_fxUSD_BTC_mainnet", "Aggregator_fxUSD_STRC_mainnet"}
    assert found["Aggregator_fxUSD_BTC_mainnet"].section == "oracles"
    assert found["Aggregator_fxUSD_STRC_mainnet"].section == "implementations"


def test_a_contract_named_without_a_path_is_returned_as_a_gap_not_dropped(repo):
    # It is a deployed contract nothing can currently baseline. Dropping it would report a repository
    # as fully recorded while one of its contracts has no source at all.
    write(
        repo,
        "mainnet/v3-oracles.json",
        {
            "implementations": {
                "0xbE19765f4711Ba7e88D98Eec096d7f21a3E0eeCf": {
                    "contractName": "Aggregator_fxUSD_STRC_mainnet",
                    "deployedAt": "2026-08-17T21:24:13Z",
                }
            }
        },
    )

    entry = read_records(repo)[0]

    assert entry.name == "Aggregator_fxUSD_STRC_mainnet"
    assert entry.recorded_path is None, "the gap is the finding; it must survive reading"
    assert entry.deployed_at == "2026-08-17T21:24:13Z", "both spellings of the timestamp are read"


def test_a_file_that_describes_no_deployed_contract_yields_nothing(repo):
    # harbor's per-market files hold deploy CONFIGURATION under `contracts`, and forge's broadcast
    # files hold transactions. Neither is excluded by name - neither has a section this recognises,
    # which is what stops a new manifest being silently skipped by an out-of-date exclusion list.
    write(repo, "harbor_v1::ETH::fxUSD.json", {"prefix": "harbor_v1", "contracts": {"minter": {"config": {}}}})
    write(repo, "broadcast/Deploy.s.sol/1/run-latest.json", {"transactions": [{"contractName": "Foo"}]})

    assert read_records(repo) == []


def test_proxy_entries_are_not_mistaken_for_deployed_source(repo):
    # `proxies` sits beside `implementations` and keys by name, but an ERC1967 proxy's bytecode is not
    # built from this repository's source, so it has no baseline and must not claim one.
    write(
        repo,
        "mainnet/state.json",
        {
            "network": "mainnet",
            "implementations": {"0xAA": {"contractSource": "src/Foo.sol", "contractType": "Foo"}},
            "proxies": {"BTC::pegged": {"address": "0xBB", "implementation": "0xAA", "salt": "harbor_v1::BTC"}},
        },
    )

    found = read_records(repo)

    assert [e.name for e in found] == ["Foo"]


def test_the_chain_falls_back_to_the_directory_when_the_record_does_not_say(repo):
    # Records written before either spelling of the field exist, and they are organised by directory,
    # so that is the honest last resort. chainId is deliberately not consulted - mapping a number back
    # to a name would duplicate a table that belongs elsewhere.
    write(
        repo,
        "arbitrum/v3-aggregators.json",
        {"chainId": 42161, "implementations": {"0xAA": {"contractSource": "src/A.sol", "contractType": "A"}}},
    )

    assert read_records(repo)[0].chain == "arbitrum"


def test_an_unreadable_manifest_is_raised_not_skipped(repo):
    # Silently returning a shorter list reads as "this repository deploys less than it does", which is
    # the failure this whole plan exists to stop.
    (repo / "deployments" / "broken.json").write_text("{not json")
    git(repo, "add", "deployments/broken.json")

    with pytest.raises(json.JSONDecodeError):
        read_records(repo)
