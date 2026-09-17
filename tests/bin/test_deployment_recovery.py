"""Recovering a baseline: which commit, and does it produce what is on chain.

The two halves are separated because only one of them can be tested without a network and a compiler.
The comparison arithmetic - stripping the metadata trailer, masking immutables - is pure and is where
a mistake would silently produce a MATCH against the wrong contract, so it is tested exhaustively
here. Placing a worktree and compiling is proven by running it, in C0's report.

Every constant below came from the real recovery of `BaoPauser_v1` at 0xd8785d5C on 2026-03-21.
"""

from __future__ import annotations

import json
import re
import shutil
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
    compiler_in,
    creation_block,
    declaration_of,
    differences,
    mask_regions,
    own_address_immutable,
    matches,
    checkouts_by_repository,
    export_tree,
    install_toolchain,
    link_libraries,
    pins_other_than,
    search_passes,
    source_blobs,
    sources_at,
    still_to_try,
    strip_metadata,
    submodules_at,
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


def placed_in(repo: Path, commit: str) -> dict:
    """Where each submodule `commit` records can be read from - what a caller works out once and
    passes to everything that needs it."""
    return submodules_at(repo, commit, checkouts_by_repository(repo))


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


def located(repo: Path, commit: str, name: str, recorded_path: str | None = None) -> tuple[str, str] | None:
    """The answer for one contract, asked on its own."""
    return sources_at(repo, commit, [(name, recorded_path)])[(name, recorded_path)]


def git_searches(monkeypatch) -> list[list[str]]:
    """Every `git grep` run from here on, as the list it fills."""
    import deployment_recovery

    searches: list[list[str]] = []
    real = subprocess.run

    def run(command, *arguments, **options):
        if list(command[:2]) == ["git", "grep"]:
            searches.append(list(command))
        return real(command, *arguments, **options)

    monkeypatch.setattr(deployment_recovery.subprocess, "run", run)
    return searches


def superproject_with_a_dependency(tmp_path: Path) -> tuple[Path, str]:
    """A superproject declaring `Own` in `src/`, with `Token` declared in its `lib/dep` submodule."""
    dependency = tmp_path / "dependency"
    (dependency / "src").mkdir(parents=True)
    git(dependency, "init", "-q", "-b", "main")
    git(dependency, "config", "user.email", "t@t")
    git(dependency, "config", "user.name", "test")
    (dependency / "src" / "Token.sol").write_text("pragma solidity 0.8.30;\ncontract Token {}\n")
    git(dependency, "add", "-A")
    git(dependency, "commit", "-qm", "the contract lives here")

    superproject = tmp_path / "superproject"
    (superproject / "src").mkdir(parents=True)
    git(superproject, "init", "-q", "-b", "main")
    git(superproject, "config", "user.email", "t@t")
    git(superproject, "config", "user.name", "test")
    (superproject / "src" / "Own.sol").write_text("pragma solidity 0.8.30;\ncontract Own {}\n")
    git(superproject, "-c", "protocol.file.allow=always", "submodule", "--quiet", "add", str(dependency), "lib/dep")
    git(superproject, "add", "-A")
    git(superproject, "commit", "-qm", "with the dependency")
    return superproject, git_output(superproject, "rev-parse", "HEAD")


def test_a_contract_declared_inside_a_submodule_is_found(tmp_path):
    # Most of harbor's closure lives in bao-base, and `MintableBurnableERC20_v1` is DEFINED there and
    # deployed from harbor - the constructor is what makes each deployment differ. A search that
    # cannot see into a dependency reports "no candidate built what is deployed" about a contract
    # whose source it never looked at.
    superproject, commit = superproject_with_a_dependency(tmp_path)

    assert located(superproject, commit, "Token") == ("lib/dep/src/Token.sol", "Token")


def test_a_source_of_the_superproject_is_named_by_its_blob_id(tmp_path):
    superproject, commit, _, _ = repository_with_submodule(tmp_path)

    named = source_blobs(superproject, commit, ["src/Own.sol"], placed_in(superproject, commit))

    assert named == {"src/Own.sol": git_output(superproject, "rev-parse", f"{commit}:src/Own.sol")}


def test_a_source_inside_a_submodule_is_read_at_the_commit_the_superproject_records(tmp_path):
    # The failure this prevents: reading the submodule's tip instead, so the record says what the
    # dependency looks like today rather than what the build actually read.
    superproject, commit, recorded_blob, later_blob = repository_with_submodule(tmp_path)

    inside = ["lib/dependency/src/Dependency.sol"]
    named = source_blobs(superproject, commit, inside, placed_in(superproject, commit))

    assert named == {"lib/dependency/src/Dependency.sol": recorded_blob}
    assert recorded_blob != later_blob, "the dependency did move on, so the two are distinguishable"


def test_every_submodule_the_commit_records_is_named(tmp_path):
    # The cheap check compares these as well as the sources: a tree with identical sources but a
    # different dependency builds different bytecode.
    superproject, commit, _, _ = repository_with_submodule(tmp_path)

    placed = submodules_at(superproject, commit, checkouts_by_repository(superproject))

    recorded = git_output(superproject, "rev-parse", f"{commit}:lib/dependency")
    assert {path: at for path, (at, _) in placed.items()} == {"lib/dependency": recorded}
    assert placed["lib/dependency"][1] == superproject / "lib" / "dependency", "read from where it sits"


