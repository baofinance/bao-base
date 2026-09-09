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
    build_fingerprint,
    candidate_commits,
    commit_timestamp,
    creation_block,
    mask_immutables,
    matches,
    place_worktree,
    remove_worktree,
    source_at,
    strip_metadata,
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

    assert docs in candidate_commits(repo, "2026-03-20T00:00:00Z")


def test_commits_reading_the_same_build_inputs_share_a_fingerprint(repo):
    # Which is where the saving actually belongs: the second need not be BUILT, and no candidate is
    # dropped to get it.
    before = commit_at(repo, "2026-03-10T00:00:00", "src/Thing.sol", "contract Thing {}")
    docs = commit_at(repo, "2026-03-11T00:00:00", "README.md")
    changed = commit_at(repo, "2026-03-12T00:00:00", "src/Thing.sol", "contract Thing { uint256 x; }")

    assert build_fingerprint(repo, docs) == build_fingerprint(repo, before), "a README changes no build"
    assert build_fingerprint(repo, changed) != build_fingerprint(repo, before)


def test_candidates_are_bounded_by_time_not_by_a_count(repo):
    # The bound was `--limit 12`, a number with nothing behind it - and one that was not even the
    # constraint: twelve commits already reached two months back in the aggregators. A window says
    # what it means and is the same bound the user gave for the search.
    old = commit_at(repo, "2024-01-01T00:00:00", "src/Old.sol", "contract Old {}")
    recent = commit_at(repo, "2026-03-11T00:00:00", "src/New.sol", "contract New {}")

    found = candidate_commits(repo, "2026-03-20T00:00:00Z", before_days=90, after_days=30)

    assert recent in found
    assert old not in found, "two years before the deploy is outside any sane window"


def test_the_first_candidate_is_the_last_commit_before_the_deploy(repo):
    # The measured pattern: the commit that RECORDS a deploy lands days after it, so the likeliest
    # source is the last commit BEFORE the deployment timestamp.
    assert subjects(repo, candidate_commits(repo, "2026-03-21T13:44:18Z"))[0] == "c1"


def test_candidates_continue_backwards_then_forwards(repo):
    # One guess is not enough: ten of the aggregators' contracts built cleanly and did not match, and
    # a deploy from a dirty tree has its source committed AFTERWARDS - bao-base's own pauser was
    # edited three days later. So earlier commits come next, then the ones after the deploy.
    found = subjects(repo, candidate_commits(repo, "2026-03-21T13:44:18Z"))

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
    branch_tip = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True
    ).stdout.strip()
    subprocess.run(["git", "checkout", "-q", "main"], cwd=repo, check=True, capture_output=True)
    subprocess.run(
        ["git", "merge", "-q", "--no-ff", "-m", "merge the branch", "feature"], cwd=repo, check=True, capture_output=True
    )

    # Derived from the repository rather than a magic future date: "a moment just after everything".
    latest = subprocess.run(
        ["git", "log", "-1", "--format=%cI"], cwd=repo, capture_output=True, text=True
    ).stdout.strip()

    assert branch_tip in candidate_commits(repo, latest), "a branch commit must be reachable"


def test_a_deploy_far_outside_the_window_finds_nothing_until_the_window_is_widened(repo):
    # With a bounded window this is honest rather than a failure: a deploy six years before any commit
    # cannot have been built from one. The caller widens deliberately - which is what an entry with no
    # recorded time needs, since its bracket is "somewhere between now and last year" rather than a
    # few months either side of a known moment.
    far = "2020-01-01T00:00:00Z"

    assert candidate_commits(repo, far) == []
    assert subjects(repo, candidate_commits(repo, far, after_days=365 * 10))[0] == "c0", "oldest first, after"


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

    assert source_at(repo, early, "Foo") == "src/Foo.sol"
    assert source_at(repo, "HEAD", "Foo") == "src/moved/Foo.sol"


def test_a_contract_absent_from_that_commit_is_not_guessed_at(repo):
    assert source_at(repo, "HEAD", "NeverExisted") is None


def test_a_contract_in_a_dependency_is_found_there_like_anywhere_else(repo):
    # A contract defined in a dependency is defined there; nothing about `lib/` makes it a different
    # kind of source. harbor records 46 contracts whose source is in bao-base, and skipping `lib/`
    # made every one of them unfindable.
    (repo / "lib" / "dep" / "src").mkdir(parents=True)
    (repo / "lib" / "dep" / "src" / "Pauser.sol").write_text("contract Pauser {}\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "vendored dependency")

    assert source_at(repo, "HEAD", "Pauser") == "lib/dep/src/Pauser.sol"


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

    assert source_at(repo, "HEAD", "Foo") == "src/Elsewhere.sol"


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
