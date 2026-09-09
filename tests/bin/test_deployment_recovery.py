"""Recovering a baseline: which commit, and does it produce what is on chain.

The two halves are separated because only one of them can be tested without a network and a compiler.
The comparison arithmetic - stripping the metadata trailer, masking immutables - is pure and is where
a mistake would silently produce a MATCH against the wrong contract, so it is tested exhaustively
here. Placing a worktree and compiling is proven by running it, in C0's report.

Every constant below came from the real recovery of `BaoPauser_v1` at 0xd8785d5C on 2026-03-21.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "bin"))

from deployment_recovery import candidate_commit, mask_immutables, strip_metadata  # noqa: E402


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
    assert mask_immutables(a, {"1": [{"start": 3, "length": 1}]}) == mask_immutables(b, {"1": [{"start": 3, "length": 1}]})


# ── choosing the candidate ────────────────────────────────────────────────────────────────────────


@pytest.fixture
def repo(tmp_path):
    """Three commits with known dates, so "what was HEAD when the deploy ran" has a right answer."""
    git(tmp_path, "init", "-q", "-b", "main")
    git(tmp_path, "config", "user.email", "t@t")
    git(tmp_path, "config", "user.name", "test")
    for n, when in enumerate(["2026-03-01T00:00:00", "2026-03-19T00:00:00", "2026-03-24T00:00:00"]):
        (tmp_path / f"f{n}.txt").write_text(str(n))
        git(tmp_path, "add", "-A")
        subprocess.run(
            ["git", "commit", "-qm", f"c{n}"],
            cwd=tmp_path,
            check=True,
            capture_output=True,
            env={"PATH": "/usr/bin:/bin", "HOME": str(tmp_path),
                 "GIT_AUTHOR_DATE": when, "GIT_COMMITTER_DATE": when,
                 "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
                 "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"},
        )
    return tmp_path


def test_the_candidate_is_the_last_commit_before_the_deploy(repo):
    # The measured pattern: the commit that RECORDS a deploy lands days after it, so the source that
    # was deployed is at the last commit BEFORE the deployment timestamp, not at or after it.
    found = candidate_commit(repo, "2026-03-21T13:44:18Z")

    assert found is not None
    subject = subprocess.run(
        ["git", "log", "-1", "--format=%s", found], cwd=repo, capture_output=True, text=True
    ).stdout.strip()
    assert subject == "c1", "the 2026-03-19 commit, not the 2026-03-24 one"


def test_a_deploy_older_than_the_repository_has_no_candidate(repo):
    # Better to say so than to hand back the oldest commit and let it be recorded as a baseline.
    assert candidate_commit(repo, "2020-01-01T00:00:00Z") is None