# ── which compiler built what is deployed, from the deployed code itself ───────────────────────────
#
# The commit fixes the settings only as far as `foundry.toml` pins them, and the compiler comes from
# the pragma plus whatever versions are installed - so a rebuild here can pick a different one from the
# deploy's and still be asked to match. The deployed code says which one built it: solc writes the
# version into the CBOR trailer. Measured on two real contracts, `BaoPauser_v1` and
# `Aggregator_stETH_USD_mainnet`, whose trailers both end
# `64736f6c634300081e0033` - the key `solc`, a 3-byte string header `0x43`, then `00 08 1e`.


def with_solc_trailer(body: bytes, version: tuple[int, int, int] = (0, 8, 30)) -> bytes:
    """`body` as solc leaves it: a CBOR map carrying an ipfs hash and the compiler, then its length."""
    trailer = b"\xa2\x64ipfs\x58\x22" + bytes(34) + b"\x64solc\x43" + bytes(version)
    return body + trailer + len(trailer).to_bytes(2, "big")


def test_the_compiler_is_read_from_the_deployed_code_s_trailer():
    assert compiler_in(with_solc_trailer(bytes.fromhex("6080604052"))) == "0.8.30"


def test_a_different_compiler_is_read_as_itself():
    assert compiler_in(with_solc_trailer(bytes.fromhex("6080604052"), (0, 7, 6))) == "0.7.6"


def test_code_with_no_trailer_names_no_compiler():
    # Not a guess and not a default: nothing to pin a rebuild to, which the caller has to be told.
    assert compiler_in(bytes.fromhex("6080604052")) is None


def test_a_trailer_that_does_not_name_solc_names_no_compiler():
    trailer = b"\xa1\x64ipfs\x58\x22" + bytes(34)
    assert compiler_in(bytes.fromhex("6080604052") + trailer + len(trailer).to_bytes(2, "big")) is None


def test_a_source_the_commit_does_not_have_is_reported(tmp_path):
    # A record missing a source would be a record that cannot be rebuilt, so this cannot pass quietly.
    superproject, commit, _, _ = repository_with_submodule(tmp_path)

    with pytest.raises(FileNotFoundError) as missing:
        source_blobs(superproject, commit, ["src/Own.sol", "src/NeverExisted.sol"], placed_in(superproject, commit))

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

    assert mask_regions(onchain, refs) == mask_regions(built, refs)


def test_masking_leaves_everything_outside_the_declared_regions_alone():
    # The whole point: a difference anywhere else must still be visible. Masking too widely is how a
    # comparison starts passing over contracts it should reject.
    a = bytes.fromhex("aabbccdd")
    b = bytes.fromhex("aabbcc00")

    assert mask_regions(a, {}) != mask_regions(b, {})
    assert mask_regions(a, {"1": [{"start": 3, "length": 1}]}) == mask_regions(b, {"1": [{"start": 3, "length": 1}]})


# ── the verdict itself ────────────────────────────────────────────────────────────────────────────
#
# `matches` decides whether a baseline is TRUE. A fault here writes a wrong commit into the record,
# which everything downstream then believes - the worst failure this tool has. Its parts were tested
# before it was; these are the composition.


def test_the_deployed_code_matches_the_artefact_that_built_it():
    body = bytes.fromhex("6080604052" + "00" * 40)

    agreed, immutables = matches(with_trailer(body), artefact(body))

    assert agreed and immutables == []


def unlinked(runtime: bytes, at: int, library: str = "Config_v1") -> dict:
    """`runtime` as a build that has not been linked leaves it: the 20 bytes where a library address
    goes replaced by solc's `__$<34 hex>$__` placeholder, and a linkReferences entry saying where.

    Placeholders are not hex, which is the whole difficulty - `bytes.fromhex` refuses them."""
    placeholder = "__$" + "0" * 34 + "$__"
    text = runtime.hex()
    built = "0x" + text[: at * 2] + placeholder + text[(at + 20) * 2 :]
    return {
        "bytecode": {"object": "0x6080"},
        "deployedBytecode": {
            "object": built,
            "immutableReferences": {},
            "linkReferences": {f"src/{library}.sol": {library: [{"start": at, "length": 20}]}},
        },
    }


def linkable(creation: bytes, runtime: bytes, at_creation: int, at_runtime: int, library: str = "Config_v1") -> dict:
    """An unlinked build of a contract that links one library, in both halves of the artefact."""
    placeholder = "__$" + "0" * 34 + "$__"

    def unlinked(code: bytes, at: int) -> str:
        text = code.hex()
        return "0x" + text[: at * 2] + placeholder + text[(at + 20) * 2 :]

    references = {f"src/{library}.sol": {library: [{"start": 0, "length": 20}]}}
    creation_refs = json.loads(json.dumps(references))
    creation_refs[f"src/{library}.sol"][library] = [{"start": at_creation, "length": 20}]
    runtime_refs = json.loads(json.dumps(references))
    runtime_refs[f"src/{library}.sol"][library] = [{"start": at_runtime, "length": 20}]
    return {
        "bytecode": {"object": unlinked(creation, at_creation), "linkReferences": creation_refs},
        "deployedBytecode": {
            "object": unlinked(runtime, at_runtime),
            "immutableReferences": {},
            "linkReferences": runtime_refs,
        },
    }


