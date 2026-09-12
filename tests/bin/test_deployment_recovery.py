"""Recovering a baseline: which commit, and does it produce what is on chain.

The two halves are separated because only one of them can be tested without a network and a compiler.
The comparison arithmetic - stripping the metadata trailer, masking immutables - is pure and is where
a mistake would silently produce a MATCH against the wrong contract, so it is tested exhaustively
here. Placing a worktree and compiling is proven by running it, in C0's report.

Every constant below came from the real recovery of `BaoPauser_v1` at 0xd8785d5C on 2026-03-21.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "bin"))

from deployment_recovery import (  # noqa: E402
    artefact_for,
    all_commits,
    build_id,
    commit_timestamp,
    creation_block,
    differences,
    mask_immutables,
    matches,
    place_worktree,
    remove_worktree,
    search_passes,
    source_at,
    source_blobs,
    still_to_compare,
    strip_metadata,
    submodule_commits,
)


def artefact(runtime: bytes, creation: bytes = b"\x60\x80", immutables: dict | None = None) -> dict:
    return {
        "bytecode": {"object": "0x" + creation.hex()},
        "deployedBytecode": {"object": "0x" + runtime.hex(), "immutableReferences": immutables or {}},
    }


def with_trailer(body: bytes, filler: int = 0x00) -> bytes:
    """`body` as a deployed contract carries it: with a CBOR trailer and its length.

    `filler` varies the trailer's contents, because the whole difficulty is that two trailers over the
    same code are NOT equal - they hash the sources and settings of the tree each was built in."""
    trailer = b"\xa2\x64solc" + bytes([filler]) * 45
    return body + trailer + len(trailer).to_bytes(2, "big")


def git(where: Path, *arguments: str) -> None:
    subprocess.run(["git", *arguments], cwd=where, capture_output=True, text=True, check=True)


def git_output(where: Path, *arguments: str) -> str:
    return subprocess.run(["git", *arguments], cwd=where, capture_output=True, text=True, check=True).stdout.strip()


# ── naming the build's inputs, so a record can be checked without building ─────────────────────────
#
# A commit plus a path is enough to FIND a source, but a check that wants to know whether two trees
# would build the same bytecode should not have to build them. Blob ids answer that with git alone -
# which is what the tag check needs, and what re-proving a record needs when the build is expensive.
#
# The catch is submodules: most of a contract's closure lives in one, a blob id resolves only in the
# object store that holds it, and the superproject records WHICH commit of the submodule it had. A
# submodule that has moved on since must not change the answer, or the record dates itself.


def repository_with_submodule(tmp_path: Path) -> tuple[Path, str, str, str]:
    """A superproject with `lib/dependency` at a recorded commit, whose tip has since moved on.

    Returns the superproject, its commit, and the dependency's first and second source blob ids."""
    dependency = tmp_path / "dependency"
    (dependency / "src").mkdir(parents=True)
    git(dependency, "init", "-q", "-b", "main")
    git(dependency, "config", "user.email", "t@t")
    git(dependency, "config", "user.name", "test")
    (dependency / "src" / "Dependency.sol").write_text("// the version the superproject records\n")
    git(dependency, "add", "-A")
    git(dependency, "commit", "-qm", "recorded")
    recorded_blob = git_output(dependency, "rev-parse", "HEAD:src/Dependency.sol")

    superproject = tmp_path / "superproject"
    (superproject / "src").mkdir(parents=True)
    git(superproject, "init", "-q", "-b", "main")
    git(superproject, "config", "user.email", "t@t")
    git(superproject, "config", "user.name", "test")
    (superproject / "src" / "Own.sol").write_text("// the superproject's own source\n")
    git(
        superproject,
        "-c",
        "protocol.file.allow=always",
        "submodule",
        "--quiet",
        "add",
        str(dependency),
        "lib/dependency",
    )
    git(superproject, "add", "-A")
    git(superproject, "commit", "-qm", "with the dependency")
    commit = git_output(superproject, "rev-parse", "HEAD")

    # The dependency moves on afterwards, without the superproject following it.
    (dependency / "src" / "Dependency.sol").write_text("// a later version nothing records\n")
    git(dependency, "add", "-A")
    git(dependency, "commit", "-qm", "later")
    later_blob = git_output(dependency, "rev-parse", "HEAD:src/Dependency.sol")

    return superproject, commit, recorded_blob, later_blob


def test_a_source_of_the_superproject_is_named_by_its_blob_id(tmp_path):
    superproject, commit, _, _ = repository_with_submodule(tmp_path)

    named = source_blobs(superproject, commit, ["src/Own.sol"])

    assert named == {"src/Own.sol": git_output(superproject, "rev-parse", f"{commit}:src/Own.sol")}


