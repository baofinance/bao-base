"""bin/deployment_records.py's second layer: what a record MEANS.

Built on a real git repository because the check that matters - "has this repo ever held this path" -
is a question about history, and a fixture that faked it would only confirm the assertion was written
to match the code. It is what separates a path that MOVED, which is the ordinary case since records
are historical, from a path this repo never had, which is harbor's `src/BaoPauser_v1.sol`.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "bin"))

from deployment_records import Entry, normalise  # noqa: E402

REMAPPINGS = """[profile.default]
src = "src"
remappings = [
  "@harbor/=src/",
  "@harbor-script/=script/",
  "@bao/=lib/bao-base/src/",
]
"""


def git(where: Path, *arguments: str) -> None:
    subprocess.run(["git", *arguments], cwd=where, capture_output=True, text=True, check=True)


@pytest.fixture
def repo(tmp_path):
    """A repo whose history holds `src/minter/Genesis_v1.sol` at its current path and
    `src/Moved.sol` only at an OLD path, so both states can be asked about."""
    git(tmp_path, "init", "-q", "-b", "main")
    git(tmp_path, "config", "user.email", "t@t")
    git(tmp_path, "config", "user.name", "test")
    (tmp_path / "foundry.toml").write_text(REMAPPINGS)
    (tmp_path / "src" / "minter").mkdir(parents=True)
    (tmp_path / "src" / "minter" / "Genesis_v1.sol").write_text("// one\n")
    (tmp_path / "src" / "Moved.sol").write_text("// two\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-qm", "one")
    # Moved.sol leaves its old path, which the record still names - the ordinary case.
    (tmp_path / "src" / "mainnet").mkdir()
    (tmp_path / "src" / "mainnet" / "Moved.sol").write_text("// two\n")
    (tmp_path / "src" / "Moved.sol").unlink()
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-qm", "move")
    return tmp_path


def entry(path: str | None, chain: str = "Mainnet") -> Entry:
    return Entry(
        address="0xAA",
        name="Foo",
        recorded_path=path,
        chain_id=1,
        recorded_chain_id=1,
        chain=chain,
        deployed_at=None,
        manifest="deployments/mainnet/x.json",
        section="implementations",
    )


def test_the_chain_is_lowercased_so_four_chains_have_four_spellings(repo):
    # Eight spellings for four chains were found across the aggregators' manifests. Lowercase is what
    # the directories and the source tree already use, so it agrees with everything else.
    settled, problems = normalise([entry("src/minter/Genesis_v1.sol", chain="MegaETH")], repo)

    assert settled[0].chain == "megaeth"
    assert problems == []


def test_a_bare_path_gains_the_prefix_its_repo_uses_for_that_directory(repo):
    settled, problems = normalise([entry("src/minter/Genesis_v1.sol")], repo)

    assert settled[0].normalised_path == "@harbor/minter/Genesis_v1.sol"
    assert settled[0].recorded_path == "src/minter/Genesis_v1.sol", "what the record says is preserved"
    assert problems == []


def test_a_path_that_has_since_moved_still_normalises(repo):
    # Records are historical: eleven of v3-oracles.json's paths name locations that no longer exist.
    # That is not a fault, and treating it as one would fail an entire manifest for being old.
    settled, problems = normalise([entry("src/Moved.sol")], repo)

    assert settled[0].normalised_path == "@harbor/Moved.sol"
    assert problems == [], "the path existed once; where it went is a later question"


def test_a_bare_path_this_repo_never_held_is_a_problem_not_a_guess(repo):
    # harbor records `src/BaoPauser_v1.sol` for a file in BAO-BASE's src. The prefix table maps it
    # cleanly to `@harbor/`, which is exactly why the table alone cannot be trusted: the answer would
    # be a well-formed lie. History is what refuses it.
    settled, problems = normalise([entry("src/BaoPauser_v1.sol")], repo)

    assert settled == []
    assert len(problems) == 1
    assert "has ever been in this repository" in problems[0].reason
    assert problems[0].entry.recorded_path == "src/BaoPauser_v1.sol", "the finding quotes the record"


def test_a_prefixed_path_is_left_exactly_as_written(repo):
    # 306 of harbor's 310 records are already prefixed. Re-deriving them would risk changing them.
    settled, problems = normalise([entry("@bao/MintableBurnableERC20_v1.sol")], repo)

    assert settled[0].normalised_path == "@bao/MintableBurnableERC20_v1.sol"
    assert problems == []


def test_a_path_no_remapping_covers_is_a_problem(repo):
    settled, problems = normalise([entry("contracts/Foo.sol")], repo)

    assert settled == []
    assert "no remapping in foundry.toml covers" in problems[0].reason


def test_an_entry_with_no_path_is_not_additionally_a_normalisation_failure(repo):
    # The reader already returns it as a gap - a deployed contract with no baseline. Reporting it
    # twice, in two vocabularies, is the duplication this whole model exists to remove.
    settled, problems = normalise([entry(None)], repo)

    assert len(settled) == 1 and settled[0].normalised_path is None
    assert problems == []


def test_a_path_in_a_dependency_normalises_through_its_own_prefix(repo):
    # This is the test that was missing, and its absence let `normalise` and `sources_at` hold opposite
    # answers to one question: `sources_at` searches `lib/` because a contract defined in a dependency
    # is defined there, while `normalise` refused to name any path inside one.
    #
    # `@bao/=lib/bao-base/src/` is exactly how harbor's 46 bao-base-sourced records are already
    # written, so refusing to produce that form made them unrepresentable.
    settled, problems = normalise([entry("lib/bao-base/src/Foo.sol")], repo)

    assert problems == [], problems
    assert settled[0].normalised_path == "@bao/Foo.sol"


def test_a_dependency_path_is_not_checked_against_this_repository_s_history(repo):
    # A submodule's files are never in the parent's history, so the "has this repo ever held it" rule
    # would reject every one of them. The prefix is unambiguous by construction there - it names the
    # dependency - so the history check is for THIS repo's own bare paths, which is what it was for.
    settled, problems = normalise([entry("lib/bao-base/src/NeverInThisRepo.sol")], repo)

    assert problems == []
    assert settled[0].normalised_path == "@bao/NeverInThisRepo.sol"