def test_the_creation_code_is_linked_with_the_address_the_deployed_code_carries():
    # A build that links a library cannot be constructed as it stands, and the address is not a guess:
    # the deployed RUNTIME code carries it at the offsets the artefact itself declares.
    creation = bytes.fromhex("6080" + "33" * 60)
    runtime = bytes.fromhex("6040" + "44" * 60)
    deployed = bytearray(runtime)
    deployed[10:30] = bytes.fromhex("cd" * 20)

    linked, addresses = link_libraries(linkable(creation, runtime, 25, 10), bytes(deployed))

    assert addresses == {"src/Config_v1.sol:Config_v1": "0x" + "cd" * 20}
    assert linked is not None
    assert bytes.fromhex(linked[2:])[25:45] == bytes.fromhex("cd" * 20), "filled into the creation code"


def test_a_library_the_deployed_code_never_names_is_refused_rather_than_guessed():
    # It appears in the creation code and nowhere in the runtime code, so nothing in this contract
    # says what address it had. Filling one in would be invention.
    creation = bytes.fromhex("6080" + "33" * 60)
    artefact = linkable(creation, bytes.fromhex("6040" + "44" * 60), 25, 10)
    artefact["deployedBytecode"]["linkReferences"] = {}

    linked, addresses = link_libraries(artefact, bytes.fromhex("6040" + "44" * 60))

    assert linked is None
    assert addresses == {}


def test_a_build_that_links_a_library_is_compared_with_the_address_left_out():
    # An external library's address is a deployment input, exactly like an immutable: the same source
    # linked against a different deployment of the same library is still the source that built this.
    # harbor's Minter_v1 and Minter_v2 both carry one, and it is why the whole run stopped.
    body = bytes.fromhex("6080604052" + "11" * 60)
    deployed = bytearray(body)
    deployed[10:30] = bytes.fromhex("aa" * 20)

    agreed, immutables = matches(with_trailer(bytes(deployed)), unlinked(body, at=10))

    assert agreed, "the address is masked out, so it cannot decide the comparison"
    assert immutables == []


def test_a_build_that_links_a_library_still_fails_on_a_difference_outside_the_address():
    # The masking must not turn into a blanket pass: everything outside the linked address is still
    # compared byte for byte.
    body = bytes.fromhex("6080604052" + "11" * 60)
    deployed = bytearray(body)
    deployed[10:30] = bytes.fromhex("aa" * 20)
    deployed[45] = 0x22

    agreed, _ = matches(with_trailer(bytes(deployed)), unlinked(body, at=10))

    assert not agreed


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

    explained, unexplained = differences(body, body, [own_address_immutable(spans((5, 32)), SELF)])

    assert (explained, unexplained) == ([], [])


def test_a_difference_that_is_the_contract_s_own_address_is_explained():
    # The one immutable a local construction cannot reproduce: `address(this)` is where the code runs,
    # and the construction runs somewhere else. OpenZeppelin's UUPS `__self` is exactly this.
    deployed = bytes.fromhex("6080604052") + word(bytes.fromhex(SELF[2:]))
    produced = bytes.fromhex("6080604052") + word(bytes.fromhex("11" * 20))

    explained, unexplained = differences(deployed, produced, [own_address_immutable(spans((5, 32)), SELF)])

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

    explained, unexplained = differences(deployed, produced, [own_address_immutable(spans((5, 32)), SELF)])

    assert explained == []
    assert len(unexplained) == 1
    assert feed.hex() in unexplained[0] and other.hex() in unexplained[0], "both values are named"


def test_a_difference_outside_every_immutable_region_is_never_explained():
    # Nothing about a deployment can move a byte the constructor did not write. This must reject
    # however many immutables the artefact declares.
    deployed = bytes.fromhex("6080604052")
    produced = bytes.fromhex("60806040ff")

    explained, unexplained = differences(deployed, produced, [own_address_immutable(spans((0, 4)), SELF)])

    assert explained == []
    assert len(unexplained) == 1 and "outside" in unexplained[0]


def test_a_length_difference_is_never_explained():
    explained, unexplained = differences(bytes(20), bytes(21), [])

    assert explained == []
    assert len(unexplained) == 1 and "length" in unexplained[0]


def test_several_immutables_are_judged_one_at_a_time():
    # A contract has many - the pauser six, an aggregator ten - and one being explicable says nothing
    # about the next. Mixing them into a single verdict is what masking did.
    feed = bytes.fromhex("cfe54b5cd566ab89272946f602d76ea879cab4a8")
    deployed = word(bytes.fromhex(SELF[2:])) + word(feed)
    produced = word(bytes.fromhex("11" * 20)) + word(bytes.fromhex("22" * 20))

    explained, unexplained = differences(deployed, produced, [own_address_immutable(spans((0, 32), (32, 32)), SELF)])

    assert len(explained) == 1 and len(unexplained) == 1


# ── not building the same thing twice, without losing a contract to it ────────────────────────────


def test_a_build_is_not_repeated_for_a_contract_already_compared_against_it():
    # The saving: twenty aggregators share a deploy and so share candidates, and many of those commits
    # read identical build inputs. Building each again proves nothing new about the same contracts.
    tried = {}

    assert still_to_try(tried, "inputs-a", ["1/0xaa", "1/0xbb"]) == ["1/0xaa", "1/0xbb"]
    assert still_to_try(tried, "inputs-a", ["1/0xaa", "1/0xbb"]) == []