def test_a_source_inside_a_submodule_is_read_at_the_commit_the_superproject_records(tmp_path):
    # The failure this prevents: reading the submodule's tip instead, so the record says what the
    # dependency looks like today rather than what the build actually read.
    superproject, commit, recorded_blob, later_blob = repository_with_submodule(tmp_path)

    named = source_blobs(superproject, commit, ["lib/dependency/src/Dependency.sol"])

    assert named == {"lib/dependency/src/Dependency.sol": recorded_blob}
    assert recorded_blob != later_blob, "the dependency did move on, so the two are distinguishable"


def test_every_submodule_the_commit_records_is_named(tmp_path):
    # The cheap check compares these as well as the sources: a tree with identical sources but a
    # different dependency builds different bytecode.
    superproject, commit, _, _ = repository_with_submodule(tmp_path)

    assert submodule_commits(superproject, commit) == {
        "lib/dependency": git_output(superproject, "rev-parse", f"{commit}:lib/dependency")
    }


def test_a_source_the_commit_does_not_have_is_reported(tmp_path):
    # A record missing a source would be a record that cannot be rebuilt, so this cannot pass quietly.
    superproject, commit, _, _ = repository_with_submodule(tmp_path)

    with pytest.raises(FileNotFoundError) as missing:
        source_blobs(superproject, commit, ["src/Own.sol", "src/NeverExisted.sol"])

    assert "src/NeverExisted.sol" in str(missing.value)


# ── the comparison arithmetic ─────────────────────────────────────────────────────────────────────


def test_the_metadata_trailer_is_removed_by_its_own_declared_length():
    # A deployed contract carries a CBOR trailer that a metadata-off build does not: the real one was
    # 53 bytes, and without removing it the comparison differs by exactly that and says nothing.
    body = bytes.fromhex("6080604052")
    trailer = b"\xa2\x64solc" + b"\x00" * 45  # 51 bytes, whatever it holds
    code = body + trailer + len(trailer).to_bytes(2, "big")

    assert strip_metadata(code) == body


def test_code_with_no_trailer_is_left_alone():
    # A metadata-off build has none, and a length that cannot be a trailer must not eat the contract.
    code = bytes.fromhex("6080604052")

    assert strip_metadata(code) == code


def test_a_declared_length_longer_than_the_code_is_refused_not_applied():
    # Otherwise a malformed or non-contract response silently strips everything and compares empty
    # against empty - a MATCH that means nothing at all.
    code = bytes.fromhex("6080") + (9999).to_bytes(2, "big")

    assert strip_metadata(code) == code


def test_nothing_is_stripped_unless_a_cbor_MAP_begins_where_the_length_says():
    # Real code whose last two bytes happen to read as a plausible length would otherwise lose that
    # many bytes off the end. Relying on the later length check in `matches` to catch it is mitigation
    # at a distance; solidity's trailer is a CBOR map, so the header is checked HERE, where the
    # decision is made.
    body = bytes.fromhex("60806040") + bytes(20)
    not_a_trailer = body + b"\x00" * 8 + (8).to_bytes(2, "big")

    assert strip_metadata(not_a_trailer) == not_a_trailer, "0x00 is not a CBOR map header"

    real = body + b"\xa2\x64solc" + (6).to_bytes(2, "big")
    assert strip_metadata(real) == body, "0xa2 is a two-entry map, which is what solidity emits"


def test_immutables_are_masked_on_both_sides_at_the_offsets_the_artefact_declares():
    # The built artefact has zeros where an immutable goes; the chain has the value. Masking both is
    # what lets the rest be compared - BaoPauser_v1 has 6 such regions.
    built = bytes(20)
    onchain = bytes(8) + bytes.fromhex("d8785d5c51aa") + bytes(6)
    refs = {"42": [{"start": 8, "length": 6}]}

    assert mask_immutables(onchain, refs) == mask_immutables(built, refs)


def test_masking_leaves_everything_outside_the_declared_regions_alone():
    # The whole point: a difference anywhere else must still be visible. Masking too widely is how a
    # comparison starts passing over contracts it should reject.
    a = bytes.fromhex("aabbccdd")
    b = bytes.fromhex("aabbcc00")

    assert mask_immutables(a, {}) != mask_immutables(b, {})
    assert mask_immutables(a, {"1": [{"start": 3, "length": 1}]}) == mask_immutables(
        b, {"1": [{"start": 3, "length": 1}]}
    )


# ── the verdict itself ────────────────────────────────────────────────────────────────────────────
#
# `matches` decides whether a baseline is TRUE. A fault here writes a wrong commit into the record,
# which everything downstream then believes - the worst failure this tool has. Its parts were tested
# before it was; these are the composition.


