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

from dataclasses import replace  # noqa: E402

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


def described_by(manifest: str, name: str):
    """One manifest's description of the same deployed contract, differing only in the name it gives."""
    from deployment_records import Entry

    return Entry(
        address="0xAA",
        name=name,
        recorded_path=f"src/{name}.sol",
        chain_id=1,
        recorded_chain_id=1,
        chain="mainnet",
        deployed_at="2026-03-21T13:41:23Z",
        manifest=manifest,
        section="implementations",
    )


def test_a_contract_two_manifests_describe_remembers_both_of_them(tmp_path):
    # A disagreement names both files, but the merged entry kept only the first manifest it saw - so a
    # report built from the entry sends the reader to one file, and for a CONFLICT that is as likely to
    # be the innocent one as the guilty one. Measured: the MegaETH aggregators' row named
    # v3-aggregators.json, where the disagreement was with v4-oracles.json.
    from deployment_baselines import _by_address

    merged, conflicts = _by_address(
        [described_by("deployments/mainnet/one.json", "Foo"), described_by("deployments/mainnet/two.json", "Bar")]
    )

    assert len(merged) == 1, "one address is one contract, however many manifests describe it"
    assert merged[0].manifests == ("deployments/mainnet/one.json", "deployments/mainnet/two.json")
    assert conflicts, "and the disagreement is still reported"


def test_a_third_manifest_disagreeing_is_reported_rather_than_quietly_winning(tmp_path):
    # The merge compares each new row against what is HELD, and a field the first two contested is held
    # as unset - so `ours or theirs` takes the third's value, and the reader is told about one
    # disagreement while a third description silently becomes the answer. A contested field stays
    # contested, and every manifest that differs is named.
    from deployment_baselines import _by_address

    merged, conflicts = _by_address(
        [
            described_by("deployments/mainnet/one.json", "Foo"),
            described_by("deployments/mainnet/two.json", "Bar"),
            described_by("deployments/mainnet/three.json", "Baz"),
        ]
    )

    assert len(merged) == 1
    assert merged[0].name is None, "no description wins a three-way disagreement"
    assert merged[0].manifests == (
        "deployments/mainnet/one.json",
        "deployments/mainnet/two.json",
        "deployments/mainnet/three.json",
    )
    assert any("three.json" in problem.reason for problem in conflicts), "the third manifest is named too"
    assert all(value in problem.reason for problem in conflicts for value in ("Foo", "Bar", "Baz")), (
        "and its disagreement is reported, not absorbed into a field two others already contested"
    )


def baseline_for(address: str = "0xAA", commit: str = "a" * 40) -> Baseline:
    return Baseline(
        chainId=1,
        chain="mainnet",
        address=address,
        contractType="Foo",
        source="src/Foo.sol",
        stateFiles=["deployments/mainnet/state.json"],
        commit=commit,
        commitTimestamp="2026-03-19T20:50:21Z",
        deployBlock=24706244,
        deployTimestamp="2026-03-21T13:41:23Z",
        creationBytecodeKeccak256="b" * 64,
        compiler="0.8.30+commit.73712a01",
        settings={"evmVersion": "cancun", "optimizer": {"enabled": True, "runs": 700}},
        sources={"src/Foo.sol": "d" * 40},
        submodules={},
        libraries={},
        constructorArguments="",
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


def two_manifests_disagreeing(repo: Path) -> None:
    """Two manifests describing one address with DIFFERENT paths, both real in this repo's history.

    The situation behind eleven of the aggregators' addresses: the file moved, and the older manifest
    recorded where it was while the newer recorded where it went."""
    (repo / "src" / "moved").mkdir()
    (repo / "src" / "moved" / "Foo.sol").write_text("// foo\n")
    (repo / "src" / "Foo.sol").unlink()
    manifests = repo / "deployments" / "mainnet"
    for name, path in (("a-first.json", "src/Foo.sol"), ("state.json", "src/moved/Foo.sol")):
        (manifests / name).write_text(
            json.dumps(
                {
                    "network": "mainnet",
                    "chainId": 1,
                    "implementations": {"0xAA": {"contractSource": path, "contractType": "Foo"}},
                }
            )
        )
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "the file moved; two manifests disagree")