def test_a_contract_that_has_not_seen_a_build_gets_it_even_when_someone_else_has():
    # The defect this exists to stop, and it cost 52 of 97. Recording the build id alone - a set of
    # builds already done - skips the commit for a contract whose window opens on it later, so the
    # contract is reported as "no candidate built what is deployed" having been compared against
    # nothing at all. `Aggregator_stETH_AAPL_arbitrum` recovers at 3a108494df when run on its own.
    tried = {}
    still_to_try(tried, "inputs-a", ["1/0xaa"])

    assert still_to_try(tried, "inputs-a", ["1/0xbb"]) == ["1/0xbb"]


def test_only_the_contracts_that_have_not_seen_it_are_returned():
    # A mixed set is the ordinary case once a run is under way: the build is worth doing for the one
    # that has not seen it, and the comparison is not worth repeating for the one that has.
    tried = {}
    still_to_try(tried, "inputs-a", ["1/0xaa"])

    assert still_to_try(tried, "inputs-a", ["1/0xaa", "1/0xbb"]) == ["1/0xbb"]


def test_a_different_build_is_a_different_question_for_the_same_contract():
    tried = {}
    still_to_try(tried, "inputs-a", ["1/0xaa"])

    assert still_to_try(tried, "inputs-b", ["1/0xaa"]) == ["1/0xaa"]


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

    found, unusable = artefact_for(tmp_path, "src/megaeth/Aggregator.sol", "Aggregator_megaeth")

    assert found is not None, unusable
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

    assert artefact_for(tmp_path, "src/Foo.sol", "Foo")[0] is None


def test_two_artefacts_claiming_one_source_are_refused_not_picked_between(tmp_path):
    # The flat artefact namespace this fleet already collides in. Returning either would be arbitrary,
    # and arbitrary here means comparing against the wrong contract's bytecode.
    artefact_declaring(tmp_path / "Foo.sol", "Foo", "src/Foo.sol")
    artefact_declaring(tmp_path / "elsewhere" / "Foo.sol", "Foo", "src/Foo.sol")

    assert artefact_for(tmp_path, "src/Foo.sol", "Foo")[0] is None


def test_an_artefact_that_will_not_parse_is_reported_rather_than_passed_over(tmp_path):
    # Every file looked at is named for the contract being recovered, so one that cannot be read may
    # be the very build wanted. Skipping it made a broken BUILD read as "nothing built that source" -
    # a statement about the sources, and the wrong thing to go and investigate.
    (tmp_path / "Foo.sol").mkdir()
    (tmp_path / "Foo.sol" / "Foo.json").write_text("{ this is not json")

    found, unusable = artefact_for(tmp_path, "src/Foo.sol", "Foo")

    assert found is None
    assert "does not parse" in unusable, unusable
    assert "Foo.json" in unusable, unusable


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

    assert located(repo, early, "Foo") == ("src/Foo.sol", "Foo")
    assert located(repo, "HEAD", "Foo") == ("src/moved/Foo.sol", "Foo")


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

    assert located(repo, early, "New", recorded_path="src/New.sol") == ("src/Old.sol", "Old")


def test_the_name_wins_over_the_path_when_both_could_answer(repo):
    # The path is only a fallback. A file that MOVED still declares the recorded name, and following
    # the path instead would answer with wherever the path happens to point.
    (repo / "src").mkdir(exist_ok=True)
    (repo / "src" / "Foo.sol").write_text("contract Foo {}\n")
    git(repo, "add", "-A")
    subprocess.run(["git", "commit", "-qm", "add Foo"], cwd=repo, check=True, capture_output=True)

    assert located(repo, "HEAD", "Foo", recorded_path="src/somewhere/else/Foo.sol") == ("src/Foo.sol", "Foo")


def test_a_contract_absent_from_that_commit_is_not_guessed_at(repo):
    assert located(repo, "HEAD", "NeverExisted") is None
    assert located(repo, "HEAD", "NeverExisted", recorded_path="src/NeverExisted.sol") is None