def test_the_deployed_code_matches_the_artefact_that_built_it():
    body = bytes.fromhex("6080604052" + "00" * 40)

    agreed, immutables = matches(with_trailer(body), artefact(body))

    assert agreed and immutables == []


def test_the_artefact_is_stripped_too_because_a_real_build_carries_its_own_metadata():
    # The comparison must be symmetric. Stripping only the chain's side worked only while the build was
    # forced to produce no metadata, and forcing that was itself the defect: solc emits an `INVALID`
    # separator before the metadata and emits none when there is nothing to separate, so the
    # metadata-off build was a byte shorter than anything ever deployed. Measured on
    # `Aggregator_stETH_USD_mainnet`: 3302 bytes off, 3303 on, 3303 deployed.
    #
    # The two trailers never agree - each hashes the tree it was built in - so both are removed and the
    # verdict rests on the code.
    body = bytes.fromhex("6080604052" + "00" * 40)

    agreed, _ = matches(with_trailer(body), artefact(with_trailer(body, filler=0x11)))

    assert agreed


def test_one_byte_different_outside_the_masked_regions_is_not_a_match():
    # The case that must never pass: same length, so the cheap length check does not catch it, and the
    # difference is where nothing is masked. If this ever goes green the tool is writing lies.
    body = bytes.fromhex("6080604052" + "00" * 40)
    tampered = bytearray(body)
    tampered[2] ^= 0xFF

    agreed, _ = matches(with_trailer(bytes(tampered)), artefact(body))

    assert not agreed


def test_a_difference_only_inside_an_immutable_region_is_still_a_match():
    # An immutable is written at construction, so the chain has a value where the build has zeros.
    # That difference is expected, and masking it is the whole reason the comparison can be made.
    built = bytes(20)
    onchain = bytes(8) + bytes.fromhex("d8785d5c51aa") + bytes(6)
    references = {"42": [{"start": 8, "length": 6}]}

    agreed, immutables = matches(with_trailer(onchain), artefact(built, immutables=references))

    assert agreed
    assert immutables == ["0xd8785d5c51aa"], "and what was masked is handed back to be looked at"


def test_a_length_mismatch_is_not_a_match():
    # Which is also the safety net under `strip_metadata`: a trailer stripped wrongly changes the
    # length, so a bad strip yields a false NEGATIVE, never a false positive.
    agreed, _ = matches(with_trailer(bytes(20)), artefact(bytes(21)))

    assert not agreed


# ── constructing, rather than masking ─────────────────────────────────────────────────────────────
#
# Masking an immutable makes the comparison possible but weakens what it proves: a match becomes a
# match MODULO the immutables, and two sources differing only in a value that becomes an immutable are
# indistinguishable. They need not be excluded - these constructors take no arguments, so the values
# are determined by the source, and executing the creation code reproduces them. What remains after
# that is genuinely deployment-specific and must be NAMED, never excluded as a class.


def spans(*regions: tuple[int, int]) -> dict:
    return {str(index): [{"start": start, "length": length}] for index, (start, length) in enumerate(regions)}


def word(value: bytes) -> bytes:
    """A 32-byte slot holding `value`, left-padded, as the EVM stores one."""
    return bytes(32 - len(value)) + value


SELF = "0x003056C3a3262b37C59143149D062Ad3a6a45BF7"


def test_code_the_constructor_reproduces_exactly_has_nothing_to_explain():
    body = bytes.fromhex("6080604052") + word(bytes.fromhex("aabb"))

    explained, unexplained = differences(body, body, spans((5, 32)), SELF)

    assert (explained, unexplained) == ([], [])


def test_a_difference_that_is_the_contract_s_own_address_is_explained():
    # The one immutable a local construction cannot reproduce: `address(this)` is where the code runs,
    # and the construction runs somewhere else. OpenZeppelin's UUPS `__self` is exactly this.
    deployed = bytes.fromhex("6080604052") + word(bytes.fromhex(SELF[2:]))
    produced = bytes.fromhex("6080604052") + word(bytes.fromhex("11" * 20))

    explained, unexplained = differences(deployed, produced, spans((5, 32)), SELF)

    assert unexplained == []
    assert len(explained) == 1 and "own address" in explained[0]


def test_a_difference_inside_an_immutable_that_is_not_the_address_is_NOT_explained():
    # The case the whole change exists for. Two aggregators differing only in their feed address have
    # identical code once that immutable is masked, so masking would call this a match. Constructing
    # reproduces the feed address, so a mismatch here means the source is not what was deployed.
    feed = bytes.fromhex("cfe54b5cd566ab89272946f602d76ea879cab4a8")
    other = bytes.fromhex("9babfc1a1952a6ed2cac1922bffe80c0506364a2")
    deployed = bytes.fromhex("6080604052") + word(feed)
    produced = bytes.fromhex("6080604052") + word(other)

    explained, unexplained = differences(deployed, produced, spans((5, 32)), SELF)

    assert explained == []
    assert len(unexplained) == 1
    assert feed.hex() in unexplained[0] and other.hex() in unexplained[0], "both values are named"