def test_two_manifests_disagreeing_about_one_contract_is_reported_and_never_guessed(repo):
    # 11 of the aggregators' addresses are described by two manifests that give DIFFERENT paths - the
    # older one recorded `src/Aggregator_…` before the file moved to `src/mainnet/`. Keeping whichever
    # was read first made manifest filename order decide, silently.
    #
    # The disagreement is reported, and the field is left UNSET rather than picked: nothing downstream
    # should act on an arbitrary choice, and recovery finds the real path at the baseline commit by
    # contract name anyway.
    two_manifests_disagreeing(repo)

    found = review(repo)

    assert len(found.conflicts) == 1, found.conflicts
    assert "src/Foo.sol" in found.conflicts[0].reason and "src/moved/Foo.sol" in found.conflicts[0].reason
    assert len(found.unrecovered) == 1
    assert found.unrecovered[0].recorded_path is None, "unset, so nothing acts on an arbitrary pick"


def test_a_disagreement_is_reported_even_when_the_contract_is_already_recorded(repo):
    # The merge ran over the UNRECORDED entries only, so a disagreement about an address that already
    # had a baseline was never computed at all: a complete record drove the count to zero, and zero read
    # as health. What the manifests say about each other cannot depend on how full the record is.
    two_manifests_disagreeing(repo)
    write_baselines(repo, add({}, baseline_for()))

    found = review(repo)

    assert [b.contractType for b in found.recorded] == ["Foo"], "it is recorded"
    assert found.unrecovered == [], "so it is not a backlog item"
    assert len(found.conflicts) == 1, "and the manifests still disagree about it"
    assert "src/moved/Foo.sol" in found.conflicts[0].reason


def test_a_conflict_row_names_every_manifest_and_the_field_in_dispute(repo):
    # One row per contested ADDRESS, built from the merged entry so it carries every manifest describing
    # it - where a row per field named two files and left a third description of the same address unnamed.
    from deployment_baselines import _by_address

    merged, conflicts = _by_address(
        [
            described_by("deployments/mainnet/one.json", "Foo"),
            described_by("deployments/mainnet/two.json", "Bar"),
            described_by("deployments/mainnet/three.json", "Baz"),
        ]
    )

    assert len(conflicts) == 1, "one contested address is one row, however many fields and files differ"
    assert conflicts[0].entry.manifests == merged[0].manifests, "the row is the merged entry, so it knows them all"
    reason = conflicts[0].reason
    for manifest in ("one.json", "two.json", "three.json"):
        assert manifest in reason, reason
    for value in ("Foo", "Bar", "Baz"):
        assert value in reason, reason
    assert "name" in reason and "recorded_path" in reason, "and which fields are in dispute"


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


def test_a_baseline_on_a_commit_this_checkout_holds_is_not_reported(repo, tmp_path):
    push_to_a_new_remote(repo, tmp_path)
    write_baselines(repo, add({}, baseline_for(commit=head_of(repo))))

    assert review(repo).unreachable == []


