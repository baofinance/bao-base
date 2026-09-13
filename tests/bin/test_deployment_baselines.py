"""`deployed.json` — the record that replaces the tags.

Every case here is a property the record has to hold for the design to work: an address is one
identity however it is spelled, a baseline can be re-recorded but never replaced, and a reader stops
rather than misreads a schema it does not know.
"""

from __future__ import annotations

import json
import subprocess
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
    commit_reach,
    key,
    read_baselines,
    write_baselines,
)

SETTINGS = {
    "evmVersion": "cancun",
    "optimizer": {"enabled": True, "runs": 700},
    "viaIR": True,
    "metadata": {"bytecodeHash": "ipfs"},
    "remappings": ["@bao/=lib/bao-base/src/"],
    "libraries": {},
}

PAUSER = Baseline(
    chainId=1,
    chain="mainnet",
    address="0xd8785d5C51aaDEb3AD1D015Cd67C8A34dBf58f61",
    contractType="BaoPauser_v1",
    source="src/BaoPauser_v1.sol",
    stateFiles=["deployments/mainnet/state.json"],
    commit="a" * 40,
    commitTimestamp="2026-03-19T20:50:21Z",
    deployBlock=24706244,
    deployTimestamp="2026-03-21T13:41:23Z",
    creationBytecodeKeccak256="b" * 64,
    compiler="0.8.30+commit.73712a01",
    settings=SETTINGS,
    sources={"src/BaoPauser_v1.sol": "d" * 40, "lib/bao-base/src/ERC165.sol": "e" * 40},
    submodules={"lib/bao-base": "f" * 40},
)


# ── where a commit lives, which decides whether a baseline may name it ─────────────────────────────
#
# A baseline is only as good as the commit it names. The three failures are different and need
# different answers: a commit on no branch will NEVER be pushed by any normal operation and can be
# destroyed by `git stash drop`; a commit on a local branch is the ordinary state of work in progress
# and will be pushed in the usual course; a commit git no longer holds at all is a baseline already
# broken. Measured in harbor-price-aggregators: a recorded baseline names a stash entry, and HEAD
# itself is on two local branches and no remote - so "must be on origin" alone would refuse ordinary
# local work, and "will be caught by CI" alone would let a droppable commit be recorded.


def git(where: Path, *arguments: str) -> None:
    subprocess.run(["git", *arguments], cwd=where, capture_output=True, text=True, check=True)


@pytest.fixture
def repo(tmp_path):
    """A repository with a remote, one pushed commit, and a `main` that tracks it."""
    remote = tmp_path / "remote.git"
    subprocess.run(["git", "init", "-q", "--bare", str(remote)], check=True, capture_output=True)
    work = tmp_path / "work"
    subprocess.run(["git", "init", "-q", "-b", "main", str(work)], check=True, capture_output=True)
    git(work, "config", "user.email", "t@t")
    git(work, "config", "user.name", "test")
    git(work, "remote", "add", "origin", str(remote))
    (work / "one.txt").write_text("one\n")
    git(work, "add", "-A")
    git(work, "commit", "-qm", "pushed")
    git(work, "push", "-q", "origin", "main")
    return work


def head(repo: Path) -> str:
    return subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True).stdout.strip()


def test_a_commit_a_remote_has_may_be_recorded_anywhere(repo):
    assert commit_reach(repo, head(repo)) == "remote"


def test_a_commit_on_a_local_branch_only_is_the_ordinary_state_of_work(repo):
    # A deploy is committed and the record written before anything is pushed, so refusing this would
    # make the tool unusable in its own normal flow. It is recordable locally and rejected by CI, which
    # is a real safety net here because a branch commit survives until it is pushed or deliberately
    # discarded.
    (repo / "two.txt").write_text("two\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "not pushed")

    assert commit_reach(repo, head(repo)) == "local"


def test_a_commit_on_no_branch_may_never_be_recorded(repo):
    # A stash. `git push` pushes branches, so nothing will ever carry this to a remote, and
    # `git stash drop` destroys it - which is why "CI will catch it" is not a safety net: the object
    # can be gone before CI ever sees it.
    (repo / "dirty.txt").write_text("dirty\n")
    git(repo, "add", "-A")
    git(repo, "stash", "-q")
    stashed = subprocess.run(["git", "rev-parse", "stash@{0}"], cwd=repo, capture_output=True, text=True).stdout.strip()

    assert commit_reach(repo, stashed) == "none"


def test_a_commit_this_repository_no_longer_holds_is_reported_as_absent(repo):
    # The case the whole reachability concern is about: a force-push, an orphaning rebase, or garbage
    # collection, and a recorded baseline points at nothing. It is a different answer from "on no
    # branch" because the remedy differs - fetch it, or the baseline is dead.
    assert commit_reach(repo, "0" * 40) == "absent"


def test_a_repository_that_has_not_started_records_nothing(tmp_path):
    # The ordinary state of every repo before this lands, and not an error.
    assert read_baselines(tmp_path) == {}


def test_a_baseline_survives_the_round_trip(tmp_path):
    write_baselines(tmp_path, add({}, PAUSER))

    assert read_baselines(tmp_path) == {key(PAUSER.chainId, PAUSER.address): PAUSER}


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
    other = Baseline(**{**PAUSER.__dict__, "commit": "c" * 40, "contractType": "HarborPauser_v1"})

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
        "stateFiles",
        "commit",
        "commitTimestamp",
        "deployBlock",
        "deployTimestamp",
        "creationBytecodeKeccak256",
        "compiler",
        "settings",
        "sources",
        "submodules",
    }
    assert not any("_" in name for name in fields), fields
    assert "Hash" not in "".join(fields), "the algorithm is named, not left for the value to declare"