def test_a_difference_outside_every_immutable_region_is_never_explained():
    # Nothing about a deployment can move a byte the constructor did not write. This must reject
    # however many immutables the artefact declares.
    deployed = bytes.fromhex("6080604052")
    produced = bytes.fromhex("60806040ff")

    explained, unexplained = differences(deployed, produced, spans((0, 4)), SELF)

    assert explained == []
    assert len(unexplained) == 1 and "outside" in unexplained[0]


def test_a_length_difference_is_never_explained():
    explained, unexplained = differences(bytes(20), bytes(21), {}, SELF)

    assert explained == []
    assert len(unexplained) == 1 and "length" in unexplained[0]


def test_several_immutables_are_judged_one_at_a_time():
    # A contract has many - the pauser six, an aggregator ten - and one being explicable says nothing
    # about the next. Mixing them into a single verdict is what masking did.
    feed = bytes.fromhex("cfe54b5cd566ab89272946f602d76ea879cab4a8")
    deployed = word(bytes.fromhex(SELF[2:])) + word(feed)
    produced = word(bytes.fromhex("11" * 20)) + word(bytes.fromhex("22" * 20))

    explained, unexplained = differences(deployed, produced, spans((0, 32), (32, 32)), SELF)

    assert len(explained) == 1 and len(unexplained) == 1


# ── not building the same thing twice, without losing a contract to it ────────────────────────────


def test_a_build_is_not_repeated_for_a_contract_already_compared_against_it():
    # The saving: twenty aggregators share a deploy and so share candidates, and many of those commits
    # read identical build inputs. Building each again proves nothing new about the same contracts.
    compared = {}

    assert still_to_compare(compared, "inputs-a", ["1/0xaa", "1/0xbb"]) == ["1/0xaa", "1/0xbb"]
    assert still_to_compare(compared, "inputs-a", ["1/0xaa", "1/0xbb"]) == []


def test_a_contract_that_has_not_seen_a_build_gets_it_even_when_someone_else_has():
    # The defect this exists to stop, and it cost 52 of 97. Recording the build id alone - a set of
    # builds already done - skips the commit for a contract whose window opens on it later, so the
    # contract is reported as "no candidate built what is deployed" having been compared against
    # nothing at all. `Aggregator_stETH_AAPL_arbitrum` recovers at 3a108494df when run on its own.
    compared = {}
    still_to_compare(compared, "inputs-a", ["1/0xaa"])

    assert still_to_compare(compared, "inputs-a", ["1/0xbb"]) == ["1/0xbb"]


def test_only_the_contracts_that_have_not_seen_it_are_returned():
    # A mixed set is the ordinary case once a run is under way: the build is worth doing for the one
    # that has not seen it, and the comparison is not worth repeating for the one that has.
    compared = {}
    still_to_compare(compared, "inputs-a", ["1/0xaa"])

    assert still_to_compare(compared, "inputs-a", ["1/0xaa", "1/0xbb"]) == ["1/0xbb"]


def test_a_different_build_is_a_different_question_for_the_same_contract():
    compared = {}
    still_to_compare(compared, "inputs-a", ["1/0xaa"])

    assert still_to_compare(compared, "inputs-b", ["1/0xaa"]) == ["1/0xaa"]


# ── locating the artefact ─────────────────────────────────────────────────────────────────────────


def test_the_artefact_is_found_by_the_source_it_declares_not_by_its_directory(tmp_path):
    # `out/<basename>.sol/` is a flat namespace this fleet already collides in. `compilationTarget` is
    # the artefact's own statement of where it came from, so two same-named contracts stay distinct.
    for chain in ("mainnet", "megaeth"):
        directory = tmp_path / "Aggregator.sol"
        directory.mkdir(exist_ok=True)
        (directory / f"Aggregator_{chain}.json").write_text(
            json.dumps(
                {
                    "bytecode": {"object": "0x00"},
                    "deployedBytecode": {"object": "0x00"},
                    "metadata": {
                        "settings": {"compilationTarget": {f"src/{chain}/Aggregator.sol": f"Aggregator_{chain}"}}
                    },
                }
            )
        )

    found = artefact_for(tmp_path, "src/megaeth/Aggregator.sol", "Aggregator_megaeth")

    assert found is not None
    assert found["metadata"]["settings"]["compilationTarget"] == {"src/megaeth/Aggregator.sol": "Aggregator_megaeth"}


