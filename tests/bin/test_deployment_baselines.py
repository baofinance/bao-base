"""`deployed.json` — the record that replaces the tags.

Every case here is a property the record has to hold for the design to work: an address is one
identity however it is spelled, a baseline can be re-recorded but never replaced, and a reader stops
rather than misreads a schema it does not know.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "bin"))

from deployment_baselines import (  # noqa: E402
    RECORD,
    SCHEMA_VERSION,
    Baseline,
    Conflict,
    UnknownSchema,
    add,
    key,
    read_baselines,
    write_baselines,
)

PAUSER = Baseline(
    chain_id=1,
    chain="mainnet",
    address="0xd8785d5C51aaDEb3AD1D015Cd67C8A34dBf58f61",
    contract_type="BaoPauser_v1",
    source="src/BaoPauser_v1.sol",
    commit="a" * 40,
    commit_timestamp="2026-03-19T20:50:21Z",
    deploy_block=24706244,
    deploy_timestamp="2026-03-21T13:41:23Z",
    creation_bytecode_keccak256="b" * 64,
)


def test_a_repository_that_has_not_started_records_nothing(tmp_path):
    # The ordinary state of every repo before this lands, and not an error.
    assert read_baselines(tmp_path) == {}


def test_a_baseline_survives_the_round_trip(tmp_path):
    write_baselines(tmp_path, add({}, PAUSER))

    assert read_baselines(tmp_path) == {key(PAUSER.chain_id, PAUSER.address): PAUSER}


def test_an_address_is_one_identity_however_it_is_spelled(tmp_path):
    # Manifests carry checksummed addresses, so two spellings of one address would otherwise become
    # two baselines for one artefact.
    assert key(1, "0xABCdef") == key(1, "0xabcdef")


def test_the_chain_is_identified_by_its_id_not_by_a_name(tmp_path):
    # Eight spellings covered four chains - `Mainnet` and `mainnet`, `MegaETH` and `megaeth` - and a
    # name is a label anyone can write differently. The id is the chain. It also caught a manifest
    # recording `chainId: 0` for MegaETH where four others say 4326, which no amount of name-matching
    # would have noticed.
    assert key(1, "0xAA") != key(42161, "0xAA"), "one address, two chains, two contracts"
    assert key(1, "0xAA") == key(1, "0xAA")


def test_recording_the_same_fact_twice_is_a_no_op(tmp_path):
    # A deploy re-run, or a recovery pass covering ground it already covered, must be safe.
    once = add({}, PAUSER)

    assert add(once, PAUSER) == once


def test_a_different_claim_about_one_address_is_refused(tmp_path):
    # The artefact at an address never changed, so two claims cannot both be true - and which is true
    # is a question about the chain, not one this file can settle.
    other = Baseline(**{**PAUSER.__dict__, "commit": "c" * 40, "contract_type": "HarborPauser_v1"})

    with pytest.raises(Conflict) as refused:
        add(add({}, PAUSER), other)

    assert PAUSER.commit[:10] in str(refused.value), "the refusal names both claims"
    assert other.commit[:10] in str(refused.value)


def test_a_schema_it_does_not_know_stops_it_rather_than_being_misread(tmp_path):
    # Every manifest in the fleet carries `schemaVersion: 1` and nothing reads it, which makes the
    # field decoration. Asserting it is what makes changing the schema later safe.
    (tmp_path / RECORD).write_text(json.dumps({"schemaVersion": SCHEMA_VERSION + 1, "baselines": {}}))

    with pytest.raises(UnknownSchema):
        read_baselines(tmp_path)


def test_the_record_declares_its_schema(tmp_path):
    write_baselines(tmp_path, add({}, PAUSER))

    assert json.loads((tmp_path / RECORD).read_text())["schemaVersion"] == SCHEMA_VERSION


def test_the_file_is_camel_case_throughout_and_names_its_fields_as_the_manifests_do(tmp_path):
    # Every manifest in the fleet is camelCase - `contractSource`, `contractType`, `deploymentTime`,
    # `chainId` - so a reader moving between them should not have to translate. `contractType` keeps
    # the manifests' own spelling deliberately: a different name would invite the question of whether
    # it means something different. Python stays snake_case, because it is Python; the two conventions
    # meeting inside one JSON file is what this stops.
    write_baselines(tmp_path, add({}, PAUSER))

    fields = next(iter(json.loads((tmp_path / RECORD).read_text())["baselines"].values()))

    assert set(fields) == {
        "chainId",
        "chain",
        "address",
        "contractType",
        "source",
        "commit",
        "commitTimestamp",
        "deployBlock",
        "deployTimestamp",
        "creationBytecodeKeccak256",
    }
    assert not any("_" in name for name in fields), fields
    assert "Hash" not in "".join(fields), "the algorithm is named, not left for the value to declare"


def test_every_timestamp_is_utc(tmp_path):
    # Both come from Unix seconds - the block's own, and `git log --format=%ct` - never from a
    # formatter carrying a local offset, so a record does not depend on where the person recovering it
    # was sitting.
    write_baselines(tmp_path, add({}, PAUSER))

    fields = next(iter(json.loads((tmp_path / RECORD).read_text())["baselines"].values()))

    for name in ("commitTimestamp", "deployTimestamp"):
        assert fields[name].endswith("Z"), (name, fields[name])


def test_the_commit_predates_the_deploy_in_the_ordinary_case(tmp_path):
    # Not enforced - a commit made AFTER the deploy is a real and recordable state, meaning the deploy
    # ran from an uncommitted tree - but the two are stored so that it can be SEEN, which the tags
    # could never show.
    assert PAUSER.commit_timestamp < PAUSER.deploy_timestamp


def test_entries_are_written_sorted_so_two_deploys_collide_as_additions(tmp_path):
    # Racing deploys then conflict as two disjoint additions a human resolves by eye, rather than as a
    # reordering of the whole file.
    second = Baseline(**{**PAUSER.__dict__, "address": "0x0000000000000000000000000000000000000001"})
    write_baselines(tmp_path, add(add({}, PAUSER), second))

    written = list(json.loads((tmp_path / RECORD).read_text())["baselines"])

    assert written == sorted(written)


def test_the_file_ends_with_a_newline(tmp_path):
    write_baselines(tmp_path, add({}, PAUSER))

    assert (tmp_path / RECORD).read_text().endswith("}\n")
