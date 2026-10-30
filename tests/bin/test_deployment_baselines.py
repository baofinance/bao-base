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
    libraries={},
    constructorArguments="",
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


def test_a_commit_a_ref_reaches_may_be_recorded(repo):
    assert commit_reach(repo, head(repo)) == "reachable"


def test_a_commit_on_a_local_branch_only_is_the_ordinary_state_of_work(repo):
    # A deploy is committed and the record written before anything is pushed, so refusing this would
    # make the tool unusable in its own normal flow. Nothing here asks whether it was pushed: CI's
    # checkout holds only what was, so the same local question answers that there, with no network.
    (repo / "two.txt").write_text("two\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "not pushed")

    assert commit_reach(repo, head(repo)) == "reachable"


def test_a_commit_only_a_remote_branch_reaches_may_be_recorded(repo, tmp_path):
    # A clone holds a local branch only for what it checked out, and every other pushed branch as a
    # remote branch. The remote has the commit, so this is not the dangling commit "none" means.
    git(repo, "switch", "-qc", "theirs")
    git(repo, "commit", "-q", "--allow-empty", "-m", "on a branch someone else pushed")
    git(repo, "push", "-q", "origin", "theirs")
    pushed = head(repo)
    clone = tmp_path / "clone"
    git(tmp_path, "clone", "-q", "-b", "main", str(tmp_path / "remote.git"), str(clone))

    assert commit_reach(clone, pushed) == "reachable"


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
        "libraries",
        "constructorArguments",
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


# ── the tags a record derives, named by their deploys ───────────────────────────────────────────────
#
# One tag per state file and commit. A state file lives at `deployments/<chain>/<file>.json`, so the name
# starts with that path, directory and suffix removed, and ends with the deploy's first block time, its
# colons - which git forbids in a ref name - as hyphens. Derivation rather than convention: "does this tag
# match the record" is string equality, and plain `git tag -l` lists a state file's deploys in time order.


def test_a_tag_is_named_by_its_deploys_first_block_time():
    # Two contracts from one commit into one state file are one tag, named by the earlier block.
    from dataclasses import replace

    from deployment_baselines import derived_tags

    later = replace(
        PAUSER, address="0x" + "cc" * 20, deployBlock=PAUSER.deployBlock + 5, deployTimestamp="2026-03-21T13:42:00Z"
    )

    assert list(derived_tags([later, PAUSER])) == [f"deploy/mainnet/state@{PAUSER.deployTimestamp.replace(':', '-')}"]


def test_tag_names_sort_in_deploy_order():
    # Three deploys into one state file, from three commits: listed by name, they come in deploy order.
    from dataclasses import replace

    from deployment_baselines import derived_tags, tag_date

    deploys = [
        replace(deployed_at(block, when), commit=letter * 40)
        for block, when, letter in (
            (300, "2026-03-23T09:00:00Z", "c"),
            (100, "2026-01-04T10:51:23Z", "a"),
            (200, "2026-02-11T17:11:59Z", "b"),
        )
    ]

    by_name = sorted(derived_tags(deploys).items())

    assert [tag_date(built) for _, built in by_name] == [
        "2026-01-04T10:51:23Z",
        "2026-02-11T17:11:59Z",
        "2026-03-23T09:00:00Z",
    ]


def test_two_commits_deployed_in_one_second_into_one_state_file_are_told_apart():
    # Their deploys would name one tag; each name gains its commit's 10 characters instead.
    from dataclasses import replace

    from deployment_baselines import derived_tags

    one = replace(PAUSER, commit="a" * 40)
    other = replace(PAUSER, address="0x" + "cc" * 20, commit="b" * 40)

    when = PAUSER.deployTimestamp.replace(":", "-")
    assert list(derived_tags([one, other])) == [
        f"deploy/mainnet/state@{when}@{'a' * 10}",
        f"deploy/mainnet/state@{when}@{'b' * 10}",
    ]


def test_a_baseline_two_state_files_claim_is_in_a_tag_for_each():
    # 44 of the aggregators' addresses are in two manifests, and one commit serves several files - so the
    # state file, not the commit alone, is what a tag is for.
    from deployment_baselines import derived_tags

    both = Baseline(
        **{
            **PAUSER.__dict__,
            "stateFiles": ["deployments/mainnet/v3-aggregators.json", "deployments/mainnet/v3-oracles.json"],
        }
    )

    when = PAUSER.deployTimestamp.replace(":", "-")
    assert list(derived_tags([both])) == [f"deploy/mainnet/v3-aggregators@{when}", f"deploy/mainnet/v3-oracles@{when}"]


# ── fetching tags: origin's deployment tags replace a clone's own ───────────────────────────────────
#
# One fetch serves `verify-audit --pull` and `yarn dep`. A deployment tag corrected in one clone has to
# reach every other, and a plain `git fetch --tags` refuses to replace a tag a clone already holds - it
# exits 1 with "would clobber existing tag". Origin's version wins only for the deployment tags, whose
# names the record derives. Any other tag a clone holds is its owner's, so a clash there is still refused.


def clone_of(remote: Path, into: Path) -> Path:
    subprocess.run(["git", "clone", "-q", str(remote), str(into)], check=True, capture_output=True)
    git(into, "config", "user.email", "t@t")
    git(into, "config", "user.name", "test")
    return into


def fetch_tags(where: Path) -> subprocess.CompletedProcess:
    from deployment_baselines import FETCH_TAGS

    return subprocess.run(["git", *FETCH_TAGS], cwd=where, capture_output=True, text=True)


def named(where: Path, tag: str) -> tuple[str, str]:
    """The object `tag` names here and that object's kind: a tag object when annotated, a commit when not."""
    found = subprocess.run(
        ["git", "for-each-ref", "--format=%(objectname) %(objecttype)", f"refs/tags/{tag}"],
        cwd=where,
        capture_output=True,
        text=True,
    ).stdout.split()
    return (found[0], found[1]) if found else ("", "")


def test_the_tag_fetch_takes_origins_version_of_a_deployment_tag(repo, tmp_path):
    # This clone holds the lightweight tag an older tool made; another clone corrected it on origin.
    other = clone_of(tmp_path / "remote.git", tmp_path / "other")
    tag = "deploy/mainnet/state@2026-01-03T00-00-00Z"
    git(repo, "tag", tag)
    git(other, "tag", "-a", tag, "-m", "corrected", head(repo))
    git(other, "push", "-q", "origin", f"refs/tags/{tag}")

    fetched = fetch_tags(repo)

    assert fetched.returncode == 0, fetched.stderr
    assert named(repo, tag) == named(other, tag), "origin's annotated tag, the very object"
    assert named(repo, tag)[1] == "tag"


def test_the_tag_fetch_still_refuses_a_clash_outside_deployment_tags(repo, tmp_path):
    # A tag outside `deploy/` is somebody's own, so which version is right is not this fetch's to decide.
    other = clone_of(tmp_path / "remote.git", tmp_path / "other")
    git(repo, "tag", "private-note")
    git(other, "tag", "-a", "private-note", "-m", "theirs")
    git(other, "push", "-q", "origin", "refs/tags/private-note")
    mine = named(repo, "private-note")

    fetched = fetch_tags(repo)

    assert fetched.returncode != 0, "the clash is reported, not settled"
    assert named(repo, "private-note") == mine, "and this clone's own tag is kept"


def test_the_tag_fetch_brings_down_a_new_tag(repo, tmp_path):
    # Both kinds arrive: a deployment tag, and any other tag origin has.
    other = clone_of(tmp_path / "remote.git", tmp_path / "other")
    deployment = "deploy/mainnet/state@2026-01-03T00-00-00Z"
    git(other, "tag", "-a", deployment, "-m", "made elsewhere", head(repo))
    git(other, "tag", "-a", "v1.0.0", "-m", "a release", head(repo))
    git(other, "push", "-q", "origin", f"refs/tags/{deployment}", "refs/tags/v1.0.0")

    fetched = fetch_tags(repo)

    assert fetched.returncode == 0, fetched.stderr
    assert named(repo, deployment) == named(other, deployment)
    assert named(repo, "v1.0.0") == named(other, "v1.0.0")


# ── what a deployment tag says, and the date it carries ─────────────────────────────────────────────
#
# Under the person's label, the tool's lines - git trailers - say which blocks the deploy spans and where
# the commit falls against it, which is the very comparison the search's two passes make. All of it is read
# from the record. The tag is dated as its deploy's first block, so it says when the deploy ran.


def deployed_at(block: int, when: str, committed: str = PAUSER.commitTimestamp) -> Baseline:
    """PAUSER, as if deployed in `block` at `when` from a commit made at `committed`."""
    from dataclasses import replace

    return replace(PAUSER, deployBlock=block, deployTimestamp=when, commitTimestamp=committed)


def test_the_message_is_the_label_then_the_tools_trailers():
    # The label leads, so it is what `git tag -n` and GitHub show; the tool's three trailers end the message.
    from deployment_baselines import tag_message

    message = tag_message([PAUSER], "the pauser")

    assert message == (
        "the pauser\n"
        "\n"
        f"Deployed-in: block {PAUSER.deployBlock}\n"
        "Committed: before the deploy\n"
        "Recorded-in: deployed.json"
    ), message


def test_a_label_of_several_lines_leads_the_message_whole():
    # The title, the blank line and the body are the person's, as written; the trailers follow a blank line.
    from deployment_baselines import tag_message

    message = tag_message([PAUSER], "the pauser\n\nfirst line of the body\nsecond line of the body")

    assert message == (
        "the pauser\n"
        "\n"
        "first line of the body\n"
        "second line of the body\n"
        "\n"
        f"Deployed-in: block {PAUSER.deployBlock}\n"
        "Committed: before the deploy\n"
        "Recorded-in: deployed.json"
    ), message


def test_blank_lines_around_a_label_are_not_in_the_message():
    # A TOML multi-line string closed on its own line ends with a line break, which is no part of the words.
    from deployment_baselines import tag_message

    message = tag_message([PAUSER], "\nthe pauser\n\nits body\n")

    assert message.startswith("the pauser\n\nits body\n\nDeployed-in: "), message


def test_the_message_names_the_first_and_last_block_of_several():
    # Given out of order: the first and last are the lowest and highest block.
    from deployment_baselines import tag_message

    message = tag_message(
        [
            deployed_at(300, "2026-03-21T15:00:00Z"),
            deployed_at(100, "2026-03-21T13:00:00Z"),
            deployed_at(200, "2026-03-21T14:00:00Z"),
        ],
        "three",
    )

    assert "\nDeployed-in: blocks 100 to 300\n" in message, message


def test_the_message_says_the_commit_came_before_the_deploy():
    # The ordinary case, and the search's first pass: the commit is the tree that was checked out.
    from deployment_baselines import tag_message

    message = tag_message([PAUSER], "the pauser")

    assert "\nCommitted: before the deploy\n" in message, message


def test_the_message_says_the_commit_came_after_the_deploy():
    # The search's second pass: the deploy ran from changes that were committed only afterwards.
    from deployment_baselines import tag_message

    message = tag_message([deployed_at(100, "2026-03-21T13:00:00Z", "2026-03-22T00:00:00Z")], "late")

    assert "\nCommitted: after the deploy, which ran from changes not yet committed\n" in message, message


def test_the_message_says_the_commit_came_during_the_deploy():
    # Later than the first contract and no later than the last: neither before nor after the whole deploy.
    from deployment_baselines import tag_message

    message = tag_message(
        [
            deployed_at(100, "2026-03-21T13:00:00Z", "2026-03-21T14:00:00Z"),
            deployed_at(200, "2026-03-21T15:00:00Z", "2026-03-21T14:00:00Z"),
        ],
        "midway",
    )

    assert "\nCommitted: during the deploy\n" in message, message


def test_every_line_the_tool_adds_fits_72_characters():
    # The limit the person's lines are held to holds for the tool's own, at their longest: nine-digit blocks,
    # and a commit made after the deploy.
    from deployment_baselines import tag_message

    message = tag_message(
        [
            deployed_at(100_000_000, "2026-03-21T13:00:00Z", "2026-03-22T00:00:00Z"),
            deployed_at(999_999_999, "2026-03-21T15:00:00Z", "2026-03-22T00:00:00Z"),
        ],
        "late",
    )

    added = message.split("\n")[2:]
    assert len(added) == 3 and all(len(line) <= 72 for line in added), added


def test_the_tag_is_dated_by_its_first_contracts_block():
    from deployment_baselines import tag_date

    dated = tag_date([deployed_at(200, "2026-03-21T15:00:00Z"), deployed_at(100, "2026-03-21T13:00:00Z")])

    assert dated == "2026-03-21T13:00:00Z"