def artefact_declaring(directory: Path, name: str, source: str) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    (directory / f"{name}.json").write_text(
        json.dumps(
            {
                "bytecode": {"object": "0x00"},
                "deployedBytecode": {"object": "0x00"},
                "metadata": {"settings": {"compilationTarget": {source: name}}},
            }
        )
    )


def test_the_source_must_match_exactly_not_as_a_suffix(tmp_path):
    # `path.endswith(source)` looked safe and is not: `src/XFoo.sol` does not match `src/Foo.sol`, but
    # `myssrc/Foo.sol` DOES, and so does any vendored copy at `lib/dep/src/Foo.sol`. This decides
    # which bytecode a baseline is compared against, so it is equality.
    artefact_declaring(tmp_path / "Foo.sol", "Foo", "myssrc/Foo.sol")

    assert artefact_for(tmp_path, "src/Foo.sol", "Foo") is None


def test_two_artefacts_claiming_one_source_are_refused_not_picked_between(tmp_path):
    # The flat artefact namespace this fleet already collides in. Returning either would be arbitrary,
    # and arbitrary here means comparing against the wrong contract's bytecode.
    artefact_declaring(tmp_path / "Foo.sol", "Foo", "src/Foo.sol")
    artefact_declaring(tmp_path / "elsewhere" / "Foo.sol", "Foo", "src/Foo.sol")

    assert artefact_for(tmp_path, "src/Foo.sol", "Foo") is None


# ── choosing the candidate ────────────────────────────────────────────────────────────────────────


@pytest.fixture
def repo(tmp_path):
    """Three commits with known dates, so "what was HEAD when the deploy ran" has a right answer."""
    git(tmp_path, "init", "-q", "-b", "main")
    git(tmp_path, "config", "user.email", "t@t")
    git(tmp_path, "config", "user.name", "test")
    # Under `src/`, because a commit touching nothing a build reads is deliberately not a candidate -
    # so a fixture of `.txt` files would exercise the empty case and call it the ordinary one.
    (tmp_path / "src").mkdir()
    for n, when in enumerate(["2026-03-01T00:00:00", "2026-03-19T00:00:00", "2026-03-24T00:00:00"]):
        (tmp_path / "src" / f"f{n}.sol").write_text(f"contract F{n} {{}}\n")
        git(tmp_path, "add", "-A")
        subprocess.run(
            ["git", "commit", "-qm", f"c{n}"],
            cwd=tmp_path,
            check=True,
            capture_output=True,
            env={
                "PATH": "/usr/bin:/bin",
                "HOME": str(tmp_path),
                "GIT_AUTHOR_DATE": when,
                "GIT_COMMITTER_DATE": when,
                "GIT_AUTHOR_NAME": "t",
                "GIT_AUTHOR_EMAIL": "t@t",
                "GIT_COMMITTER_NAME": "t",
                "GIT_COMMITTER_EMAIL": "t@t",
            },
        )
    return tmp_path


def order_for(repo: Path, deployed: str) -> list[str]:
    """The commits one contract tries, in order - composed exactly as the run composes them, so these
    tests exercise the real search rather than a restatement of it."""
    dated = all_commits(repo)
    return [commit for _, order, admits in search_passes(dated) for commit, when in order if admits(when, deployed)]


def subjects(repo: Path, commits: list[str]) -> list[str]:
    return [
        subprocess.run(["git", "log", "-1", "--format=%s", c], cwd=repo, capture_output=True, text=True).stdout.strip()
        for c in commits
    ]


def commit_at(repo: Path, when: str, path: str, body: str = "x") -> str:
    target = repo / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(body)
    subprocess.run(["git", "add", "-A"], cwd=repo, check=True, capture_output=True)
    subprocess.run(
        ["git", "commit", "-qm", f"touch {path}"],
        cwd=repo,
        check=True,
        capture_output=True,
        env={
            "PATH": "/usr/bin:/bin",
            "HOME": str(repo),
            "GIT_AUTHOR_DATE": when,
            "GIT_COMMITTER_DATE": when,
            "GIT_AUTHOR_NAME": "t",
            "GIT_AUTHOR_EMAIL": "t@t",
            "GIT_COMMITTER_NAME": "t",
            "GIT_COMMITTER_EMAIL": "t@t",
        },
    )
    return subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True).stdout.strip()


def test_a_commit_touching_nothing_a_build_reads_is_still_a_candidate(repo):
    # It was excluded, to save building it - and that lost the true answer. `BaoPauser_v1` was
    # deployed from a commit whose only change was `bin/coverage`; dropping it recorded a two-month
    # older commit that compiled identically. Right bytecode, wrong provenance.
    docs = commit_at(repo, "2026-03-10T00:00:00", "README.md")

    assert docs in order_for(repo, "2026-03-20T00:00:00Z")


