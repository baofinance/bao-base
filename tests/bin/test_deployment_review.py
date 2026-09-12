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


def baseline_for(address: str = "0xAA", commit: str = "a" * 40) -> Baseline:
    return Baseline(
        chainId=1,
        chain="mainnet",
        address=address,
        contractType="Foo",
        source="src/Foo.sol",
        commit=commit,
        commitTimestamp="2026-03-19T20:50:21Z",
        deployBlock=24706244,
        deployTimestamp="2026-03-21T13:41:23Z",
        creationBytecodeKeccak256="b" * 64,
        compiler="0.8.30+commit.73712a01",
        settings={"evmVersion": "cancun", "optimizer": {"enabled": True, "runs": 700}},
        sources={"src/Foo.sol": "d" * 40},
        submodules={},
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

    assert [b.contractType for b in found.recorded] == ["Foo"]
    assert found.unrecovered == []


def test_deleting_a_manifest_entry_orphans_its_baseline(repo):
    # harbor's eleven dropped `Minter_v2` entries, made impossible to repeat quietly. The baseline
    # outlives the deletion and says so, with no git archaeology needed to notice.
    write_baselines(repo, add({}, baseline_for()))
    (repo / "deployments" / "mainnet" / "state.json").write_text(json.dumps({"implementations": {}}))

    found = review(repo)

    assert [b.contractType for b in found.orphaned] == ["Foo"]
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


def push_to_a_new_remote(repo: Path, tmp_path: Path) -> None:
    remote = tmp_path / "remote.git"
    subprocess.run(["git", "init", "-q", "--bare", str(remote)], check=True, capture_output=True)
    git(repo, "remote", "add", "origin", str(remote))
    git(repo, "push", "-q", "origin", "main")


def declare(repo: Path, path: str, contract: str) -> None:
    """Commit `path` declaring `contract`, so the source says something a record can agree with."""
    (repo / path).write_text(f"contract {contract} {{}}\n")
    git(repo, "add", "-A")
    subprocess.run(["git", "commit", "-qm", f"declare {contract}"], cwd=repo, check=True, capture_output=True)


def head_of(repo: Path) -> str:
    return subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True).stdout.strip()


def test_a_baseline_on_a_pushed_commit_is_not_reported(repo, tmp_path):
    push_to_a_new_remote(repo, tmp_path)
    write_baselines(repo, add({}, baseline_for(commit=head_of(repo))))

    assert review(repo).not_on_a_remote == []


def test_a_baseline_on_a_commit_only_this_clone_has_is_reported_with_where_it_lives(repo, tmp_path):
    # Recordable locally, rejected by CI. Carrying the REACH rather than a boolean is what lets one
    # definition serve both: the recorder tolerates "local", the CI check does not.
    push_to_a_new_remote(repo, tmp_path)
    (repo / "src" / "Later.sol").write_text("// later\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "not pushed")
    write_baselines(repo, add({}, baseline_for(commit=head_of(repo))))

    found = review(repo)

    assert [(b.contractType, reach) for b, reach in found.not_on_a_remote] == [("Foo", "local")]


def test_a_baseline_on_a_commit_this_repository_has_lost_is_reported_as_absent(repo, tmp_path):
    # The reachability failure itself: a force-push, an orphaning rebase, or garbage collection, and
    # the record points at nothing. Distinguished from "not pushed" because the remedy differs.
    push_to_a_new_remote(repo, tmp_path)
    write_baselines(repo, add({}, baseline_for(commit="0" * 40)))

    found = review(repo)

    assert [(b.contractType, reach) for b, reach in found.not_on_a_remote] == [("Foo", "absent")]


def test_a_record_naming_a_contract_its_source_does_not_declare_is_reported(repo, tmp_path):
    # A deployment record is a record of a deployment, so its contract name is the name at deploy time
    # and the source at that commit declares exactly that. Twelve of the aggregators' eighty-three
    # disagree, every one a rewrite after a rename: `deployments/mainnet/v4-oracles.json` said
    # `Aggregator_sUSDe_BTC_mainnet` on 2026-02-07 and `Aggregator_USDE_BTC_mainnet` from 2026-04-24 —
    # same address, same bytecode, name changed underneath it.
    #
    # The bytecode match does not rescue it: a RENAME CHANGES NO BYTECODE, so a match is never evidence
    # about the name. Which is why this is an error rather than a note.
    push_to_a_new_remote(repo, tmp_path)
    declare(repo, "src/Foo.sol", "Renamed")
    write_baselines(repo, add({}, baseline_for(commit=head_of(repo))))

    found = review(repo)

    assert len(found.misnamed) == 1
    baseline, declares = found.misnamed[0]
    assert (baseline.contractType, declares) == ("Foo", "Renamed"), "both names, so the fix is obvious"


def test_a_record_agreeing_with_its_source_is_not_reported(repo, tmp_path):
    # The ordinary case, including a contract renamed AFTER its deploy: the record keeps the deploy-time
    # name, the source at that commit declares it, and they agree. Only a rewritten record disagrees.
    push_to_a_new_remote(repo, tmp_path)
    declare(repo, "src/Foo.sol", "Foo")
    write_baselines(repo, add({}, baseline_for(commit=head_of(repo))))

    assert review(repo).misnamed == []


def test_a_record_whose_source_declares_no_contract_at_all_is_reported(repo, tmp_path):
    # The record points at a file that is not a contract, so nothing can be built from it and nothing
    # can be compared. Reported with the same finding rather than a separate one - the record and its
    # source disagree either way, and the fix is the same: make the record say what the source says.
    push_to_a_new_remote(repo, tmp_path)
    write_baselines(repo, add({}, baseline_for(commit=head_of(repo))))

    found = review(repo)

    assert [declares for _, declares in found.misnamed] == [None]


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


def test_a_contract_whose_manifest_gives_no_address_is_reported_not_silently_dropped(repo):
    # The address IS the identity here, so an entry without one cannot be keyed, cannot be looked up on
    # any chain, and cannot be recovered. `v4-oracles.json` holds five such placeholders.
    manifest = repo / "deployments" / "mainnet" / "state.json"
    manifest.write_text(
        json.dumps(
            {
                "network": "mainnet",
                "chainId": 1,
                "oracles": {"FOO": {"address": "", "contractPath": "src/Foo.sol:Foo"}},
            }
        )
    )

    found = review(repo)

    assert [problem.entry.name for problem in found.unreadable] == ["Foo"]
    assert "address" in found.unreadable[0].reason
    assert found.unrecovered == [], "it cannot be keyed, so it is not a recovery backlog item either"


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
