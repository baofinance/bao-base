"""The manifests and the record, read against each other.

The case with teeth is ORPHANED: once a baseline exists, deleting the manifest entry it belongs to
leaves a baseline nothing claims. harbor did exactly that - eleven `Minter_v2` implementations dropped
in one commit, still on chain, with nothing left saying what built them - and this is what stops it
happening quietly a second time, without reading git history to do it.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "bin"))

from deployment_baselines import Baseline, add, review, write_baselines  # noqa: E402

REMAPPINGS = '[profile.default]\nsrc = "src"\nremappings = ["@harbor/=src/"]\n'


def git(where: Path, *arguments: str) -> None:
    subprocess.run(["git", *arguments], cwd=where, capture_output=True, text=True, check=True)


@pytest.fixture
def repo(tmp_path):
    """A repo with one deployed contract recorded in a manifest, its source in history."""
    git(tmp_path, "init", "-q", "-b", "main")
    git(tmp_path, "config", "user.email", "t@t")
    git(tmp_path, "config", "user.name", "test")
    (tmp_path / "foundry.toml").write_text(REMAPPINGS)
    (tmp_path / "src").mkdir()
    (tmp_path / "src" / "Foo.sol").write_text("// foo\n")
    manifest = tmp_path / "deployments" / "mainnet" / "state.json"
    manifest.parent.mkdir(parents=True)
    manifest.write_text(
        json.dumps(
            {
                "network": "mainnet",
                "chainId": 1,
                "implementations": {"0xAA": {"contractSource": "src/Foo.sol", "contractType": "Foo"}},
            }
        )
    )
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-qm", "one")
    return tmp_path


def baseline_for(address: str = "0xAA") -> Baseline:
    return Baseline(
        chain_id=1,
        chain="mainnet",
        address=address,
        contract_type="Foo",
        source="src/Foo.sol",
        commit="a" * 40,
        commit_timestamp="2026-03-19T20:50:21Z",
        deploy_block=24706244,
        deploy_timestamp="2026-03-21T13:41:23Z",
        creation_bytecode_keccak256="b" * 64,
    )


def test_a_repository_that_has_recorded_nothing_yet_has_everything_unrecovered(repo):
    # The state every repo is in on the day this lands. It must not be a failure, or the check is red
    # from the moment it exists until the backlog is burnt down - which is how a check stops being read.
    found = review(repo)

    assert [entry.name for entry in found.unrecovered] == ["Foo"]
    assert found.recorded == [] and found.orphaned == [] and found.unreadable == []


def test_a_recorded_contract_stops_being_unrecovered(repo):
    write_baselines(repo, add({}, baseline_for()))

    found = review(repo)

    assert [b.contract_type for b in found.recorded] == ["Foo"]
    assert found.unrecovered == []


def test_deleting_a_manifest_entry_orphans_its_baseline(repo):
    # harbor's eleven dropped `Minter_v2` entries, made impossible to repeat quietly. The baseline
    # outlives the deletion and says so, with no git archaeology needed to notice.
    write_baselines(repo, add({}, baseline_for()))
    (repo / "deployments" / "mainnet" / "state.json").write_text(json.dumps({"implementations": {}}))

    found = review(repo)

    assert [b.contract_type for b in found.orphaned] == ["Foo"]
    assert found.recorded == []


def test_an_address_matches_however_either_side_spells_it(repo):
    # The manifest checksums it, the record lowercases it. If those failed to meet, every recorded
    # contract would read as both unrecovered AND orphaned - the worst possible answer, since it
    # invents a deletion that did not happen.
    write_baselines(repo, add({}, baseline_for(address="0xaa")))

    found = review(repo)

    assert len(found.recorded) == 1 and found.orphaned == [] and found.unrecovered == []


def test_one_contract_in_two_manifests_is_one_thing_to_recover(repo):
    # 44 of the aggregators' 85 addresses are in both `v3-aggregators.json` and `v3-oracles.json`, and
    # only one of the two carries `deploymentTime`. Listing them separately made 64 of 152 outcomes
    # read "no deployment time recorded" while the time sat in the other row - the address-is-the-
    # identity lesson, applied one layer up.
    manifests = repo / "deployments" / "mainnet"
    (manifests / "with-time.json").write_text(
        json.dumps(
            {
                "network": "mainnet",
                "chainId": 1,
                "implementations": {
                    "0xAA": {
                        "contractSource": "src/Foo.sol",
                        "contractType": "Foo",
                        "deploymentTime": "2026-03-21T00:00:00Z",
                    }
                },
            }
        )
    )
    (manifests / "state.json").write_text(
        json.dumps(
            {
                "network": "mainnet",
                "chainId": 1,
                "oracles": {"FOO": {"address": "0xAA", "contractPath": "src/Foo.sol:Foo"}},
            }
        )
    )
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "two manifests, one contract")

    found = review(repo)

    assert len(found.unrecovered) == 1, [e.manifest for e in found.unrecovered]
    assert found.unrecovered[0].deployed_at == "2026-03-21T00:00:00Z", "taken from whichever row has it"


def test_two_manifests_disagreeing_about_one_contract_is_reported_and_never_guessed(repo):
    # 11 of the aggregators' addresses are described by two manifests that give DIFFERENT paths - the
    # older one recorded `src/Aggregator_…` before the file moved to `src/mainnet/`. Keeping whichever
    # was read first made manifest filename order decide, silently.
    #
    # The disagreement is reported, and the field is left UNSET rather than picked: nothing downstream
    # should act on an arbitrary choice, and recovery finds the real path at the baseline commit by
    # contract name anyway.
    # The file really moved, so BOTH paths are in this repo's history - which is the actual situation:
    # the older manifest recorded where it was, the newer where it went.
    (repo / "src" / "moved").mkdir()
    (repo / "src" / "moved" / "Foo.sol").write_text("// foo\n")
    (repo / "src" / "Foo.sol").unlink()
    manifests = repo / "deployments" / "mainnet"
    (manifests / "a-first.json").write_text(
        json.dumps(
            {
                "network": "mainnet",
                "chainId": 1,
                "implementations": {"0xAA": {"contractSource": "src/Foo.sol", "contractType": "Foo"}},
            }
        )
    )
    (manifests / "state.json").write_text(
        json.dumps(
            {
                "network": "mainnet",
                "chainId": 1,
                "implementations": {"0xAA": {"contractSource": "src/moved/Foo.sol", "contractType": "Foo"}},
            }
        )
    )
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "the file moved; two manifests disagree")

    found = review(repo)

    assert len(found.conflicts) == 1, found.conflicts
    assert "src/Foo.sol" in found.conflicts[0] and "src/moved/Foo.sol" in found.conflicts[0]
    assert len(found.unrecovered) == 1
    assert found.unrecovered[0].recorded_path is None, "unset, so nothing acts on an arbitrary pick"


def test_a_contract_whose_manifest_gives_no_chain_id_is_reported_not_silently_dropped(repo):
    # A deployed contract with no usable chain id cannot be keyed, so it would vanish from every count -
    # exactly the "this repo deploys less than it does" failure the whole model exists to remove. One
    # MegaETH manifest records `chainId: 0` where four others say 4326.
    manifest = repo / "deployments" / "mainnet" / "state.json"
    manifest.write_text(
        json.dumps(
            {
                "network": "mainnet",
                "chainId": 0,
                "implementations": {"0xAA": {"contractSource": "src/Foo.sol", "contractType": "Foo"}},
            }
        )
    )

    found = review(repo)

    assert [problem.entry.name for problem in found.unreadable] == ["Foo"]
    # The reason quotes what the RECORD says, not what it was normalised to: "chainId is None" for a
    # manifest holding `chainId: 0` sends the reader looking for a missing field that is not missing.
    assert "chainId is 0" in found.unreadable[0].reason, found.unreadable[0].reason
    assert found.unrecovered == [], "it is not also a recovery backlog item, because it cannot be keyed"


def test_a_manifest_path_that_cannot_be_normalised_is_reported_not_failed(repo):
    # Pre-existing record defects - harbor's `src/BaoPauser_v1.sol` naming bao-base's file - must not
    # turn a repo red on the day this check lands. They are reported, and a baseline cannot be written
    # for one anyway, so recording forces them to be fixed.
    manifest = repo / "deployments" / "mainnet" / "state.json"
    manifest.write_text(
        json.dumps(
            {
                "network": "mainnet",
                "chainId": 1,
                "implementations": {"0xBB": {"contractSource": "src/NeverHere.sol", "contractType": "Ghost"}},
            }
        )
    )

    found = review(repo)

    assert len(found.unreadable) == 1
    assert found.unreadable[0].entry.name == "Ghost"
    assert found.unrecovered == [], "an entry that cannot be read is not also a recovery backlog item"