def test_commits_reading_the_same_build_inputs_share_a_build_id(repo):
    # Which is where the saving actually belongs: the second need not be BUILT, and no candidate is
    # dropped to get it.
    before = commit_at(repo, "2026-03-10T00:00:00", "src/Thing.sol", "contract Thing {}")
    docs = commit_at(repo, "2026-03-11T00:00:00", "README.md")
    changed = commit_at(repo, "2026-03-12T00:00:00", "src/Thing.sol", "contract Thing { uint256 x; }")

    assert build_id(repo, docs) == build_id(repo, before), "a README changes no build"
    assert build_id(repo, changed) != build_id(repo, before)


def test_the_search_is_not_bounded_at_all(repo):
    # It was `--limit 12`, then a 120/30-day window. Every bound was wrong the same way: THE ERROR IS
    # ONE-SIDED. Too narrow loses the answer and reports it as "no candidate built what is deployed",
    # which is indistinguishable from a real miss; too wide costs only time and cannot give a wrong
    # answer, because every match is verified against the deployed bytecode.
    #
    # A time window also measures the calendar, not the repository: the same 120/30 days gave 89
    # candidates around February 2026 and 23 around May. And it bought almost nothing - 145 commits
    # carry 89 distinct builds, the window covered 75 of them, at a mean of 1.0s a build.
    old = commit_at(repo, "2024-01-01T00:00:00", "src/Old.sol", "contract Old {}")
    recent = commit_at(repo, "2026-03-11T00:00:00", "src/New.sol", "contract New {}")

    found = order_for(repo, "2026-03-20T00:00:00Z")

    assert recent in found
    assert old in found, "two years earlier is still a tree someone could have deployed from"


def test_the_first_candidate_is_the_last_commit_before_the_deploy(repo):
    # The measured pattern: the commit that RECORDS a deploy lands days after it, so the likeliest
    # source is the last commit BEFORE the deployment timestamp.
    assert subjects(repo, order_for(repo, "2026-03-21T13:44:18Z"))[0] == "c1"


def test_candidates_continue_backwards_then_forwards(repo):
    # One guess is not enough: ten of the aggregators' contracts built cleanly and did not match, and
    # a deploy from a dirty tree has its source committed AFTERWARDS - bao-base's own pauser was
    # edited three days later. So earlier commits come next, then the ones after the deploy.
    found = subjects(repo, order_for(repo, "2026-03-21T13:44:18Z"))

    assert found[0] == "c1", "likeliest first"
    assert set(found) == {"c0", "c1", "c2"}, "and the rest are reachable"
    assert found.index("c0") < found.index("c2"), "earlier before later: the tree was more likely behind"


def test_a_commit_on_a_merged_branch_is_a_candidate(repo):
    # Deploys run from whatever was checked out, and that is often a feature branch: the arbitrum
    # aggregators were deployed from `l2feeds`, whose tip held "Remove BASE_NAME storage from Arbitrum
    # and Base oracles" - exactly the change that decides the bytecode. `--first-parent` saw 11 commits
    # in the window where there were 63, and none of them could have built what is on chain.
    subprocess.run(["git", "checkout", "-q", "-b", "feature", "HEAD~1"], cwd=repo, check=True, capture_output=True)
    (repo / "src" / "OnBranch.sol").write_text("contract OnBranch {}\n")
    subprocess.run(["git", "add", "-A"], cwd=repo, check=True, capture_output=True)
    subprocess.run(["git", "commit", "-qm", "on the branch"], cwd=repo, check=True, capture_output=True)
    branch_tip = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True).stdout.strip()
    subprocess.run(["git", "checkout", "-q", "main"], cwd=repo, check=True, capture_output=True)
    subprocess.run(
        ["git", "merge", "-q", "--no-ff", "-m", "merge the branch", "feature"],
        cwd=repo,
        check=True,
        capture_output=True,
    )

    # Derived from the repository rather than a magic future date: "a moment just after everything".
    latest = subprocess.run(
        ["git", "log", "-1", "--format=%cI"], cwd=repo, capture_output=True, text=True
    ).stdout.strip()

    assert branch_tip in order_for(repo, latest), "a branch commit must be reachable"


def test_a_commit_on_an_unmerged_branch_is_still_a_candidate(repo):
    # Reading only the current branch's history would miss it, and a deploy runs from whatever is
    # checked out - including a branch that never landed.
    subprocess.run(["git", "checkout", "-q", "-b", "stranded"], cwd=repo, check=True, capture_output=True)
    (repo / "src" / "Stranded.sol").write_text("contract Stranded {}\n")
    git(repo, "add", "-A")
    subprocess.run(["git", "commit", "-qm", "never merged"], cwd=repo, check=True, capture_output=True)
    tip = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True).stdout.strip()
    subprocess.run(["git", "checkout", "-q", "main"], cwd=repo, check=True, capture_output=True)

    assert tip in [commit for commit, _ in all_commits(repo)]