def test_everyTimestamp_is_utc(tmp_path):
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
    assert PAUSER.commitTimestamp < PAUSER.deployTimestamp


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


# ── the compiler input beside the commit ───────────────────────────────────────────────────────────
#
# A commit alone leaves the build to whatever the machine running it has: the compiler comes from the
# pragma and whatever versions are installed, and the settings from one forge release's reading of that
# commit's foundry.toml. Measured: one deployed contract's explorer record says `prague` where a
# rebuild here chose `osaka`, and both build the deployed code. So a baseline states what proved it -
# the compiler, solc's settings, the blob id of every source the build read, and the submodule commit
# holding each blob that lives in one, since a blob id resolves only where the object is.


def test_the_compiler_input_is_part_of_the_record(tmp_path):
    write_baselines(tmp_path, add({}, PAUSER))

    fields = next(iter(json.loads((tmp_path / RECORD).read_text())["baselines"].values()))

    assert fields["compiler"] == "0.8.30+commit.73712a01"
    assert fields["settings"]["evmVersion"] == "cancun", "the EVM version no pragma pins"
    assert fields["settings"]["remappings"], "remappings decide which file each import resolves to"
    assert fields["sources"]["lib/bao-base/src/ERC165.sol"] == "e" * 40, "a dependency, by blob id"
    assert fields["submodules"]["lib/bao-base"] == "f" * 40, "the repository that holds that blob"


def test_a_record_that_cannot_say_what_built_it_is_refused(tmp_path):
    # The gap this record exists to close, so it is not silently readable as "built by anything".
    without = {spelling: value for spelling, value in _written(PAUSER).items() if spelling != "settings"}
    (tmp_path / RECORD).write_text(
        json.dumps({"schemaVersion": SCHEMA_VERSION, "baselines": {key(PAUSER.chainId, PAUSER.address): without}})
    )

    with pytest.raises(KeyError) as refused:
        read_baselines(tmp_path)

    assert "settings" in str(refused.value), "the refusal names the field that is missing"


def test_a_different_compiler_input_for_one_address_is_refused(tmp_path):
    # Same rule as the commit: the artefact never changed, so two claims about what built it cannot
    # both be true, and which is true is a question about the chain.
    other = Baseline(**{**PAUSER.__dict__, "settings": {**SETTINGS, "evmVersion": "prague"}})

    with pytest.raises(Conflict):
        add(add({}, PAUSER), other)


def _written(baseline: Baseline) -> dict:
    """The record's own spelling of one baseline, taken from the file it writes."""
    import tempfile

    with tempfile.TemporaryDirectory() as directory:
        write_baselines(Path(directory), {key(baseline.chainId, baseline.address): baseline})
        return next(iter(json.loads((Path(directory) / RECORD).read_text())["baselines"].values()))


# ── the tag a baseline wants, derived rather than agreed ───────────────────────────────────────────
#
# A state file lives at `deployments/<chain>/<file>.json`, so the tag IS that path with the directory
# and the suffix removed. Derivation rather than convention: "does this tag match the record" becomes
# string equality, not a naming agreement someone has to keep.


def test_the_tag_a_baseline_wants_is_named_for_its_state_file():
    from deployment_baselines import deploy_tags

    assert deploy_tags(PAUSER) == [f"deploy/mainnet/state@{PAUSER.commit[:10]}"]


def test_a_baseline_two_state_files_claim_wants_a_tag_for_each():
    # 44 of the aggregators' addresses are in two manifests, and one commit serves several files - so
    # the pair, not the commit alone, is what a preservation tag names.
    from deployment_baselines import deploy_tags

    both = Baseline(
        **{
            **PAUSER.__dict__,
            "stateFiles": ["deployments/mainnet/v3-aggregators.json", "deployments/mainnet/v3-oracles.json"],
        }
    )

    assert deploy_tags(both) == [
        f"deploy/mainnet/v3-aggregators@{PAUSER.commit[:10]}",
        f"deploy/mainnet/v3-oracles@{PAUSER.commit[:10]}",
    ]