def test_a_baseline_on_an_unpushed_commit_is_not_reported_here(repo, tmp_path):
    # A review asks only what THIS checkout can resolve, and a local branch reaches it - so an unpushed
    # commit is silent here and reported in CI, whose checkout holds only what was pushed. That is the
    # same bargain a formatter makes: it passes locally once you have fixed the file, and the build is
    # what notices you never pushed it. Nothing asks a remote to decide it.
    push_to_a_new_remote(repo, tmp_path)
    (repo / "src" / "Later.sol").write_text("// later\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "not pushed")
    write_baselines(repo, add({}, baseline_for(commit=head_of(repo))))

    found = review(repo)

    assert found.unreachable == [], "a local branch reaches it, so this checkout can resolve it"


def test_a_baseline_on_a_commit_this_repository_has_lost_is_reported_as_absent(repo, tmp_path):
    # The reachability failure itself: a force-push, an orphaning rebase, or garbage collection, and
    # the record points at nothing. Distinguished from "not pushed" because the remedy differs.
    push_to_a_new_remote(repo, tmp_path)
    write_baselines(repo, add({}, baseline_for(commit="0" * 40)))

    found = review(repo)

    assert [(b.contractType, reach) for b, reach in found.unreachable] == [("Foo", "absent")]


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
    head = head_of(repo)
    write_baselines(
        repo, add({}, replace(baseline_for(commit=head), sources=real_sources(repo, head, ["src/Foo.sol"])))
    )

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
    head = head_of(repo)
    write_baselines(
        repo, add({}, replace(baseline_for(commit=head), sources=real_sources(repo, head, ["src/Foo.sol"])))
    )

    found = review(repo)

    assert [declares for _, declares in found.misnamed] == [None]


def a_dependency(tmp_path: Path, contract: str) -> Path:
    """A repository whose `Dep.sol` declares `contract`, to be mounted as a submodule."""
    origin = tmp_path / "dep-origin"
    origin.mkdir()
    for arguments in (("init", "-q"), ("config", "user.email", "t@t"), ("config", "user.name", "test")):
        git(origin, *arguments)
    (origin / "Dep.sol").write_text(f"contract {contract} {{}}\n")
    git(origin, "add", "-A")
    git(origin, "commit", "-qm", "dependency")
    return origin


def mount(repo: Path, origin: Path, path: str) -> None:
    """Commit `origin` mounted as a submodule at `path`.

    Commits only what `submodule add` staged: the repositories a test creates sit inside `repo`'s own
    directory, and staging everything would commit them as gitlinks no `.gitmodules` declares."""
    subprocess.run(
        ["git", "-c", "protocol.file.allow=always", "submodule", "add", "-q", str(origin), path],
        cwd=repo,
        check=True,
        capture_output=True,
    )
    git(repo, "commit", "-qm", f"mount {path}")


def with_a_submodule(repo: Path, tmp_path: Path, contract: str) -> str:
    """Add `lib/dep`, whose `Dep.sol` declares `contract`, and commit it. Returns the gitlink recorded."""
    mount(repo, a_dependency(tmp_path, contract), "lib/dep")
    return head_of(repo / "lib" / "dep")


def recorded_from_the_submodule(repo: Path, contract_type: str) -> Baseline:
    """A record of `lib/dep/Dep.sol` built at HEAD, whose inputs all resolve."""
    head = head_of(repo)
    return replace(
        baseline_for(commit=head),
        contractType=contract_type,
        source="lib/dep/Dep.sol",
        sources=real_sources(repo, head, ["lib/dep/Dep.sol"]),
        submodules={"lib/dep": head_of(repo / "lib" / "dep")},
    )


def test_a_record_agreeing_with_its_source_in_a_submodule_is_not_reported(repo, tmp_path):
    # A contract deployed from this repository and defined in a dependency - harbor's
    # `MintableBurnableERC20_v1`, from bao-base. The superproject's tree holds only a gitlink there, so
    # the source is read inside the submodule at the commit the record holds for it.
    with_a_submodule(repo, tmp_path, "Dep")
    push_to_a_new_remote(repo, tmp_path)
    write_baselines(repo, add({}, recorded_from_the_submodule(repo, "Dep")))

    assert review(repo).misnamed == []


def test_a_record_disagreeing_with_its_source_in_a_submodule_is_reported_with_what_it_declares(repo, tmp_path):
    # A submodule source is read, not waved through: a record renamed after its deploy is caught the same
    # wherever the file lives, and the name the source declares is reported beside the record's.
    with_a_submodule(repo, tmp_path, "Dep")
    push_to_a_new_remote(repo, tmp_path)
    write_baselines(repo, add({}, recorded_from_the_submodule(repo, "Renamed")))

    assert [(b.contractType, declares) for b, declares in review(repo).misnamed] == [("Renamed", "Dep")]


def test_a_record_whose_source_is_in_a_submodule_this_clone_does_not_have_is_not_reported_as_misnamed(
    repo, tmp_path
):
    # Nothing can be said about a file that cannot be read, and the source is already reported as
    # unchecked. Saying it "declares no single contract" asserts something nobody looked at.
    push_to_a_new_remote(repo, tmp_path)
    baseline = replace(
        baseline_for(commit=head_of(repo)),
        source="lib/ghost/src/Foo.sol",
        sources={"lib/ghost/src/Foo.sol": "e" * 40},
        submodules={"lib/ghost": "f" * 40},
    )
    write_baselines(repo, add({}, baseline))

    found = review(repo)

    assert found.misnamed == []
    assert [b.contractType for b, _ in found.inputs_unchecked] == ["Foo"], "it is reported, as unchecked"


def test_a_record_whose_source_is_not_the_bytes_it_recorded_is_reported_once_as_missing(repo, tmp_path):
    # The name check reads the source at the commit; when those are not the recorded bytes it would be
    # reading some other file than the one deployed. Reported once, as the thing it is.
    push_to_a_new_remote(repo, tmp_path)
    declare(repo, "src/Foo.sol", "Renamed")
    write_baselines(repo, add({}, replace(baseline_for(commit=head_of(repo)), sources={"src/Foo.sol": "d" * 40})))

    found = review(repo)

    assert [b.contractType for b, _ in found.inputs_missing] == ["Foo"]
    assert found.misnamed == [], "a disagreement with bytes nobody deployed is not a finding about the record"


def test_what_a_source_declares_cannot_be_read_from_a_path_its_commit_does_not_have(repo):
    # An unreadable file declares nothing that can be known. Answering None - "declares no single
    # contract" - reported a question never asked as an answer; the path and commit are the facts.
    from deployment_recovery import declared_in

    with pytest.raises(FileNotFoundError, match=r"src/Absent\.sol is not in the tree at [0-9a-f]{10}"):
        declared_in(repo, head_of(repo), "src/Absent.sol", {})


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


# ── the record's inputs, checked on every build ────────────────────────────────────────────────────
#
# `creationBytecodeKeccak256` is written once and read by nothing: the record states "these inputs
# produce this bytecode" and never asks again. Rebuilding to check it costs minutes, so the per-build
# check is on the INPUTS - every recorded source blob and submodule gitlink still resolving at the
# recorded commit. With the compiler and settings pinned in the record and solc deterministic,
# identical inputs mean identical output, so this is the cheap half of the same guarantee. It catches
# what actually threatens a record: history rewritten underneath it.


def real_sources(repo: Path, commit: str, paths: list[str]) -> dict[str, str]:
    from deployment_recovery import checkouts_by_repository, source_blobs, submodules_at

    return source_blobs(repo, commit, paths, submodules_at(repo, commit, checkouts_by_repository(repo)))


def test_a_record_whose_inputs_all_resolve_is_silent(repo, tmp_path):
    # The ordinary case: the commit is there, the sources are the bytes it holds, and nothing is said.
    push_to_a_new_remote(repo, tmp_path)
    head = head_of(repo)
    write_baselines(
        repo, add({}, replace(baseline_for(commit=head), sources=real_sources(repo, head, ["src/Foo.sol"])))
    )

    found = review(repo)

    assert found.inputs_missing == [], "every recorded blob is what that commit holds"
    assert found.inputs_unchecked == []


def test_a_recorded_source_whose_bytes_changed_at_its_commit_is_reported(repo, tmp_path):
    # The failure this exists for: a force-push, a filtered branch or a rewritten tag leaves the commit
    # resolvable while the bytes under it are not the ones that were built. Existence alone would pass
    # that, so the check compares the blob the path has NOW at that commit against the recorded one.
    push_to_a_new_remote(repo, tmp_path)
    head = head_of(repo)
    write_baselines(repo, add({}, replace(baseline_for(commit=head), sources={"src/Foo.sol": "d" * 40})))

    found = review(repo)

    assert [b.contractType for b, _ in found.inputs_missing] == ["Foo"]
    assert found.inputs_missing[0][1] == ["src/Foo.sol"], "named, so the reader knows which file moved under it"


def test_a_baseline_whose_commit_is_absent_is_not_also_reported_as_missing_inputs(repo, tmp_path):
    # Reported once, as the thing it is. A commit this repository has lost cannot have its sources
    # checked either, and saying "32 sources missing" beside "commit absent" sends the reader after the
    # wrong fix - the same reasoning `misnamed` already follows.
    push_to_a_new_remote(repo, tmp_path)
    write_baselines(repo, add({}, baseline_for(commit="0" * 40)))

    found = review(repo)

    assert [(b.contractType, reach) for b, reach in found.unreachable] == [("Foo", "absent")]
    assert found.inputs_missing == [], "the absent commit is the finding, and it is made once"


def test_inputs_in_a_submodule_this_clone_does_not_have_are_unchecked_not_missing(repo, tmp_path):
    # A partial checkout can say nothing about what is inside a submodule it does not hold. Calling that
    # "missing" would fail every developer's build for a clone CI does not make, so it is reported as
    # what it is: not checked.
    push_to_a_new_remote(repo, tmp_path)
    head = head_of(repo)
    baseline = replace(
        baseline_for(commit=head),
        sources={"lib/ghost/src/Dep.sol": "e" * 40},
        submodules={"lib/ghost": "f" * 40},
        libraries={},
        constructorArguments="",
    )
    write_baselines(repo, add({}, baseline))

    found = review(repo)

    assert found.inputs_missing == [], "nothing can be asserted about a submodule that is not here"
    assert [b.contractType for b, _ in found.inputs_unchecked] == ["Foo"]
    assert "lib/ghost" in " ".join(found.inputs_unchecked[0][1])


def test_a_submodule_gitlink_this_clone_has_lost_is_reported(repo, tmp_path):
    # The submodule IS here, so the question can be asked - and the commit the superproject records for
    # it is not in it. That is a dependency pin that went away, which no rebuild could reproduce.
    with_a_submodule(repo, tmp_path, "Dep")
    push_to_a_new_remote(repo, tmp_path)
    head = head_of(repo)
    write_baselines(
        repo,
        add(
            {},
            replace(
                baseline_for(commit=head),
                sources={"lib/dep/Dep.sol": "e" * 40},
                submodules={"lib/dep": "0" * 40},
                libraries={},
                constructorArguments="",
            ),
        ),
    )

    found = review(repo)

    assert [b.contractType for b, _ in found.inputs_missing] == ["Foo"]
    named = " ".join(found.inputs_missing[0][1])
    assert "lib/dep" in named, "the pin that went away"
    assert "lib/dep/Dep.sol" in named, "and the source that needed it, which went with it"


def test_every_baseline_is_checked_not_only_the_first(repo, tmp_path):
    # A loop over the record, so the second one's broken inputs are found as readily as the first's.
    push_to_a_new_remote(repo, tmp_path)
    head = head_of(repo)
    (repo / "src" / "Bar.sol").write_text("contract Bar {}\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "a second contract")
    later = head_of(repo)
    baselines = add({}, replace(baseline_for(commit=head), sources=real_sources(repo, head, ["src/Foo.sol"])))
    second = replace(
        baseline_for(address="0xBB", commit=later),
        contractType="Bar",
        source="src/Bar.sol",
        sources={"src/Bar.sol": "c" * 40},
    )
    write_baselines(repo, add(baselines, second))

    found = review(repo)

    assert [b.contractType for b, _ in found.inputs_missing] == ["Bar"], "the first being sound does not end the check"


def recorded_before_a_second_mount_was_removed(repo: Path, tmp_path: Path) -> Baseline:
    """A record built while one dependency was mounted twice, the second mount since removed.

    harbor's shape: `lib/bao-base-audit-2025-07` was bao-base itself at the audit tag, mounted beside
    `lib/bao-base`, and was removed from the tree after 153 contracts were built from it."""
    origin = a_dependency(tmp_path, "Dep")
    mount(repo, origin, "lib/dep")
    mount(repo, origin, "lib/dep-audit")
    built = replace(
        baseline_for(commit=head_of(repo)),
        contractType="Dep",
        source="lib/dep-audit/Dep.sol",
        sources=real_sources(repo, head_of(repo), ["lib/dep-audit/Dep.sol"]),
        submodules={"lib/dep-audit": head_of(repo / "lib" / "dep-audit")},
    )
    git(repo, "rm", "-q", "lib/dep-audit")
    git(repo, "commit", "-qm", "unmount lib/dep-audit")
    push_to_a_new_remote(repo, tmp_path)
    return built


def test_inputs_in_a_submodule_since_removed_are_checked_in_another_checkout_of_its_repository(repo, tmp_path):
    # A gitlink names a commit, and any checkout of that repository holding the commit gives the same
    # bytes - where it is mounted does not matter. A removed mount is not a partial clone: no clone,
    # recursive or not, will ever put a checkout there again, so "not checked" would be permanent.
    write_baselines(repo, add({}, recorded_before_a_second_mount_was_removed(repo, tmp_path)))

    found = review(repo)

    assert not (repo / "lib" / "dep-audit").exists(), "the mount the record names is gone"
    assert found.inputs_unchecked == [], "the same repository is checked out at lib/dep and holds the commit"
    assert found.inputs_missing == []
    assert found.misnamed == [], "and the name is read from it too"


def test_changed_bytes_in_a_submodule_since_removed_are_reported(repo, tmp_path):
    # The other checkout is READ, not taken as a pass: a recorded source it does not hold is missing.
    built = recorded_before_a_second_mount_was_removed(repo, tmp_path)
    write_baselines(repo, add({}, replace(built, sources={"lib/dep-audit/Dep.sol": "d" * 40})))

    found = review(repo)

    assert [(b.contractType, paths) for b, paths in found.inputs_missing] == [("Dep", ["lib/dep-audit/Dep.sol"])]
    assert found.inputs_unchecked == []


def test_inputs_in_a_nested_submodule_are_read_from_the_checkout_of_its_parent(repo, tmp_path):
    # The OpenZeppelin contracts live inside contracts-upgradeable, and a gitlink resolves only against
    # the commit its own parent records - so the parent is placed first and the child is looked for
    # from the parent's checkout. The parent here is a mount since removed, so its checkout is another
    # one of the same repository and the child's recorded path names nothing on disk.
    inner = tmp_path / "inner-origin"
    inner.mkdir()
    for arguments in (("init", "-q"), ("config", "user.email", "t@t"), ("config", "user.name", "test")):
        git(inner, *arguments)
    (inner / "Inner.sol").write_text("contract Inner {}\n")
    git(inner, "add", "-A")
    git(inner, "commit", "-qm", "inner")
    origin = a_dependency(tmp_path, "Dep")
    mount(origin, inner, "lib/inner")
    mount(repo, origin, "lib/dep")
    mount(repo, origin, "lib/dep-audit")
    updated = subprocess.run(
        ["git", "-c", "protocol.file.allow=always", "submodule", "update", "-q", "--init", "--recursive"],
        cwd=repo,
        capture_output=True,
        text=True,
    )
    assert updated.returncode == 0, updated.stderr
    head = head_of(repo)
    built = replace(
        baseline_for(commit=head),
        contractType="Inner",
        source="lib/dep-audit/lib/inner/Inner.sol",
        sources=real_sources(repo, head, ["lib/dep-audit/lib/inner/Inner.sol"]),
        submodules={
            "lib/dep-audit": head_of(repo / "lib" / "dep-audit"),
            "lib/dep-audit/lib/inner": head_of(repo / "lib" / "dep-audit" / "lib" / "inner"),
        },
    )
    git(repo, "rm", "-q", "lib/dep-audit")
    git(repo, "commit", "-qm", "unmount lib/dep-audit")
    push_to_a_new_remote(repo, tmp_path)
    write_baselines(repo, add({}, built))

    found = review(repo)

    assert not (repo / "lib" / "dep-audit").exists(), "the parent mount the record names is gone"
    assert found.inputs_unchecked == []
    assert found.inputs_missing == []
    assert found.misnamed == [], "the name is read from the nested checkout too"


def test_a_gitlink_for_a_submodule_holding_no_recorded_source_is_not_checked(repo, tmp_path):
    # The record names 32 gitlinks per baseline and compiles sources from three of them; the rest are
    # pins of dependencies the build never read. Reporting those as unchecked warns on every build about
    # something nobody can act on except by checking out ds-test for no benefit - and the aggregators'
    # own recovery proves they are outside the closure, building successfully while reporting them
    # unplaced. What reproduces the bytecode is the SOURCES plus the pinned compiler and settings, so a
    # submodule that supplied none of them cannot change the answer.
    push_to_a_new_remote(repo, tmp_path)
    head = head_of(repo)
    baseline = replace(
        baseline_for(commit=head),
        sources=real_sources(repo, head, ["src/Foo.sol"]),
        submodules={"lib/ghost": "f" * 40},
        libraries={},
        constructorArguments="",
    )
    write_baselines(repo, add({}, baseline))

    found = review(repo)

    assert found.inputs_unchecked == [], "no recorded source lives in it, so there is nothing to check"
    assert found.inputs_missing == []


# ── a tag reaches a commit, and a branch is not the only ref that does ─────────────────────────────
#
# `commit_reach` asked `git branch --contains`, so a commit only a TAG reaches read as "on no branch, so
# nothing will ever push it" - which is false of a tag: `git push origin <tag>` exists and `git fetch`
# retrieves tags by default. A tag is also the better ref for this job, being the only one that does not
# move and is not deleted in the ordinary course of work, where the branch the record's commits sit on
# can be force-pushed or dropped.


def tag_only_commit(repo: Path, name: str) -> str:
    """A commit reachable by `name` and by no branch: committed, tagged, then the branch moved back."""
    git(repo, "commit", "--allow-empty", "-qm", "reachable only by its tag")
    only = head_of(repo)
    git(repo, "tag", name, only)
    git(repo, "reset", "--hard", "-q", "HEAD~1")
    return only


def test_a_commit_only_a_tag_reaches_is_recordable(repo, tmp_path):
    # The tag holds it, so it is not the dangling commit "none" means - and a baseline may name it.
    from deployment_baselines import commit_reach

    push_to_a_new_remote(repo, tmp_path)
    only = tag_only_commit(repo, "deploy/mainnet/state@local")

    assert commit_reach(repo, only) == "reachable", "a tag reaches it, even though no branch does"


def test_whether_the_remote_has_the_tag_makes_no_difference(repo, tmp_path):
    # A pushed tag and a local-only one are indistinguishable in refs, and this no longer tries to tell
    # them apart: the question is only whether THIS checkout can resolve the commit. In CI the checkout
    # holds what was pushed, so the same local question answers "was it pushed" there for free.
    from deployment_baselines import commit_reach

    push_to_a_new_remote(repo, tmp_path)
    only = tag_only_commit(repo, "deploy/mainnet/state@pushed")
    git(repo, "push", "-q", "origin", "deploy/mainnet/state@pushed")

    assert commit_reach(repo, only) == "reachable", "the tag reaches it; whose tag it is does not enter into it"


def test_a_dangling_commit_is_still_refused(repo, tmp_path):
    # The case the check exists for, unchanged: no ref of any kind reaches it, so nothing will ever carry
    # it to a remote and `git gc` may take it.
    from deployment_baselines import commit_reach

    push_to_a_new_remote(repo, tmp_path)
    git(repo, "commit", "--allow-empty", "-qm", "about to be orphaned")
    dangling = head_of(repo)
    git(repo, "reset", "--hard", "-q", "HEAD~1")

    assert commit_reach(repo, dangling) == "none", "no branch and no tag reaches it"


def test_a_clone_with_no_reachable_remote_is_still_answered(tmp_path):
    # The check never needs the network, so having no remote at all changes nothing. This used to cost
    # an `ls-remote` on every review, which made "what happens when it fails" a live question; now the
    # only remote call left runs when something is ALREADY failing, to say whether origin holds what is
    # missing.
    from deployment_baselines import commit_reach, remote_tags

    git(tmp_path, "init", "-q", "-b", "main")
    git(tmp_path, "config", "user.email", "t@t")
    git(tmp_path, "config", "user.name", "test")
    git(tmp_path, "commit", "-q", "--allow-empty", "-m", "one")
    only = tag_only_commit(tmp_path, "deploy/mainnet/state@unreachable")

    assert commit_reach(tmp_path, only) == "reachable", "a tag here reaches it, with nothing to ask"
    assert remote_tags(tmp_path) == {}, "and the diagnostic degrades to saying nothing, not to failing"


# ── naming the refs, and the tags that are missing ─────────────────────────────────────────────────
#
# "push that branch" without saying WHICH is a remedy the reader has to derive, and `commit_reach`
# already has the names in hand and throws them away. And a recorded commit no tag NAMES is one whose
# preservation rests on a branch, which moves and is deleted in the ordinary course of work.


def test_a_local_commit_is_reported_with_the_branch_holding_it(repo, tmp_path):
    from deployment_baselines import reached_by

    push_to_a_new_remote(repo, tmp_path)
    git(repo, "commit", "-q", "--allow-empty", "-m", "not pushed")

    assert reached_by(repo, head_of(repo)) == ["main"]


def test_a_commit_on_several_branches_names_them_all(repo, tmp_path):
    # Naming one of them would send the reader to push a branch that may not be the one they meant.
    from deployment_baselines import reached_by

    push_to_a_new_remote(repo, tmp_path)
    git(repo, "commit", "-q", "--allow-empty", "-m", "not pushed")
    git(repo, "branch", "also-here")

    assert reached_by(repo, head_of(repo)) == ["also-here", "main"]


def test_a_recorded_commit_no_tag_names_is_listed(repo, tmp_path):
    # Preservation is the tag's first job. A branch holding it is not enough: branches move.
    push_to_a_new_remote(repo, tmp_path)
    write_baselines(repo, add({}, baseline_for(commit=head_of(repo))))

    assert [b.contractType for b in review(repo).untagged] == ["Foo"]


def test_a_recorded_commit_a_tag_names_is_not_listed(repo, tmp_path):
    # `--points-at`, not `--contains`: a commit some later tag happens to contain is safe from
    # collection but is not NAMED, and naming a state file's capture is the tag's second job.
    from deployment_baselines import deploy_tags

    push_to_a_new_remote(repo, tmp_path)
    baseline = baseline_for(commit=head_of(repo))
    write_baselines(repo, add({}, baseline))
    git(repo, "tag", deploy_tags(baseline)[0], baseline.commit)

    assert review(repo).untagged == []