def test_a_stashed_tree_is_still_a_candidate(repo):
    # A deploy from a dirty tree whose source was STASHED rather than committed is findable nowhere
    # else, and a stash is a real commit that builds like any other.
    (repo / "src" / "Dirty.sol").write_text("contract Dirty {}\n")
    git(repo, "add", "-A")
    subprocess.run(["git", "stash", "-q"], cwd=repo, check=True, capture_output=True)

    stashed = subprocess.run(["git", "rev-parse", "stash@{0}"], cwd=repo, capture_output=True, text=True).stdout.strip()

    assert stashed in [commit for commit, _ in all_commits(repo)]


def test_a_deploy_before_every_commit_takes_them_all_oldest_first(repo):
    # The dirty-tree case at its limit: nothing was committed before the deploy, so the whole history
    # is in the second pass, and the EARLIEST commit is where that source first landed.
    far = "2020-01-01T00:00:00Z"

    assert subjects(repo, order_for(repo, far)) == ["c0", "c1", "c2"], "oldest first, all after"


def test_the_source_is_found_at_the_candidate_commit_not_at_the_recorded_path(repo, tmp_path):
    # `v3-oracles.json` records `src/Aggregator_…` where the tree now holds `src/mainnet/Aggregator_…`.
    # Building the recorded path at an older commit gave "No source files found" 40 times. The
    # contract NAME is what survives a move, so the file is located in that commit's own tree.
    (repo / "src").mkdir(exist_ok=True)
    (repo / "src" / "Foo.sol").write_text("contract Foo {}\n")
    subprocess.run(["git", "add", "-A"], cwd=repo, check=True, capture_output=True)
    subprocess.run(["git", "commit", "-qm", "add Foo"], cwd=repo, check=True, capture_output=True)
    early = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True).stdout.strip()

    (repo / "src" / "moved").mkdir()
    (repo / "src" / "moved" / "Foo.sol").write_text("contract Foo {}\n")
    (repo / "src" / "Foo.sol").unlink()
    subprocess.run(["git", "add", "-A"], cwd=repo, check=True, capture_output=True)
    subprocess.run(["git", "commit", "-qm", "move Foo"], cwd=repo, check=True, capture_output=True)

    assert source_at(repo, early, "Foo") == ("src/Foo.sol", "Foo")
    assert source_at(repo, "HEAD", "Foo") == ("src/moved/Foo.sol", "Foo")


def test_a_contract_renamed_after_the_deploy_is_followed_by_its_file(repo):
    # The megaeth aggregators: the manifest records `Aggregator_USDM_ETH_megaeth`, but at deploy time
    # the token was USDMY and the contract was `Aggregator_USDMY_ETH_megaeth`. The NAME survives a
    # move and not a rename, so locating by name alone found nothing at any of 50 builds and reported
    # "no candidate built what is deployed" for twelve contracts.
    #
    # What survives both is git's own rename tracking of the FILE, which is why the recorded path is
    # the fallback: `git diff -M` reports the old path, and whatever contract it declares THERE is the
    # one that was deployed.
    (repo / "src").mkdir(exist_ok=True)
    (repo / "src" / "Old.sol").write_text("contract Old {\n    uint256 constant A = 1;\n    // body\n}\n")
    git(repo, "add", "-A")
    subprocess.run(["git", "commit", "-qm", "before the rename"], cwd=repo, check=True, capture_output=True)
    early = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True).stdout.strip()

    (repo / "src" / "New.sol").write_text("contract New {\n    uint256 constant A = 1;\n    // body\n}\n")
    (repo / "src" / "Old.sol").unlink()
    git(repo, "add", "-A")
    subprocess.run(["git", "commit", "-qm", "rename it"], cwd=repo, check=True, capture_output=True)

    assert source_at(repo, early, "New", recorded_path="src/New.sol") == ("src/Old.sol", "Old")


def test_the_name_wins_over_the_path_when_both_could_answer(repo):
    # The path is only a fallback. A file that MOVED still declares the recorded name, and following
    # the path instead would answer with wherever the path happens to point.
    (repo / "src").mkdir(exist_ok=True)
    (repo / "src" / "Foo.sol").write_text("contract Foo {}\n")
    git(repo, "add", "-A")
    subprocess.run(["git", "commit", "-qm", "add Foo"], cwd=repo, check=True, capture_output=True)

    assert source_at(repo, "HEAD", "Foo", recorded_path="src/somewhere/else/Foo.sol") == ("src/Foo.sol", "Foo")