def test_a_contract_in_a_dependency_is_found_there_like_anywhere_else(repo):
    # A contract defined in a dependency is defined there; nothing about `lib/` makes it a different
    # kind of source. harbor records 46 contracts whose source is in bao-base, and skipping `lib/`
    # made every one of them unfindable.
    (repo / "lib" / "dep" / "src").mkdir(parents=True)
    (repo / "lib" / "dep" / "src" / "Pauser.sol").write_text("contract Pauser {}\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "vendored dependency")

    assert located(repo, "HEAD", "Pauser") == ("lib/dep/src/Pauser.sol", "Pauser")


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

    assert located(repo, "HEAD", "Aggregator") is None


def test_the_declaration_decides_not_the_filename(repo):
    # A `Foo.sol` holding `contract Bar` must not answer for `Foo`, and the file that does declare it
    # must be found however it is named.
    (repo / "src").mkdir(exist_ok=True)
    (repo / "src" / "Foo.sol").write_text("contract Bar {}\n")
    (repo / "src" / "Elsewhere.sol").write_text("contract Foo {}\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "misleading filename")

    assert located(repo, "HEAD", "Foo") == ("src/Elsewhere.sol", "Foo")


def as_posix_reads_it(pattern: str) -> str:
    """`pattern` as an engine with no GNU extensions reads it, which is the engine macOS git uses.

    `git grep --extended-regexp` compiles the pattern with whatever `regcomp` the platform provides.
    On Linux that is glibc's, which accepts the GNU extensions; on macOS it is the system one, which
    does not, and git adds Apple's `REG_ENHANCED` - the flag that would restore them - only to patterns
    compiled WITHOUT `REG_EXTENDED` (`compat/regcomp_enhanced.c`), so an extended pattern never gets
    it. `re_format(7)` then reads a backslash before an ordinary character as "that character taken as
    an ordinary character, as if the `\\` had not been present", which is what this drops. So a pattern
    leaning on a GNU extension passes every test on Linux and finds nothing at all on a Mac."""
    special = "^.[$()|*+?{\\"
    return re.sub(r"\\(.)", lambda escape: escape.group(0 if escape.group(1) in special else 1), pattern)


def test_the_search_works_on_a_posix_engine_and_not_only_on_glibc(repo, monkeypatch):
    # `contract F0\b` is a word boundary to glibc and the literal `contract F0b` to macOS, so every
    # contract went unfound there and every row read "no candidate built what is deployed" - a search
    # that never looked, reported as one that found nothing. The pattern has to mean the same to both.
    monkeypatch.setattr(
        "deployment_recovery.declaration_of",
        lambda *contract_types: as_posix_reads_it(declaration_of(*contract_types)),
    )

    assert located(repo, "HEAD", "F0") == ("src/f0.sol", "F0")


def test_the_name_ends_where_an_identifier_ends_and_nowhere_else(repo):
    # What the boundary is FOR: `Foo` is not declared by `contract Foob`, and `contract Foo` with its
    # brace on the next line is still a declaration. Answering with `Foob` would be worse than
    # answering with nothing - it compares a deployed contract against a different one's build.
    (repo / "src" / "Foo.sol").write_text("contract Foo {}\n")
    (repo / "src" / "Foob.sol").write_text("contract Foob {}\n")
    (repo / "src" / "FooBar.sol").write_text("contract FooBar is Foo {}\n")
    (repo / "src" / "Split.sol").write_text("contract Split\n{\n}\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "names that share a prefix")

    assert located(repo, "HEAD", "Foo") == ("src/Foo.sol", "Foo")
    assert located(repo, "HEAD", "Foob") == ("src/Foob.sol", "Foob")
    assert located(repo, "HEAD", "Split") == ("src/Split.sol", "Split")


# ── every name at a commit, in one search ──────────────────────────────────────────────────────────
#
# The search walks the whole commit, submodules included, and the walk is the cost: 0.36s a name on the
# aggregators, thirteen names waiting at a commit, 578s of one run. Asked for all 142 of its names at once
# it measured twice one name's cost, so every question at a commit shares one search, and the line each
# match prints says which name it declares.


def test_every_name_at_a_commit_is_located_by_one_search(tmp_path, monkeypatch):
    superproject, commit = superproject_with_a_dependency(tmp_path)
    searches = git_searches(monkeypatch)

    answers = sources_at(superproject, commit, [("Own", None), ("Token", None), ("NeverExisted", None)])

    assert answers == {
        ("Own", None): ("src/Own.sol", "Own"),
        ("Token", None): ("lib/dep/src/Token.sol", "Token"),
        ("NeverExisted", None): None,
    }
    assert len(searches) == 1, searches


def test_asking_about_no_names_searches_nothing(repo, monkeypatch):
    searches = git_searches(monkeypatch)

    assert sources_at(repo, "HEAD", []) == {}
    assert searches == []


def test_names_sharing_a_prefix_in_one_search_each_find_their_own_file(repo):
    # Asked together, a line has to go to the name it declares and to no other. No file here is named
    # after its contract, so a tie-break by filename cannot hide a line given to the wrong name.
    (repo / "src" / "A.sol").write_text("contract Foo {}\n")
    (repo / "src" / "B.sol").write_text("contract Foob {}\n")
    (repo / "src" / "C.sol").write_text("contract FooBar is Foo {}\n")
    (repo / "src" / "D.sol").write_text("contract Split\n{\n}\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "names that share a prefix, in files named for none of them")

    assert sources_at(repo, "HEAD", [("Foo", None), ("Foob", None), ("Split", None)]) == {
        ("Foo", None): ("src/A.sol", "Foo"),
        ("Foob", None): ("src/B.sol", "Foob"),
        ("Split", None): ("src/D.sol", "Split"),
    }


def test_one_search_answers_a_found_a_missing_an_ambiguous_and_a_renamed_contract(repo, monkeypatch):
    # Each question keeps its own rules after the shared search: a unique declaration answers, two files
    # declaring one name refuse, a name declared nowhere answers None, and a renamed contract is followed
    # by its recorded path.
    (repo / "src" / "A.sol").write_text("contract Foo {}\n")
    for chain in ("mainnet", "megaeth"):
        (repo / "src" / chain).mkdir(parents=True, exist_ok=True)
        (repo / "src" / chain / "Aggregator.sol").write_text("contract Aggregator {}\n")
    (repo / "src" / "Old.sol").write_text("contract Old {\n    uint256 constant A = 1;\n    // body\n}\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "before the rename")
    early = git_output(repo, "rev-parse", "HEAD")
    (repo / "src" / "New.sol").write_text("contract New {\n    uint256 constant A = 1;\n    // body\n}\n")
    (repo / "src" / "Old.sol").unlink()
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "rename it")
    searches = git_searches(monkeypatch)

    answers = sources_at(
        repo, early, [("Foo", None), ("NeverExisted", None), ("Aggregator", None), ("New", "src/New.sol")]
    )

    assert answers == {
        ("Foo", None): ("src/A.sol", "Foo"),
        ("NeverExisted", None): None,
        ("Aggregator", None): None,
        ("New", "src/New.sol"): ("src/Old.sol", "Old"),
    }
    assert len(searches) == 1, searches


# ── when it was deployed, and when the commit was made ────────────────────────────────────────────


def test_the_creation_block_is_found_from_a_late_estimate_in_a_handful_of_calls():
    # The manifest's `deploymentTime` is the deploy SCRIPT's clock, written after the broadcast, so a
    # block found from it usually sits just past the truth - fifteen blocks past, for BaoPauser, whose
    # manifest was 2m55s late. Walking back from a close estimate costs a handful of calls; a blind
    # bisect of the whole chain would cost ~25, which is what this exists to avoid.
    asked: list[int] = []

    def has_code(block: int) -> bool:
        asked.append(block)
        return block >= 24706244

    assert creation_block(has_code, near=24706259, ceiling=24800000) == 24706244
    assert len(asked) <= 12, f"took {len(asked)} calls: {asked}"


def test_a_contract_created_after_the_estimate_is_found_by_searching_forward():
    # The estimate can also land BEFORE the creation, when the manifest's time is not the time the
    # transaction landed: two mainnet aggregators record a time whose block holds no code while the
    # code is there now. The search is symmetric - double forward until a block has the code, then
    # bisect - so a distance of a hundred thousand blocks costs tens of calls, not one per block.
    asked: list[int] = []

    def has_code(block: int) -> bool:
        asked.append(block)
        return block >= 24512345

    assert creation_block(has_code, near=24401569, ceiling=26000000) == 24512345
    assert len(asked) <= 45, f"took {len(asked)} calls: {asked}"


def test_a_contract_present_at_the_floor_cannot_be_bracketed():
    # Every block searched has the code, so the creation block is below the range and guessing the
    # floor would record a block the contract did not exist at.
    assert creation_block(lambda block: True, near=1000, floor=900, ceiling=2000) is None


def test_a_contract_with_no_code_by_the_ceiling_is_not_found():
    # Nothing up to the head of the chain has the code, so there is no creation block to record - and
    # the walk forward reaches that verdict by doubling to the ceiling, not by stepping to it.
    asked: list[int] = []

    def has_code(block: int) -> bool:
        asked.append(block)
        return False

    assert creation_block(has_code, near=1000, ceiling=26000000) is None
    assert len(asked) <= 30, f"took {len(asked)} calls: {asked}"


def test_a_commit_timestamp_is_utc_whatever_the_committer_s_clock_said(repo):
    # `%cI` carries the committer's local offset, so two identical commits made in different zones
    # would record differently. Unix seconds formatted as UTC removes the question.
    found = commit_timestamp(repo, "HEAD")

    assert found.endswith("Z"), found
    assert found == "2026-03-24T00:00:00Z", "the fixture's last commit, in UTC"


# ── the worktrees, which touch the repository ─────────────────────────────────────────────────────


def locked_project(at: Path, dependencies: str = "") -> Path:
    """A uv project with its lock already written, as a tracked `pyproject.toml`/`uv.lock` pair gives
    an export. Locked here rather than shipped as a fixture file so the lock matches the uv in use."""
    at.mkdir(parents=True, exist_ok=True)
    (at / "pyproject.toml").write_text(
        f'[project]\nname = "fixture"\nversion = "0"\nrequires-python = ">=3.9"\ndependencies = [{dependencies}]\n'
    )
    subprocess.run(["uv", "lock"], cwd=at, capture_output=True, text=True, check=True)
    return at


def test_an_exact_pragma_that_is_not_the_deployed_compiler_rules_the_commit_out(tmp_path):
    # Knowable without building: a source pinning one version cannot have been built by another, and
    # harbor's MintableBurnableERC20_v1 moved 0.8.28 -> 0.8.30, so most of a 1204-commit search was
    # forge being asked to do the impossible.
    assert pins_other_than("pragma solidity 0.8.28;\ncontract A {}\n", "0.8.30") == "0.8.28"
    assert pins_other_than("pragma solidity =0.8.28;\n", "0.8.30") == "0.8.28"


def test_an_exact_pragma_that_matches_rules_nothing_out(tmp_path):
    assert pins_other_than("pragma solidity 0.8.30;\n", "0.8.30") is None


def test_a_pragma_that_is_a_RANGE_rules_nothing_out(tmp_path):
    # A range admits many versions, and deciding which without solc's own resolver would be guessing.
    # It is not a mismatch, so it is not this filter's business.
    for spec in ("^0.8.0", ">=0.8.20 <0.9.0", ">0.8.0", "~0.8.20"):
        assert pins_other_than(f"pragma solidity {spec};\n", "0.8.30") is None, spec


def test_a_source_with_no_pragma_rules_nothing_out(tmp_path):
    assert pins_other_than("contract A {}\n", "0.8.30") is None


def test_a_tree_whose_lock_pins_a_toolchain_gets_it_installed(tmp_path):
    # `forge build` resolves a declared vyper compiler before compiling anything, and `.venv` is
    # untracked so no export carries one. The lock IS tracked, so the export can rebuild it.
    tree = locked_project(tmp_path / "tree")

    assert install_toolchain(tree) is None
    assert (tree / ".venv").is_dir(), "the environment the lock pins is there to be found"


def test_a_tree_with_nothing_pinned_is_left_alone(tmp_path):
    # Most repositories pin no python toolchain at all, and must not pay for one.
    tree = tmp_path / "tree"
    (tree / "src").mkdir(parents=True)

    assert install_toolchain(tree) is None
    assert not (tree / ".venv").exists()


def test_an_install_that_fails_is_returned_rather_than_raised(tmp_path):
    # A tree with no vyper in it builds perfectly well without this, so a failure is worth reporting
    # beside the build error that follows if one does - not worth ending the run over.
    tree = locked_project(tmp_path / "tree")
    (tree / "uv.lock").write_text("this is not a lock\n")

    failure = install_toolchain(tree)

    assert failure is not None
    assert failure.strip() != "", "the reader is told what uv said"


def test_the_export_holds_the_commit_and_its_dependency_at_the_recorded_version(tmp_path):
    # The dependency's tip has moved on since. What a build reads has to be the commit the
    # superproject RECORDS, or the rebuild says what the dependency looks like today rather than
    # what was deployed.
    superproject, commit, _, _ = repository_with_submodule(tmp_path)

    at = tmp_path / "exported"
    assert export_tree(superproject, commit, at, checkouts_by_repository(superproject)) == []

    assert (at / "src" / "Own.sol").is_file(), "the superproject's own source"
    assert (at / "lib" / "dependency" / "src" / "Dependency.sol").read_text() == (
        "// the version the superproject records\n"
    )


def test_the_export_is_files_only_and_carries_no_repository(tmp_path):
    # A `.git` anywhere under the export is what let `forge build` reach back into the repository it
    # came from: a linked worktree shares that repository's `.git/modules`, and forge settling a
    # dependency re-points every shared gitdir at the export, which is then deleted.
    superproject, commit, _, _ = repository_with_submodule(tmp_path)

    at = tmp_path / "exported"
    export_tree(superproject, commit, at, checkouts_by_repository(superproject))

    assert list(at.rglob(".git")) == []


def moved_dependency(tmp_path: Path) -> tuple[Path, str]:
    """A superproject recording `lib/gone` and `lib/kept` as the SAME repository, with `lib/gone` no
    longer checked out.

    harbor's shape at a deployed commit: `@bao/` pointed at `lib/bao-base-audit-2025-07` and
    `@bao-factory/` at `lib/bao-factory`, both since moved, and both the same repository as a
    checkout that is still there."""
    dependency = tmp_path / "dependency"
    (dependency / "src").mkdir(parents=True)
    git(dependency, "init", "-q", "-b", "main")
    git(dependency, "config", "user.email", "t@t")
    git(dependency, "config", "user.name", "test")
    (dependency / "src" / "D.sol").write_text("// the version the superproject records\n")
    git(dependency, "add", "-A")
    git(dependency, "commit", "-qm", "recorded")

    superproject = tmp_path / "superproject"
    (superproject / "src").mkdir(parents=True)
    git(superproject, "init", "-q", "-b", "main")
    git(superproject, "config", "user.email", "t@t")
    git(superproject, "config", "user.name", "test")
    (superproject / "src" / "Own.sol").write_text("// the superproject's own source\n")
    for path in ("lib/gone", "lib/kept"):
        git(superproject, "-c", "protocol.file.allow=always", "submodule", "--quiet", "add", str(dependency), path)
    git(superproject, "add", "-A")
    git(superproject, "commit", "-qm", "with the dependency twice")
    commit = git_output(superproject, "rev-parse", "HEAD")

    # The path the commit records, no longer on disk - the dependency moved after the deploy.
    shutil.rmtree(superproject / "lib" / "gone")
    return superproject, commit


def test_a_source_inside_a_moved_dependency_is_still_named(tmp_path):
    # Naming a build's inputs asks the same question exporting does - which store holds this commit -
    # and answering it by the recorded path ended a run with FileNotFoundError on a dependency that
    # had moved. One resolution, used by both.
    superproject, commit = moved_dependency(tmp_path)
    placed = submodules_at(superproject, commit, checkouts_by_repository(superproject))

    named = source_blobs(superproject, commit, ["lib/gone/src/D.sol"], placed)

    assert list(named) == ["lib/gone/src/D.sol"]
    assert named["lib/gone/src/D.sol"], "a blob id, read from wherever that commit actually lives"


def test_a_dependency_that_moved_is_exported_from_a_checkout_that_still_holds_it(tmp_path):
    # The recorded PATH says where a dependency once sat; the recorded URL says what it IS. A
    # checkout of the same repository holding the same commit gives the same bytes, so the build
    # gets what was deployed rather than a gap.
    superproject, commit = moved_dependency(tmp_path)

    at = tmp_path / "exported"
    failures = export_tree(superproject, commit, at, checkouts_by_repository(superproject))

    assert failures == [], failures
    assert (at / "lib" / "gone" / "src" / "D.sol").read_text() == "// the version the superproject records\n"


def test_a_checkout_is_matched_on_the_repository_not_on_how_its_remote_is_written(tmp_path):
    # One repository is named `git@host:org/repo.git`, `https://host/org/repo` and with a trailing
    # slash, depending on who cloned it. Matching the text would miss the checkout that has the
    # objects.
    superproject, commit = moved_dependency(tmp_path)
    kept = superproject / "lib" / "kept"
    plain = git_output(kept, "remote", "get-url", "origin")
    git(kept, "remote", "set-url", "origin", f"ssh://git@example.invalid/{Path(plain).name}.git")
    git(
        superproject,
        "config",
        "-f",
        ".gitmodules",
        "submodule.lib/gone.url",
        f"https://example.invalid/{Path(plain).name}/",
    )
    # Only .gitmodules: `add -A` would stage the removed checkout as a deleted gitlink, and the
    # commit would then not record the dependency this is about at all.
    git(superproject, "add", ".gitmodules")
    git(superproject, "commit", "-qm", "the same repository, written three ways")
    commit = git_output(superproject, "rev-parse", "HEAD")

    at = tmp_path / "exported"
    failures = export_tree(superproject, commit, at, checkouts_by_repository(superproject))

    assert failures == [], failures
    assert (at / "lib" / "gone" / "src" / "D.sol").is_file()


def test_a_checkout_that_is_present_but_lacks_the_commit_does_not_hide_one_that_has_it(tmp_path):
    # Being AT the recorded path is not what makes a checkout a source - holding the commit is.
    # harbor carries nine checkouts of forge-std at four commits, and their object stores genuinely
    # differ, so the one the commit names can be the one that cannot answer.
    dependency = tmp_path / "dependency"
    (dependency / "src").mkdir(parents=True)
    git(dependency, "init", "-q", "-b", "main")
    git(dependency, "config", "user.email", "t@t")
    git(dependency, "config", "user.name", "test")
    (dependency / "src" / "D.sol").write_text("// first\n")
    git(dependency, "add", "-A")
    git(dependency, "commit", "-qm", "first")

    superproject = tmp_path / "superproject"
    (superproject / "src").mkdir(parents=True)
    git(superproject, "init", "-q", "-b", "main")
    git(superproject, "config", "user.email", "t@t")
    git(superproject, "config", "user.name", "test")
    (superproject / "src" / "Own.sol").write_text("// own\n")
    # Cloned before the second commit exists, so its store can never hold it.
    git(superproject, "-c", "protocol.file.allow=always", "submodule", "--quiet", "add", str(dependency), "lib/stale")

    (dependency / "src" / "D.sol").write_text("// the version the superproject records\n")
    git(dependency, "add", "-A")
    git(dependency, "commit", "-qm", "second")
    wanted = git_output(dependency, "rev-parse", "HEAD")
    # Cloned after, so this one has it.
    git(superproject, "-c", "protocol.file.allow=always", "submodule", "--quiet", "add", str(dependency), "lib/fresh")

    # The superproject records the LATER commit at the path whose checkout stops short of it.
    git(superproject, "update-index", "--cacheinfo", f"160000,{wanted},lib/stale")
    git(superproject, "add", ".gitmodules", "src")
    git(superproject, "commit", "-qm", "recording a commit lib/stale does not hold")
    commit = git_output(superproject, "rev-parse", "HEAD")

    at = tmp_path / "exported"
    failures = export_tree(superproject, commit, at, checkouts_by_repository(superproject))

    assert failures == [], failures
    assert (at / "lib" / "stale" / "src" / "D.sol").read_text() == "// the version the superproject records\n"


def test_a_dependency_no_checkout_holds_is_reported_rather_than_fetched(tmp_path):
    # What is on disk is the whole of what a run may read. A remote could supply this commit, and
    # reaching for it would make a baseline depend on the network and on what that remote still
    # serves - so it would record here and fail to reproduce on a fresh checkout, which is exactly
    # what CI is.
    superproject, commit = moved_dependency(tmp_path)
    shutil.rmtree(superproject / "lib" / "kept")

    at = tmp_path / "exported"
    failures = export_tree(superproject, commit, at, checkouts_by_repository(superproject))

    # Both of them: removing the sibling leaves neither path with a store, and each is named.
    assert [failure.partition("@")[0] for failure in failures] == ["lib/gone", "lib/kept"], failures
    assert all("no checkout in this tree holds it" in failure for failure in failures), failures
    assert not (superproject / ".git" / "recovery-cache").exists(), "nothing was fetched"


def test_a_dependency_that_cannot_be_exported_is_named_rather_than_raised(tmp_path):
    # It may not be in the closure at all, so this is not fatal - but a build that does need it fails
    # naming the file, and the caller says both together.
    superproject, commit, _, _ = repository_with_submodule(tmp_path)
    shutil.rmtree(superproject / "lib" / "dependency")

    at = tmp_path / "exported"
    failures = export_tree(superproject, commit, at, checkouts_by_repository(superproject))

    assert len(failures) == 1, failures
    assert failures[0].startswith("lib/dependency@"), failures[0]
    # What was actually established, which is stronger than "not checked out here": every checkout
    # in the tree was asked, and none of them has this commit.
    assert "no checkout in this tree holds it" in failures[0], failures[0]
    assert (at / "src" / "Own.sol").is_file(), "the rest of the commit is still exported"