def test_a_contract_absent_from_that_commit_is_not_guessed_at(repo):
    assert source_at(repo, "HEAD", "NeverExisted") is None
    assert source_at(repo, "HEAD", "NeverExisted", recorded_path="src/NeverExisted.sol") is None


def test_a_contract_in_a_dependency_is_found_there_like_anywhere_else(repo):
    # A contract defined in a dependency is defined there; nothing about `lib/` makes it a different
    # kind of source. harbor records 46 contracts whose source is in bao-base, and skipping `lib/`
    # made every one of them unfindable.
    (repo / "lib" / "dep" / "src").mkdir(parents=True)
    (repo / "lib" / "dep" / "src" / "Pauser.sol").write_text("contract Pauser {}\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "vendored dependency")

    assert source_at(repo, "HEAD", "Pauser") == ("lib/dep/src/Pauser.sol", "Pauser")


def test_two_files_declaring_one_contract_is_refused_not_guessed(repo):
    # A clash is caught long before here: `lint-contract-names` fails the build on any duplicate, and
    # a deploy must stop rather than put an ambiguous name on chain - by then it is too late, because
    # nothing afterwards can say which file an address came from. (It currently reports 12 in
    # harbor-price-aggregators, none of them a deployed contract type.)
    #
    # So this branch is a last-resort refusal for something that should never reach it, and it is
    # tested rather than trusted precisely because it is the path nobody exercises.
    for chain in ("mainnet", "megaeth"):
        (repo / "src" / chain).mkdir(parents=True, exist_ok=True)
        (repo / "src" / chain / "Aggregator.sol").write_text("contract Aggregator {}\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "one name, two files")

    assert source_at(repo, "HEAD", "Aggregator") is None


def test_the_declaration_decides_not_the_filename(repo):
    # A `Foo.sol` holding `contract Bar` must not answer for `Foo`, and the file that does declare it
    # must be found however it is named.
    (repo / "src").mkdir(exist_ok=True)
    (repo / "src" / "Foo.sol").write_text("contract Bar {}\n")
    (repo / "src" / "Elsewhere.sol").write_text("contract Foo {}\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "misleading filename")

    assert source_at(repo, "HEAD", "Foo") == ("src/Elsewhere.sol", "Foo")


# ── when it was deployed, and when the commit was made ────────────────────────────────────────────


def test_the_creation_block_is_found_from_an_upper_bound_in_a_handful_of_calls():
    # The manifest's `deploymentTime` is the deploy SCRIPT's clock, written after the broadcast, so a
    # block found from it is always an upper bound - measured at 15 blocks past the truth for
    # BaoPauser, whose manifest was 2m55s late. Walking back from a close upper bound costs a handful
    # of calls; a blind bisect of the whole chain would cost ~25, which is what this exists to avoid.
    asked: list[int] = []

    def has_code(block: int) -> bool:
        asked.append(block)
        return block >= 24706244

    assert creation_block(has_code, upper=24706259) == 24706244
    assert len(asked) <= 12, f"took {len(asked)} calls: {asked}"


def test_a_contract_present_at_the_floor_cannot_be_bracketed():
    # Every block searched has the code, so the creation block is below the range and guessing the
    # floor would record a block the contract did not exist at.
    assert creation_block(lambda block: True, upper=1000, floor=900) is None


def test_the_upper_bound_must_actually_have_the_code():
    # Otherwise the answer is somewhere above, and returning the upper bound would be a fabrication.
    assert creation_block(lambda block: False, upper=1000) is None


def test_a_commit_timestamp_is_utc_whatever_the_committer_s_clock_said(repo):
    # `%cI` carries the committer's local offset, so two identical commits made in different zones
    # would record differently. Unix seconds formatted as UTC removes the question.
    found = commit_timestamp(repo, "HEAD")

    assert found.endswith("Z"), found
    assert found == "2026-03-24T00:00:00Z", "the fixture's last commit, in UTC"


# ── the worktrees, which touch the repository ─────────────────────────────────────────────────────


def test_placing_and_removing_a_worktree_leaves_the_repository_as_it_was(repo, tmp_path):
    # These are the only functions here with side effects OUTSIDE a temporary directory. A regression
    # in cleanup accumulates worktrees in every repository this is run against, silently.
    before = subprocess.run(["git", "worktree", "list"], cwd=repo, capture_output=True, text=True).stdout

    at = tmp_path / "placed"
    place_worktree(repo, "HEAD", at)
    assert (at / "src" / "f0.sol").is_file(), "the commit's content is actually there"
    assert len(
        subprocess.run(["git", "worktree", "list"], cwd=repo, capture_output=True, text=True).stdout.splitlines()
    ) > len(before.splitlines())

    remove_worktree(repo, at)

    assert subprocess.run(["git", "worktree", "list"], cwd=repo, capture_output=True, text=True).stdout == before
