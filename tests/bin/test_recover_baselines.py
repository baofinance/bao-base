"""Recovering baselines for many contracts in one run.

The recovery places one worktree per commit and builds each contract waiting there on its own.
Grouping them into a single `forge build` was cheaper and changed answers: forge writes no artefact for
any source in a build that fails, so one file that did not compile discarded every contract at that
commit. A contract's baseline has to be the same whether it is recovered alone or beside contracts
whose source does not compile at the same commit.

These tests drive the real recovery loop against a small repository with real builds. Only the chain is
replaced, because it is the one input a test cannot reach: the code at each address, the block each
contract was created in, and what running a constructor returns.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

BIN = Path(__file__).resolve().parents[2] / "bin"
sys.path.insert(0, str(BIN))

from deployment_baselines import key, read_baselines  # noqa: E402
from deployment_recovery import strip_metadata  # noqa: E402

ADDRESS_A = "0x" + "aa" * 20
ADDRESS_B = "0x" + "bb" * 20
DEPLOYED = "2026-01-03T00:00:00Z"


def load_recover_baselines():
    """The orchestration under test, imported by name.

    It was loaded by path through `importlib` while it lived in a hyphenated script that nothing could
    import - the same fact that made `verify-audit` spawn a process to reach it. Both are gone."""
    import recover_baselines

    return recover_baselines


def contract_source(name: str, value: int) -> str:
    return (
        "pragma solidity 0.8.30;\n"
        f"contract {name} {{\n"
        f"    function value() external pure returns (uint256) {{\n"
        f"        return {value};\n"
        "    }\n"
        "}\n"
    )


def commit(repo: Path, when: str, message: str) -> str:
    dated = {**os.environ, "GIT_AUTHOR_DATE": when, "GIT_COMMITTER_DATE": when}
    for arguments in (["add", "-A"], ["commit", "-qm", message]):
        subprocess.run(["git", *arguments], cwd=repo, check=True, capture_output=True, env=dated)
    return subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True, check=True
    ).stdout.strip()


def artefact_of(repo: Path, source: str, contract: str, scratch: Path) -> dict:
    """The whole artefact `contract` compiles to in the working tree now."""
    environment = {k: v for k, v in os.environ.items() if not k.startswith("FOUNDRY_") or k == "FOUNDRY_DIR"}
    out = scratch / f"out-{contract}"
    subprocess.run(
        ["forge", "build", source],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
        env={**environment, "FOUNDRY_OUT": str(out), "FOUNDRY_CACHE_PATH": str(scratch / f"cache-{contract}")},
    )
    return json.loads((out / Path(source).name / f"{contract}.json").read_text())


def runtime(repo: Path, source: str, contract: str, scratch: Path) -> bytes:
    """What `contract` compiles to in the working tree now: the code a deploy from this tree places."""
    return bytes.fromhex(artefact_of(repo, source, contract, scratch)["deployedBytecode"]["object"][2:])


class Chain:
    """Everything recovery reads from a chain, for contracts created at one moment.

    The fixture's contracts take no constructor arguments and have no immutables, so a constructor
    returns the runtime code its creation code carries, which is what `construct` returns."""

    def __init__(self, deployed: dict[str, bytes]):
        self.deployed = {address.lower(): code for address, code in deployed.items()}

    def code(self, address: str, chain: str) -> bytes | None:
        return self.deployed.get(address.lower())

    def deployment(self, address: str, chain: str, claimed: str) -> tuple[int, str]:
        return 100, DEPLOYED

    def construct(self, creation: str, chain: str, block: int) -> bytes | None:
        for code in self.deployed.values():
            if strip_metadata(code).hex() in creation.lower():
                return code
        return None


def test_one_uncompilable_source_does_not_hide_the_others_at_that_commit(tmp_path, monkeypatch):
    # Two contracts deployed from one tree. At the newest commit before their deploy, A's source is
    # exactly what was deployed and B's source does not compile. Built together they fail, and that
    # failure must not stand in for comparing A: A's baseline is that commit whatever happens to B.
    repo, scratch = tmp_path / "repo", tmp_path / "scratch"
    (repo / "src").mkdir(parents=True)
    scratch.mkdir()
    subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], check=True, capture_output=True)
    for setting, value in (("user.email", "t@t"), ("user.name", "test")):
        subprocess.run(["git", "config", setting, value], cwd=repo, check=True, capture_output=True)
    (repo / "foundry.toml").write_text('[profile.default]\nsrc = "src"\nlibs = []\nremappings = ["@fixture/=src/"]\n')
    manifest = repo / "deployments" / "mainnet" / "state.json"
    manifest.parent.mkdir(parents=True)
    manifest.write_text(
        json.dumps(
            {
                "network": "mainnet",
                "chainId": 1,
                "implementations": {
                    ADDRESS_A: {"contractSource": "src/A.sol", "contractType": "A", "deploymentTime": DEPLOYED},
                    ADDRESS_B: {"contractSource": "src/B.sol", "contractType": "B", "deploymentTime": DEPLOYED},
                },
            },
            indent=2,
        )
        + "\n"
    )

    (repo / "src" / "A.sol").write_text(contract_source("A", 1))
    (repo / "src" / "B.sol").write_text(contract_source("B", 2))
    deployed_b = runtime(repo, "src/B.sol", "B", scratch)
    earlier = commit(repo, "2026-01-01T00:00:00+00:00", "A and B both compile")

    (repo / "src" / "A.sol").write_text(contract_source("A", 11))
    deployed_a = runtime(repo, "src/A.sol", "A", scratch)
    (repo / "src" / "B.sol").write_text("pragma solidity 0.8.30;\ncontract B { function broken( }\n")
    latest = commit(repo, "2026-01-02T00:00:00+00:00", "A is what was deployed; B no longer compiles")

    recover = load_recover_baselines()
    chain = Chain({ADDRESS_A: deployed_a, ADDRESS_B: deployed_b})
    monkeypatch.setattr(recover, "_deployed_code", chain.code)
    monkeypatch.setattr(recover, "_deployment", chain.deployment)
    monkeypatch.setattr(recover, "_construct", chain.construct)
    monkeypatch.chdir(repo)

    recover.run(repo, say=recover.Printer(0), write=True)

    record = read_baselines(repo)
    assert key(1, ADDRESS_B) in record, "B compiles at the earlier commit, which built what was deployed"
    assert record[key(1, ADDRESS_B)].commit == earlier
    assert key(1, ADDRESS_A) in record, "A was never compared at the commit where B failed to compile beside it"
    assert record[key(1, ADDRESS_A)].commit == latest


# ── every contract that was not recorded, gathered where a reader will see it ──────────────────────
#
# A contract can drop out at four different places before the search even starts - its manifest names
# no contract, it has no deployment time, its code cannot be read, its creation block cannot be found -
# and each of those prints one line and continues. In a real run those lines sit eighty lines above the
# end, interleaved with the progress listing, and the closing tally says only "76 of 83 recovered": the
# other seven exist as an arithmetic gap and nothing else. Measured on the aggregators, that gap held
# four contracts whose manifests disagree about their name and two whose creation block was not found.
#
# So the run ends with every unrecorded contract and its reason, in one place.

ADDRESS_C = "0x" + "cc" * 20
ADDRESS_D = "0x" + "dd" * 20


def test_every_contract_that_was_not_recorded_is_listed_with_its_reason_at_the_end(tmp_path, monkeypatch, capsys):
    # Four contracts, four outcomes: one recorded, one the manifest does not name, one whose creation
    # block the chain will not give, and one nothing in the repository builds.
    repo, scratch = tmp_path / "repo", tmp_path / "scratch"
    (repo / "src").mkdir(parents=True)
    scratch.mkdir()
    subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], check=True, capture_output=True)
    for setting, value in (("user.email", "t@t"), ("user.name", "test")):
        subprocess.run(["git", "config", setting, value], cwd=repo, check=True, capture_output=True)
    (repo / "foundry.toml").write_text('[profile.default]\nsrc = "src"\nlibs = []\nremappings = ["@fixture/=src/"]\n')
    manifest = repo / "deployments" / "mainnet" / "state.json"
    manifest.parent.mkdir(parents=True)
    manifest.write_text(
        json.dumps(
            {
                "network": "mainnet",
                "chainId": 1,
                "implementations": {
                    ADDRESS_A: {"contractSource": "src/A.sol", "contractType": "A", "deploymentTime": DEPLOYED},
                    # No contractType: two manifests disagreeing about a name leave exactly this.
                    ADDRESS_B: {"contractSource": "src/B.sol", "deploymentTime": DEPLOYED},
                    ADDRESS_C: {"contractSource": "src/C.sol", "contractType": "C", "deploymentTime": DEPLOYED},
                    ADDRESS_D: {"contractSource": "src/D.sol", "contractType": "D", "deploymentTime": DEPLOYED},
                },
            },
            indent=2,
        )
        + "\n"
    )
    for name, value in (("A", 1), ("B", 2), ("C", 3), ("D", 4)):
        (repo / "src" / f"{name}.sol").write_text(contract_source(name, value))
    deployed_a = runtime(repo, "src/A.sol", "A", scratch)
    deployed_c = runtime(repo, "src/C.sol", "C", scratch)
    commit(repo, "2026-01-01T00:00:00+00:00", "every contract's source")

    # D's deployed code is not what any commit here builds.
    deployed_d = runtime(repo, "src/D.sol", "D", scratch).replace(b"\x60\x04", b"\x60\x05")

    recover = load_recover_baselines()
    chain = Chain({ADDRESS_A: deployed_a, ADDRESS_C: deployed_c, ADDRESS_D: deployed_d})
    monkeypatch.setattr(recover, "_deployed_code", chain.code)
    # C's creation block cannot be found, which in a real run is an RPC that will not answer for it.
    monkeypatch.setattr(
        recover,
        "_deployment",
        lambda address, chain_name, claimed: None if address.lower() == ADDRESS_C else (100, DEPLOYED),
    )
    monkeypatch.setattr(recover, "_construct", chain.construct)
    monkeypatch.chdir(repo)

    recover.run(repo, say=recover.Printer(0), write=True)

    printed = capsys.readouterr().out
    summary = printed[printed.rindex("not recorded") :]
    assert ADDRESS_B in summary, "the manifest names no contract for it, so it was never looked for"
    assert "names no contract" in summary
    assert ADDRESS_C in summary, "its creation block could not be found, so it was never searched for"
    assert "creation block" in summary
    assert ADDRESS_D in summary, "it was searched for and nothing built it"
    assert ADDRESS_A not in summary, "it was recorded, so it is not among the failures"
    assert "3 not recorded:" in printed, "all three are gathered under one heading"
    assert "1 of 4 recovered" in printed, "and the tally reconciles with it: 1 recorded, 3 listed, 4 described"

    # A row has to say WHERE the entry it is complaining about lives: a fleet has many state files, and
    # "this address is broken" sends the reader to grep for it.
    assert summary.count("deployments/mainnet/state.json") == 3, "every row names the state file holding it"

    # And "nothing built it" has to say what was actually looked at, or it reads as a dead end rather
    # than as a search that can be widened.
    unmatched = next(line for line in summary.splitlines() if ADDRESS_D in line)
    assert DEPLOYED in unmatched, "the deploy time, which decides which commits are candidates"
    assert "1 distinct build" in unmatched, "and how many distinct builds it was actually compared against"
    assert "every ref" in summary, "the search is `git log --all`, not a branch, and says so"
    assert "1 commit" in summary, "with the size of the space it covered"


# ── built by the compiler the deployed code names ──────────────────────────────────────────────────
#
# A commit fixes the compiler only as far as its pragma and foundry.toml do: the aggregators pin 0.8.30
# exactly, but bao-base's sources are mostly ranges, so a rebuild takes whatever version is installed
# and can differ from the one the deploy used while being asked to match its bytecode. The deployed
# code says which built it - solc writes the version into its CBOR trailer - so the rebuild is pinned
# to that, and the artefact is checked to have been built by it.


def test_the_build_is_pinned_to_the_compiler_the_deployed_code_names(monkeypatch, tmp_path):
    recover = load_recover_baselines()
    invoked = {}

    class Done:
        returncode = 0
        stdout = ""
        stderr = ""

    def record(command, **kwargs):
        invoked["command"] = command
        return Done()

    monkeypatch.setattr(recover.subprocess, "run", record)

    recover._build(tmp_path, "src/A.sol", tmp_path / "out", "0.8.30")

    assert "--use" in invoked["command"], "the version is pinned, not left to whatever is installed"
    assert invoked["command"][invoked["command"].index("--use") + 1] == "0.8.30"


def test_a_deployed_contract_naming_no_compiler_is_reported_not_guessed(tmp_path, monkeypatch, capsys):
    # A contract whose code carries no trailer names no compiler. Recovering it anyway would record a
    # compiler that merely happens to be installed here, which is the claim this record exists to stop.
    repo, scratch = tmp_path / "repo", tmp_path / "scratch"
    (repo / "src").mkdir(parents=True)
    scratch.mkdir()
    subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], check=True, capture_output=True)
    for setting, value in (("user.email", "t@t"), ("user.name", "test")):
        subprocess.run(["git", "config", setting, value], cwd=repo, check=True, capture_output=True)
    (repo / "foundry.toml").write_text('[profile.default]\nsrc = "src"\nlibs = []\nremappings = ["@fixture/=src/"]\n')
    manifest = repo / "deployments" / "mainnet" / "state.json"
    manifest.parent.mkdir(parents=True)
    manifest.write_text(
        json.dumps(
            {
                "network": "mainnet",
                "chainId": 1,
                "implementations": {
                    ADDRESS_A: {"contractSource": "src/A.sol", "contractType": "A", "deploymentTime": DEPLOYED}
                },
            },
            indent=2,
        )
        + "\n"
    )
    (repo / "src" / "A.sol").write_text(contract_source("A", 1))
    deployed_a = runtime(repo, "src/A.sol", "A", scratch)
    commit(repo, "2026-01-01T00:00:00+00:00", "the contract")

    recover = load_recover_baselines()
    # Its trailer removed: the code is otherwise exactly what was built.
    from deployment_recovery import strip_metadata

    chain = Chain({ADDRESS_A: strip_metadata(deployed_a)})
    monkeypatch.setattr(recover, "_deployed_code", chain.code)
    monkeypatch.setattr(recover, "_deployment", chain.deployment)
    monkeypatch.setattr(recover, "_construct", chain.construct)
    monkeypatch.chdir(repo)

    recover.run(repo, say=recover.Printer(0), write=True)

    printed = capsys.readouterr().out
    assert key(1, ADDRESS_A) not in read_baselines(repo), "nothing is recorded for it"
    assert "names no compiler" in printed, "and the reason is said, not left as a silent miss"


def test_a_contract_two_manifests_disagree_about_names_both_of_them(tmp_path, monkeypatch, capsys):
    # The row has to name every manifest describing the contract, not just the one the reader kept:
    # when two disagree, the kept one is as likely to be the innocent file. Measured on the MegaETH
    # aggregators, whose row named v3-aggregators.json where the disagreement was with v4-oracles.json.
    repo, scratch = tmp_path / "repo", tmp_path / "scratch"
    (repo / "src").mkdir(parents=True)
    scratch.mkdir()
    subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], check=True, capture_output=True)
    for setting, value in (("user.email", "t@t"), ("user.name", "test")):
        subprocess.run(["git", "config", setting, value], cwd=repo, check=True, capture_output=True)
    (repo / "foundry.toml").write_text('[profile.default]\nsrc = "src"\nlibs = []\nremappings = ["@fixture/=src/"]\n')
    (repo / "deployments" / "mainnet").mkdir(parents=True)
    for manifest, declared in (
        ("old.json", "A"),
        ("new.json", "Renamed"),
    ):
        (repo / "deployments" / "mainnet" / manifest).write_text(
            json.dumps(
                {
                    "network": "mainnet",
                    "chainId": 1,
                    "implementations": {
                        ADDRESS_A: {
                            "contractSource": f"src/{declared}.sol",
                            "contractType": declared,
                            "deploymentTime": DEPLOYED,
                        }
                    },
                },
                indent=2,
            )
            + "\n"
        )
    # BOTH sources exist: a path no file in the repository has ever had is rejected before the merge,
    # as a record naming another repository's file, so the two descriptions would never meet.
    (repo / "src" / "A.sol").write_text(contract_source("A", 1))
    (repo / "src" / "Renamed.sol").write_text(contract_source("Renamed", 1))
    deployed_a = runtime(repo, "src/A.sol", "A", scratch)
    commit(repo, "2026-01-01T00:00:00+00:00", "the contract, under both of its names")

    recover = load_recover_baselines()
    chain = Chain({ADDRESS_A: deployed_a})
    monkeypatch.setattr(recover, "_deployed_code", chain.code)
    monkeypatch.setattr(recover, "_deployment", chain.deployment)
    monkeypatch.setattr(recover, "_construct", chain.construct)
    monkeypatch.chdir(repo)

    recover.run(repo, say=recover.Printer(0), write=True)

    printed = capsys.readouterr().out
    summary = printed[printed.rindex("not recorded") :]
    assert "deployments/mainnet/old.json" in summary, "the manifest the reader kept"
    assert "deployments/mainnet/new.json" in summary, "and the one it disagrees with"


# ── a screen is not a proof, so a contract stays in the search until it gets one ───────────────────
#
# The screen masks the immutables, so every tree whose only difference becomes an immutable matches it.
# `Aggregator_wBTC_USD_mainnet` screened at the commit before its deploy, where the staleness constant
# was 3600, while the chain holds 86400 — written by the commit two minutes AFTER the contract was
# created, from the dirty tree it was deployed from. A contract that leaves the search on a screen never
# reaches that commit, and is reported as though nothing in the repository built it.

STALENESS_COMMITTED = 3600
STALENESS_DEPLOYED = 86400

# Its immutable comes from a constant another file holds, so a commit can change what this contract
# builds without touching it — which is what makes two trees screen the same and prove differently.
IMMUTABLE_CONTRACT = (
    "pragma solidity 0.8.30;\n"
    'import {Staleness} from "@fixture/Staleness.sol";\n'
    "contract A {\n"
    "    uint256 public immutable staleness = Staleness.VALUE;\n"
    "}\n"
)


def staleness_library(value: int, note: str = "") -> str:
    return f"pragma solidity 0.8.30;\nlibrary Staleness {{\n    uint256 internal constant VALUE = {value};\n}}\n{note}"


def repository_with_an_immutable(tmp_path) -> tuple[Path, Path]:
    """A repository holding that contract, and nothing committed yet.

    Each test commits the trees it needs, because what separates them is which trees exist and when."""
    repo, scratch = tmp_path / "repo", tmp_path / "scratch"
    (repo / "src").mkdir(parents=True)
    scratch.mkdir()
    subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], check=True, capture_output=True)
    for setting, value in (("user.email", "t@t"), ("user.name", "test")):
        subprocess.run(["git", "config", setting, value], cwd=repo, check=True, capture_output=True)
    (repo / "foundry.toml").write_text('[profile.default]\nsrc = "src"\nlibs = []\nremappings = ["@fixture/=src/"]\n')
    manifest = repo / "deployments" / "mainnet" / "state.json"
    manifest.parent.mkdir(parents=True)
    manifest.write_text(
        json.dumps(
            {
                "network": "mainnet",
                "chainId": 1,
                "implementations": {
                    ADDRESS_A: {"contractSource": "src/A.sol", "contractType": "A", "deploymentTime": DEPLOYED}
                },
            },
            indent=2,
        )
        + "\n"
    )
    (repo / "src" / "A.sol").write_text(IMMUTABLE_CONTRACT)
    return repo, scratch


def tree_with_staleness(repo: Path, scratch: Path, value: int, note: str = "") -> tuple[dict, bytes]:
    """Put `value` in the constant, build, and return the artefact with the code a deploy from here holds.

    The artefact carries zeros where the immutable goes and the constructor writes the value into every
    reference to it before returning the code, so filling them is what the chain ends up with."""
    (repo / "src" / "Staleness.sol").write_text(staleness_library(value, note))
    artefact = artefact_of(repo, "src/A.sol", "A", scratch)
    references = artefact["deployedBytecode"]["immutableReferences"]
    assert references, "the fixture contract must carry an immutable, or the screen masks nothing"
    code = bytearray(bytes.fromhex(artefact["deployedBytecode"]["object"][2:]))
    for regions in references.values():
        for region in regions:
            code[region["start"] : region["start"] + region["length"]] = value.to_bytes(region["length"], "big")
    return artefact, bytes(code)


class ImmutableChain:
    """The chain for a contract whose immutable the tree's own constant decides.

    `construct` answers per BUILD, as the real one does: it runs the creation code a candidate commit
    produced, so the value written is THAT tree's constant rather than the chain's. A creation code
    carries its runtime verbatim, metadata trailer included, and the trailer hashes the sources of the
    tree it was built in — so the build that produced a given creation code is identified by it."""

    def __init__(self, onchain: bytes, builds: list[tuple[dict, bytes]]):
        self.onchain = onchain
        self.builds = builds

    def code(self, address: str, chain: str) -> bytes | None:
        return self.onchain if address.lower() == ADDRESS_A else None

    def deployment(self, address: str, chain: str, claimed: str) -> tuple[int, str]:
        return 100, DEPLOYED

    def construct(self, creation: str, chain: str, block: int) -> bytes:
        for artefact, produced in self.builds:
            if artefact["deployedBytecode"]["object"][2:].lower() in creation.lower():
                return produced
        raise AssertionError("no build in this fixture produced that creation code")


def test_a_screened_candidate_that_fails_the_constructor_stays_in_the_search(tmp_path, monkeypatch):
    # The tree committed BEFORE the deploy holds 3600 where the chain holds 86400, in an immutable: it
    # screens, and cannot be the answer. The tree committed AFTER holds 86400 — the dirty tree the
    # contract was deployed from, committed later. The first screen must not end the search.
    repo, scratch = repository_with_an_immutable(tmp_path)
    committed = tree_with_staleness(repo, scratch, STALENESS_COMMITTED)
    commit(repo, "2026-01-01T00:00:00+00:00", "staleness of an hour")
    deployed = tree_with_staleness(repo, scratch, STALENESS_DEPLOYED)
    later = commit(repo, "2026-01-04T00:00:00+00:00", "staleness of a day, committed after the deploy")

    recover = load_recover_baselines()
    chain = ImmutableChain(deployed[1], [committed, deployed])
    monkeypatch.setattr(recover, "_deployed_code", chain.code)
    monkeypatch.setattr(recover, "_deployment", chain.deployment)
    monkeypatch.setattr(recover, "_construct", chain.construct)
    monkeypatch.chdir(repo)

    recover.run(repo, say=recover.Printer(0), write=True)

    record = read_baselines(repo)
    assert key(1, ADDRESS_A) in record, "the commit after the deploy builds what is deployed, immutable included"
    assert record[key(1, ADDRESS_A)].commit == later, "and it is that commit, not the one that only screened"


def test_a_contract_proved_after_an_unproven_screen_is_not_also_reported_unproven(tmp_path, monkeypatch, capsys):
    # A failed constructor at one commit is a step in the search, not an outcome, so a contract proved
    # at a later one appears nowhere in the closing lists.
    repo, scratch = repository_with_an_immutable(tmp_path)
    committed = tree_with_staleness(repo, scratch, STALENESS_COMMITTED)
    commit(repo, "2026-01-01T00:00:00+00:00", "staleness of an hour")
    deployed = tree_with_staleness(repo, scratch, STALENESS_DEPLOYED)
    commit(repo, "2026-01-04T00:00:00+00:00", "staleness of a day, committed after the deploy")

    recover = load_recover_baselines()
    chain = ImmutableChain(deployed[1], [committed, deployed])
    monkeypatch.setattr(recover, "_deployed_code", chain.code)
    monkeypatch.setattr(recover, "_deployment", chain.deployment)
    monkeypatch.setattr(recover, "_construct", chain.construct)
    monkeypatch.chdir(repo)

    recover.run(repo, say=recover.Printer(0), write=True)

    printed = capsys.readouterr().out
    assert "1 of 1 recovered" in printed
    assert "not recorded:" not in printed, "it was recorded, so nothing is gathered as missing"
    assert "screened but NOT recorded" not in printed, "and the screen it failed on the way is not an outcome"


def test_a_contract_never_proved_names_every_commit_it_screened_at(tmp_path, monkeypatch, capsys):
    # Two commits screen and neither proves. "No candidate built what is deployed" would be untrue of a
    # contract whose code matched everywhere except an immutable, and the commits that came close are
    # what the reader needs: the next step is to look at that immutable, not to widen the search.
    repo, scratch = repository_with_an_immutable(tmp_path)
    first_build = tree_with_staleness(repo, scratch, STALENESS_COMMITTED)
    first = commit(repo, "2026-01-01T00:00:00+00:00", "staleness of an hour")
    # The same constant in a file whose bytes changed: a second distinct build, screening as the first
    # does, so there are two commits to name rather than one.
    second_build = tree_with_staleness(repo, scratch, STALENESS_COMMITTED, note="// a note added later\n")
    second = commit(repo, "2026-01-02T00:00:00+00:00", "a note in the constant's file")
    # What the chain holds was never committed, so nothing here can prove it.
    onchain = tree_with_staleness(repo, scratch, STALENESS_DEPLOYED)[1]

    recover = load_recover_baselines()
    chain = ImmutableChain(onchain, [first_build, second_build])
    monkeypatch.setattr(recover, "_deployed_code", chain.code)
    monkeypatch.setattr(recover, "_deployment", chain.deployment)
    monkeypatch.setattr(recover, "_construct", chain.construct)
    monkeypatch.chdir(repo)

    recover.run(repo, say=recover.Printer(0), write=True)

    printed = capsys.readouterr().out
    assert "1 screened but NOT recorded" in printed, "the remedy is the immutable, so it keeps its own block"
    summary = printed[printed.rindex("not recorded") :]
    row = next(line for line in summary.splitlines() if ADDRESS_A in line)
    assert first[:10] in row, "the first commit that came close"
    assert second[:10] in row, "and the second, so the reader sees every one of them"
    assert "constructor does not account for it" in row
    assert "no candidate built" not in row, "something did build it — everywhere but an immutable"


# ── nothing leaves a run without being named ──────────────────────────────────────────────────────
#
# A contract stops being a candidate at one of several stages: `review` cannot key its manifest entry,
# the chain will not answer for it, nothing in the repository builds it. Each stage narrows what the run
# works on, and the closing account has to carry every one of them - a count at the top of a long run is
# not a report, it is a number the reader has to go and explain for themselves. Measured on the
# aggregators: five entries in `megaeth/v4-oracles.json` carry `"address": ""`, and the run said
# `5 cannot be read, so cannot be recovered` without ever naming one of them.

NO_ADDRESS = "the record gives no address, so the contract cannot be identified"


def repository_of_oracles(tmp_path, oracles: dict) -> tuple[Path, Path]:
    """A repository whose manifest uses the `oracles` shape: keyed by label, with an `address` field.

    The only shape in which an entry can name no address at all - `implementations` is keyed BY address,
    so the gap cannot arise there - and the shape the aggregators' own placeholders are written in."""
    repo, scratch = tmp_path / "repo", tmp_path / "scratch"
    (repo / "src").mkdir(parents=True)
    scratch.mkdir()
    subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], check=True, capture_output=True)
    for setting, value in (("user.email", "t@t"), ("user.name", "test")):
        subprocess.run(["git", "config", setting, value], cwd=repo, check=True, capture_output=True)
    (repo / "foundry.toml").write_text('[profile.default]\nsrc = "src"\nlibs = []\nremappings = ["@fixture/=src/"]\n')
    manifest = repo / "deployments" / "mainnet" / "state.json"
    manifest.parent.mkdir(parents=True)
    manifest.write_text(
        json.dumps(
            {"schemaVersion": 1, "network": "mainnet", "chainId": 1, "deploymentTime": DEPLOYED, "oracles": oracles},
            indent=2,
        )
        + "\n"
    )
    return repo, scratch


def test_an_entry_with_no_address_is_named_in_the_closing_list(tmp_path, monkeypatch, capsys):
    # An entry review cannot key never reaches the search, so no later stage can report it - and it is
    # the one row whose identity cannot be an address, because not having one is what it is.
    repo, scratch = repository_of_oracles(
        tmp_path,
        {
            "A_USD": {"name": "A/USD", "address": ADDRESS_A, "contractPath": "src/A.sol:A"},
            "P_USD": {"name": "P/USD", "address": "", "contractPath": "src/Placeholder.sol:Placeholder"},
        },
    )
    (repo / "src" / "A.sol").write_text(contract_source("A", 1))
    (repo / "src" / "Placeholder.sol").write_text(contract_source("Placeholder", 2))
    deployed_a = runtime(repo, "src/A.sol", "A", scratch)
    commit(repo, "2026-01-01T00:00:00+00:00", "both sources")

    recover = load_recover_baselines()
    chain = Chain({ADDRESS_A: deployed_a})
    monkeypatch.setattr(recover, "_deployed_code", chain.code)
    monkeypatch.setattr(recover, "_deployment", chain.deployment)
    monkeypatch.setattr(recover, "_construct", chain.construct)
    monkeypatch.chdir(repo)

    recover.run(repo, say=recover.Printer(0), write=True)

    printed = capsys.readouterr().out
    assert key(1, ADDRESS_A) in read_baselines(repo), "the keyable one is recovered as usual"
    summary = printed[printed.rindex("not recorded") :]
    row = next(line for line in summary.splitlines() if "Placeholder" in line)
    assert "deployments/mainnet/state.json" in row, "the file a human has to edit"
    assert "src/Placeholder.sol" in row, "and what identifies it, since it has no address to be named by"
    assert NO_ADDRESS in row, "with the reason review already wrote, not a count"


def test_the_described_total_accounts_for_every_entry_the_manifests_hold(tmp_path, monkeypatch, capsys):
    # "manifests describe N" was recorded + unrecovered, leaving the unkeyable ones outside the
    # arithmetic: 83 described where the files held 88. A total that excludes what it could not read
    # cannot be reconciled against anything, which is how five entries stayed invisible.
    repo, scratch = repository_of_oracles(
        tmp_path,
        {
            "A_USD": {"name": "A/USD", "address": ADDRESS_A, "contractPath": "src/A.sol:A"},
            "P_USD": {"name": "P/USD", "address": "", "contractPath": "src/Placeholder.sol:Placeholder"},
        },
    )
    (repo / "src" / "A.sol").write_text(contract_source("A", 1))
    (repo / "src" / "Placeholder.sol").write_text(contract_source("Placeholder", 2))
    deployed_a = runtime(repo, "src/A.sol", "A", scratch)
    commit(repo, "2026-01-01T00:00:00+00:00", "both sources")

    recover = load_recover_baselines()
    chain = Chain({ADDRESS_A: deployed_a})
    monkeypatch.setattr(recover, "_deployed_code", chain.code)
    monkeypatch.setattr(recover, "_deployment", chain.deployment)
    monkeypatch.setattr(recover, "_construct", chain.construct)
    monkeypatch.chdir(repo)

    recover.run(repo, say=recover.Printer(0), write=True)

    printed = capsys.readouterr().out
    assert "manifests describe 2 deployed contracts" in printed, "both entries, including the unkeyable one"
    assert "1 that cannot be identified" in printed, "counted INSIDE the total it belongs to"


def test_a_drop_removes_the_contract_and_records_its_reason_in_one_call():
    # The shared call exists so that leaving the run and being accounted for cannot happen separately;
    # it also serves the stages BEFORE the search, where the key was never in the working set at all.
    from deployment_baselines import drop
    from deployment_records import Entry, Problem

    def entry_for(address: str | None) -> Entry:
        return Entry(
            address=address,
            name="A",
            recorded_path="src/A.sol",
            chain_id=1,
            recorded_chain_id=1,
            chain="mainnet",
            deployed_at=DEPLOYED,
            manifest="deployments/mainnet/state.json",
            section="oracles",
        )

    held, never_held = entry_for(ADDRESS_A), entry_for(None)
    pending = {key(1, ADDRESS_A): "the chain facts"}
    account: list[Problem] = []

    drop(pending, account, key(1, ADDRESS_A), held, "nothing built it")
    assert pending == {}, "out of the working set"
    assert [(problem.entry, problem.reason) for problem in account] == [(held, "nothing built it")]

    drop(pending, account, "deployments/mainnet/state.json:src/A.sol", never_held, NO_ADDRESS)
    assert [problem.reason for problem in account] == ["nothing built it", NO_ADDRESS], "a key the set never held"


def test_every_drop_reason_reaches_the_summary_from_every_stage(tmp_path, monkeypatch, capsys):
    # Three contracts leaving at three different stages - unkeyable, unreadable on chain, built by
    # nothing - and one closing list holding all three. The stages are independent code paths, and a
    # reader should not have to know which one applied to find out what happened.
    repo, scratch = repository_of_oracles(
        tmp_path,
        {
            "P_USD": {"name": "P/USD", "address": "", "contractPath": "src/Placeholder.sol:Placeholder"},
            "B_USD": {"name": "B/USD", "address": ADDRESS_B, "contractPath": "src/B.sol:B"},
            "C_USD": {"name": "C/USD", "address": ADDRESS_C, "contractPath": "src/C.sol:C"},
        },
    )
    for name, value in (("Placeholder", 1), ("B", 2), ("C", 3)):
        (repo / "src" / f"{name}.sol").write_text(contract_source(name, value))
    deployed_c = runtime(repo, "src/C.sol", "C", scratch).replace(b"\x60\x03", b"\x60\x09")
    commit(repo, "2026-01-01T00:00:00+00:00", "every source")

    recover = load_recover_baselines()
    # B's code cannot be read, which in a real run is an RPC that will not answer for it.
    chain = Chain({ADDRESS_C: deployed_c})
    monkeypatch.setattr(recover, "_deployed_code", chain.code)
    monkeypatch.setattr(recover, "_deployment", chain.deployment)
    monkeypatch.setattr(recover, "_construct", chain.construct)
    monkeypatch.chdir(repo)

    recover.run(repo, say=recover.Printer(0), write=True)

    printed = capsys.readouterr().out
    assert "3 not recorded:" in printed, "every stage's casualties under one heading"
    summary = printed[printed.rindex("not recorded") :]
    assert NO_ADDRESS in summary, "the entry review could not key"
    assert "deployed code unreadable" in summary, "the one the chain would not answer for"
    assert "no candidate built what is deployed" in summary, "and the one nothing built"


def test_the_entries_that_cannot_be_read_are_named_when_there_is_nothing_to_recover(tmp_path, monkeypatch, capsys):
    # The state a finished repository is in: every keyable contract already has a baseline, so the run
    # exits before the search - and that early exit is the one path on which nothing at all would be
    # said about the entries review could not key. The aggregators sat here, reporting five as a count.
    repo, scratch = repository_of_oracles(
        tmp_path,
        {"P_USD": {"name": "P/USD", "address": "", "contractPath": "src/Placeholder.sol:Placeholder"}},
    )
    (repo / "src" / "Placeholder.sol").write_text(contract_source("Placeholder", 2))
    commit(repo, "2026-01-01T00:00:00+00:00", "the source")

    recover = load_recover_baselines()
    chain = Chain({})
    monkeypatch.setattr(recover, "_deployed_code", chain.code)
    monkeypatch.setattr(recover, "_deployment", chain.deployment)
    monkeypatch.setattr(recover, "_construct", chain.construct)
    monkeypatch.chdir(repo)

    recover.run(repo, say=recover.Printer(0), write=True)

    printed = capsys.readouterr().out
    assert "1 not recorded:" in printed, "said even when there was nothing to search for"
    assert NO_ADDRESS in printed, "with the reason, which is the whole point of naming it"


# ── every count has rows, including the two the record itself raises ───────────────────────────────
#
# Two conditions are about the manifests and the record rather than about recovery: an address two
# manifests describe differently, and a baseline no manifest claims any more. `verify-audit` names both;
# this run reduced them to counts at the top. An orphan IS recorded, so it does not belong among the
# contracts with no baseline - it gets its own listing, and so does a disagreement.

ADDRESS_GHOST = "0x" + "ee" * 20


def orphan_baseline(address: str, name: str):
    """A baseline for an address no manifest mentions: what deleting a manifest entry leaves behind."""
    from deployment_baselines import Baseline

    return Baseline(
        chainId=1,
        chain="mainnet",
        address=address,
        contractType=name,
        source=f"src/{name}.sol",
        stateFiles=["deployments/mainnet/state.json"],
        commit="a" * 40,
        commitTimestamp=DEPLOYED,
        deployBlock=100,
        deployTimestamp=DEPLOYED,
        creationBytecodeKeccak256="b" * 64,
        compiler="0.8.30+commit.73712a01",
        settings={},
        sources={},
        submodules={},
    )


def test_a_baseline_no_manifest_claims_is_named_in_the_summary(tmp_path, monkeypatch, capsys):
    # harbor dropped eleven manifest entries in one commit, leaving eleven baselines nothing claimed and
    # nothing saying what built the contracts still on chain. A count cannot be acted on: the reader
    # needs the address and the name to know which entry was deleted.
    from deployment_baselines import add, write_baselines

    repo, scratch = repository_of_oracles(
        tmp_path, {"A_USD": {"name": "A/USD", "address": ADDRESS_A, "contractPath": "src/A.sol:A"}}
    )
    (repo / "src" / "A.sol").write_text(contract_source("A", 1))
    deployed_a = runtime(repo, "src/A.sol", "A", scratch)
    commit(repo, "2026-01-01T00:00:00+00:00", "the source")
    write_baselines(repo, add({}, orphan_baseline(ADDRESS_GHOST, "Ghost")))

    recover = load_recover_baselines()
    chain = Chain({ADDRESS_A: deployed_a})
    monkeypatch.setattr(recover, "_deployed_code", chain.code)
    monkeypatch.setattr(recover, "_deployment", chain.deployment)
    monkeypatch.setattr(recover, "_construct", chain.construct)
    monkeypatch.chdir(repo)

    recover.run(repo, say=recover.Printer(0), write=True)

    printed = capsys.readouterr().out
    assert ADDRESS_GHOST in printed.lower(), "the orphan is named, not counted"
    assert "Ghost" in printed, "with the contract it records, which is what says which entry went"


def test_every_count_in_the_head_line_has_rows_at_the_end(tmp_path, monkeypatch, capsys):
    # The rule itself, over one run holding all three: an entry review cannot key, an address two
    # manifests describe differently, and a baseline no manifest claims. Nothing may be counted that is
    # not also listed, whichever stage or side of the record it came from.
    from deployment_baselines import add, write_baselines

    repo, scratch = repository_of_oracles(
        tmp_path,
        {
            "A_USD": {"name": "A/USD", "address": ADDRESS_A, "contractPath": "src/A.sol:A"},
            "P_USD": {"name": "P/USD", "address": "", "contractPath": "src/Placeholder.sol:Placeholder"},
        },
    )
    for name, value in (("A", 1), ("Placeholder", 2)):
        (repo / "src" / f"{name}.sol").write_text(contract_source(name, value))
    # The file moved, and an older manifest still describes A where it was - both paths real in history,
    # which is the situation behind eleven of the aggregators' addresses.
    (repo / "src" / "moved").mkdir()
    (repo / "src" / "moved" / "A.sol").write_text(contract_source("A", 1))
    (repo / "deployments" / "mainnet" / "older.json").write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "network": "mainnet",
                "chainId": 1,
                "deploymentTime": DEPLOYED,
                "oracles": {"A_USD": {"name": "A/USD", "address": ADDRESS_A, "contractPath": "src/moved/A.sol:A"}},
            },
            indent=2,
        )
        + "\n"
    )
    deployed_a = runtime(repo, "src/A.sol", "A", scratch)
    commit(repo, "2026-01-01T00:00:00+00:00", "two descriptions of A, and a placeholder")
    write_baselines(repo, add({}, orphan_baseline(ADDRESS_GHOST, "Ghost")))

    recover = load_recover_baselines()
    chain = Chain({ADDRESS_A: deployed_a})
    monkeypatch.setattr(recover, "_deployed_code", chain.code)
    monkeypatch.setattr(recover, "_deployment", chain.deployment)
    monkeypatch.setattr(recover, "_construct", chain.construct)
    monkeypatch.chdir(repo)

    recover.run(repo, say=recover.Printer(0), write=True)

    printed = capsys.readouterr().out
    assert NO_ADDRESS in printed, "the entry that cannot be keyed"
    assert "src/moved/A.sol" in printed, "the disagreement, naming what each manifest says"
    assert "Ghost" in printed, "and the baseline no manifest claims"


# ── tier 2: rebuild what the record claims and compare the hash ────────────────────────────────────
#
# `creationBytecodeKeccak256` is the field that carries the chain proof forward, and nothing has ever
# read it. Checking it means rebuilding - minutes, not milliseconds - so it is asked for explicitly,
# where the per-build check settles for the inputs being unchanged. It selects over the RECORD, unlike
# `--only`, which filters the backlog and so cannot name a contract that already has a baseline.


def recorded_baseline(repo: Path, scratch: Path, commit: str, digest: str):
    """A baseline for A at `commit`, claiming `digest` as the hash of its creation bytecode."""
    from deployment_baselines import Baseline

    return Baseline(
        chainId=1,
        chain="mainnet",
        address=ADDRESS_A,
        contractType="A",
        source="src/A.sol",
        stateFiles=["deployments/mainnet/state.json"],
        commit=commit,
        commitTimestamp=DEPLOYED,
        deployBlock=100,
        deployTimestamp=DEPLOYED,
        creationBytecodeKeccak256=digest,
        compiler="0.8.30+commit.73712a01",
        settings={},
        sources={},
        submodules={},
    )


def a_recorded_repository(tmp_path):
    """A repository with A committed and nothing else, plus the creation hash a rebuild of it gives."""
    repo, scratch = repository_of_oracles(
        tmp_path, {"A_USD": {"name": "A/USD", "address": ADDRESS_A, "contractPath": "src/A.sol:A"}}
    )
    (repo / "src" / "A.sol").write_text(contract_source("A", 1))
    creation = artefact_of(repo, "src/A.sol", "A", scratch)["bytecode"]["object"]
    head = commit(repo, "2026-01-01T00:00:00+00:00", "the source")
    return repo, scratch, head, bytes.fromhex(creation[2:])


def test_a_rebuild_that_reproduces_the_recorded_hash_passes(tmp_path, monkeypatch, capsys):
    # The ordinary case: the commit still builds what the record says it built, so the proof the chain
    # gave once still holds without asking the chain again.
    from deployment_baselines import add, write_baselines

    repo, scratch, head, creation = a_recorded_repository(tmp_path)
    recover = load_recover_baselines()
    write_baselines(repo, add({}, recorded_baseline(repo, scratch, head, recover._keccak256(creation))))
    monkeypatch.chdir(repo)

    assert recover.run(repo, say=recover.Printer(0), reprove=True) == 0

    printed = capsys.readouterr().out
    assert "1 rebuilt" in printed, "it says what it did, so a silent pass cannot be mistaken for a skip"


def test_a_rebuild_that_does_not_reproduce_the_recorded_hash_is_reported(tmp_path, monkeypatch, capsys):
    # The failure the field exists to catch: the inputs still resolve, and what they build is not what
    # was deployed. Nothing else in the system would notice - the screen and the constructor proof ran
    # once, at recovery, and their verdict lives on in this hash alone.
    from deployment_baselines import add, write_baselines

    repo, scratch, head, _ = a_recorded_repository(tmp_path)
    recover = load_recover_baselines()
    write_baselines(repo, add({}, recorded_baseline(repo, scratch, head, "f" * 64)))
    monkeypatch.chdir(repo)

    assert recover.run(repo, say=recover.Printer(0), reprove=True) != 0, "a record that no longer rebuilds is a failure, not a note"

    printed = capsys.readouterr().out
    assert ADDRESS_A in printed.lower()
    assert "does not rebuild" in printed


def test_the_rebuild_is_not_run_unless_asked(tmp_path, monkeypatch, capsys):
    # The per-build path stays cheap. A plain run says nothing about the hash, however wrong it is -
    # rebuilding eighty-three baselines is minutes, which is why the inputs check exists instead.
    from deployment_baselines import add, write_baselines

    repo, scratch, head, _ = a_recorded_repository(tmp_path)
    recover = load_recover_baselines()
    write_baselines(repo, add({}, recorded_baseline(repo, scratch, head, "f" * 64)))
    monkeypatch.chdir(repo)

    assert recover.run(repo, say=recover.Printer(0)) == 0

    printed = capsys.readouterr().out
    assert "rebuilt" not in printed and "does not rebuild" not in printed


def test_a_selector_that_names_nothing_still_reports_what_is_wrong(tmp_path, monkeypatch, capsys):
    # `--only` filters the BACKLOG, so once a contract is recorded the selector matches nothing - and
    # that path returned before the listings, reporting less than the same run would without a selector.
    # A focused question is no reason to stop saying what is wrong: the head-line still counts the
    # entries that cannot be identified, and a count with no rows is what this section exists to remove.
    from deployment_baselines import add, write_baselines

    repo, scratch = repository_of_oracles(
        tmp_path,
        {
            "A_USD": {"name": "A/USD", "address": ADDRESS_A, "contractPath": "src/A.sol:A"},
            "P_USD": {"name": "P/USD", "address": "", "contractPath": "src/Placeholder.sol:Placeholder"},
        },
    )
    for name, value in (("A", 1), ("Placeholder", 2)):
        (repo / "src" / f"{name}.sol").write_text(contract_source(name, value))
    commit(repo, "2026-01-01T00:00:00+00:00", "both sources")
    write_baselines(repo, add({}, orphan_baseline(ADDRESS_A, "A")))

    recover = load_recover_baselines()
    chain = Chain({})
    monkeypatch.setattr(recover, "_deployed_code", chain.code)
    monkeypatch.setattr(recover, "_deployment", chain.deployment)
    monkeypatch.setattr(recover, "_construct", chain.construct)
    monkeypatch.chdir(repo)

    assert recover.run(repo, say=recover.Printer(0), only=f"mainnet/{ADDRESS_A}") == 1, "a selector naming nothing is still a mistyped argument"

    printed = capsys.readouterr().out
    assert NO_ADDRESS in printed, "and the run still says what it knows is wrong"


def two_recorded_baselines(tmp_path, recover):
    """A and B committed and recorded, where A's recorded hash is right and B's is not."""
    from dataclasses import replace

    from deployment_baselines import add

    repo, scratch = repository_of_oracles(
        tmp_path,
        {
            "A_USD": {"name": "A/USD", "address": ADDRESS_A, "contractPath": "src/A.sol:A"},
            "B_USD": {"name": "B/USD", "address": ADDRESS_B, "contractPath": "src/B.sol:B"},
        },
    )
    (repo / "src" / "A.sol").write_text(contract_source("A", 1))
    (repo / "src" / "B.sol").write_text(contract_source("B", 2))
    creation = artefact_of(repo, "src/A.sol", "A", scratch)["bytecode"]["object"]
    head = commit(repo, "2026-01-01T00:00:00+00:00", "both sources")
    sound = recorded_baseline(repo, scratch, head, recover._keccak256(bytes.fromhex(creation[2:])))
    broken = replace(sound, address=ADDRESS_B, contractType="B", source="src/B.sol", creationBytecodeKeccak256="f" * 64)
    return repo, add(add({}, sound), broken)


def test_only_chooses_which_baseline_is_reproved(tmp_path, monkeypatch, capsys):
    # The same selector, over the other set. `--only` narrows what is SEARCHED when recovering and what
    # is REBUILT when re-proving, which is one idea either way - and re-proving eighty-three baselines
    # to ask about one is the cost that makes a selector worth having.
    from deployment_baselines import write_baselines

    recover = load_recover_baselines()
    repo, baselines = two_recorded_baselines(tmp_path, recover)
    write_baselines(repo, baselines)
    monkeypatch.chdir(repo)

    assert recover.run(repo, say=recover.Printer(0), reprove=True, only=f"mainnet/{ADDRESS_A}") == 0, "the one asked about rebuilds to what it records"

    printed = capsys.readouterr().out
    assert "1 rebuilt" in printed, "one, not both — the broken one was not asked about"


def test_a_selector_naming_no_recorded_baseline_is_refused(tmp_path, monkeypatch, capsys):
    # A mistyped selector reads exactly like a clean run otherwise. The message differs from the
    # recovery one because the set does: there, a contract is missing from the backlog; here, from the
    # record.
    from deployment_baselines import write_baselines

    recover = load_recover_baselines()
    repo, baselines = two_recorded_baselines(tmp_path, recover)
    write_baselines(repo, baselines)
    monkeypatch.chdir(repo)

    assert recover.run(repo, say=recover.Printer(0), reprove=True, only="mainnet/0x" + "de" * 20) == 1

    printed = capsys.readouterr().out
    assert "no recorded baseline is" in printed, "named for the set it was looked for in"


# ── which state file a baseline came from ──────────────────────────────────────────────────────────
#
# Recovery knows it and throws it away: the entry it recovered from carries every manifest describing
# the address. Recorded, it gives provenance - and more usefully makes COVERAGE computable, since "is
# every contract this state file records now recorded" stops being a hand classification. It also
# derives the deploy tag's name, `deployments/<chain>/<file>.json` becoming `deploy/<chain>/<file>`.


def test_a_baseline_records_the_state_file_it_came_from(tmp_path, monkeypatch):
    repo, scratch = repository_of_oracles(
        tmp_path, {"A_USD": {"name": "A/USD", "address": ADDRESS_A, "contractPath": "src/A.sol:A"}}
    )
    (repo / "src" / "A.sol").write_text(contract_source("A", 1))
    deployed_a = runtime(repo, "src/A.sol", "A", scratch)
    commit(repo, "2026-01-01T00:00:00+00:00", "the source")

    recover = load_recover_baselines()
    chain = Chain({ADDRESS_A: deployed_a})
    monkeypatch.setattr(recover, "_deployed_code", chain.code)
    monkeypatch.setattr(recover, "_deployment", chain.deployment)
    monkeypatch.setattr(recover, "_construct", chain.construct)
    monkeypatch.chdir(repo)

    recover.run(repo, say=recover.Printer(0), write=True)

    assert read_baselines(repo)[key(1, ADDRESS_A)].stateFiles == ["deployments/mainnet/state.json"]


def test_a_contract_two_manifests_describe_records_both_state_files(tmp_path, monkeypatch):
    # 44 of the aggregators' addresses are in two manifests. Recording one of them would be the same
    # arbitrary pick the merge refuses to make elsewhere - and the wrong one would send a reader, or a
    # coverage check, to the file that does not claim it.
    repo, scratch = repository_of_oracles(
        tmp_path, {"A_USD": {"name": "A/USD", "address": ADDRESS_A, "contractPath": "src/A.sol:A"}}
    )
    (repo / "src" / "A.sol").write_text(contract_source("A", 1))
    (repo / "deployments" / "mainnet" / "older.json").write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "network": "mainnet",
                "chainId": 1,
                "deploymentTime": DEPLOYED,
                "oracles": {"A_USD": {"name": "A/USD", "address": ADDRESS_A, "contractPath": "src/A.sol:A"}},
            },
            indent=2,
        )
        + "\n"
    )
    deployed_a = runtime(repo, "src/A.sol", "A", scratch)
    commit(repo, "2026-01-01T00:00:00+00:00", "two manifests, one contract")

    recover = load_recover_baselines()
    chain = Chain({ADDRESS_A: deployed_a})
    monkeypatch.setattr(recover, "_deployed_code", chain.code)
    monkeypatch.setattr(recover, "_deployment", chain.deployment)
    monkeypatch.setattr(recover, "_construct", chain.construct)
    monkeypatch.chdir(repo)

    recover.run(repo, say=recover.Printer(0), write=True)

    assert read_baselines(repo)[key(1, ADDRESS_A)].stateFiles == [
        "deployments/mainnet/older.json",
        "deployments/mainnet/state.json",
    ]


# ── regeneration the tool owns ─────────────────────────────────────────────────────────────────────
#
# Recovery skips what is already recorded, so a wrong entry can only be corrected by deleting the file
# and running again - a manual deletion, which is the one operation the record's history should never
# need. `--regenerate` derives from the state files WITHOUT reading the existing record, and with
# `--write` replaces it; without, it reports every difference and touches nothing, which is a check CI
# can run because it cannot lose anything.


def a_repository_recording(tmp_path, existing):
    """A repo where A is recoverable at HEAD, with `existing` already written as its record."""
    repo, scratch = repository_of_oracles(
        tmp_path, {"A_USD": {"name": "A/USD", "address": ADDRESS_A, "contractPath": "src/A.sol:A"}}
    )
    (repo / "src" / "A.sol").write_text(contract_source("A", 1))
    deployed_a = runtime(repo, "src/A.sol", "A", scratch)
    head = commit(repo, "2026-01-01T00:00:00+00:00", "the source")
    (repo / "deployed.json").write_text(existing)
    return repo, deployed_a, head


def driven(recover, monkeypatch, repo, deployed_a):
    chain = Chain({ADDRESS_A: deployed_a})
    monkeypatch.setattr(recover, "_deployed_code", chain.code)
    monkeypatch.setattr(recover, "_deployment", chain.deployment)
    monkeypatch.setattr(recover, "_construct", chain.construct)
    monkeypatch.chdir(repo)


def test_regeneration_replaces_a_baseline_the_existing_record_holds_wrongly(tmp_path, monkeypatch):
    # The reason this exists: an ordinary run sees the address as recorded and leaves the wrong commit
    # standing. Correcting it by hand is the edit the record refuses to sanction.
    from deployment_baselines import add, write_baselines

    repo, deployed_a, head = a_repository_recording(tmp_path, "{}")
    write_baselines(repo, add({}, orphan_baseline(ADDRESS_A, "A")))
    recover = load_recover_baselines()
    driven(recover, monkeypatch, repo, deployed_a)

    assert recover.run(repo, say=recover.Printer(0), regenerate=True, write=True) == 0

    assert read_baselines(repo)[key(1, ADDRESS_A)].commit == head, "the tool corrected it, not a human"


def test_regeneration_never_reads_the_existing_record(tmp_path, monkeypatch):
    # Output depends only on the state files. Proved with a record that cannot be READ at all - the
    # state a mandatory new field leaves every existing record in, and precisely when regeneration is
    # the remedy: a mode that had to parse the old file first could not rescue it.
    repo, deployed_a, head = a_repository_recording(
        tmp_path, '{"schemaVersion": 1, "baselines": {"1/0x": {"chain": "mainnet"}}}\n'
    )
    recover = load_recover_baselines()
    driven(recover, monkeypatch, repo, deployed_a)

    assert recover.run(repo, say=recover.Printer(0), regenerate=True, write=True) == 0, "an unreadable record is what this replaces, not something it trips over"

    assert read_baselines(repo)[key(1, ADDRESS_A)].commit == head


def test_verify_reports_a_record_regeneration_would_change(tmp_path, monkeypatch, capsys):
    # The check half: regenerate in memory, say what differs, write nothing. A hand-edited record that
    # is internally consistent passes every other check in the system - this is what catches it.
    from deployment_baselines import add, write_baselines

    repo, deployed_a, head = a_repository_recording(tmp_path, "{}")
    write_baselines(repo, add({}, orphan_baseline(ADDRESS_A, "A")))
    before = (repo / "deployed.json").read_text()
    recover = load_recover_baselines()
    driven(recover, monkeypatch, repo, deployed_a)

    assert recover.run(repo, say=recover.Printer(0), regenerate=True) == 1, "a record regeneration would change is a failure, not a note"

    printed = capsys.readouterr().out
    assert "regeneration would change" in printed
    assert ADDRESS_A in printed.lower() and head[:10] in printed, "the address, and what it should say"
    assert (repo / "deployed.json").read_text() == before, "the check writes nothing"


def test_verify_says_an_unreadable_record_would_be_replaced(tmp_path, monkeypatch, capsys):
    # Asked as a question rather than performed as an action. A record that cannot be read is the case
    # this mode exists to repair, so the check must not trip over one - and "would regeneration change
    # this" has an obvious answer for it: entirely. Without this the `except` path ships untested, and
    # an exception tuple is only evaluated when something raises, so a missing name there stays green.
    repo, deployed_a, head = a_repository_recording(
        tmp_path, '{"schemaVersion": 1, "baselines": {"1/0x": {"chain": "mainnet"}}}\n'
    )
    recover = load_recover_baselines()
    driven(recover, monkeypatch, repo, deployed_a)

    assert recover.run(repo, say=recover.Printer(0), regenerate=True) == 1, "a record that cannot be read is a failure, and a repairable one"

    printed = capsys.readouterr().out
    assert "cannot be read" in printed and "would replace it" in printed
    assert (repo / "deployed.json").read_text().startswith('{"schemaVersion": 1'), "the check writes nothing"


def test_write_creates_the_missing_tags_locally(tmp_path, monkeypatch):
    # The repair CREATES them, rather than printing a checklist of `git tag` lines for a reader to
    # retype - the names are derived from the record, so nothing about them needed a human. Locally
    # only: what leaves the machine stays one decision the user makes knowingly.
    repo, deployed_a, head = a_repository_recording(tmp_path, '{"schemaVersion": 1, "baselines": {}}\n')
    recover = load_recover_baselines()
    driven(recover, monkeypatch, repo, deployed_a)

    recover.run(repo, say=recover.Printer(0), write=True)

    at_head = subprocess.run(
        ["git", "tag", "--points-at", head], cwd=repo, capture_output=True, text=True
    ).stdout.split()
    assert at_head == [f"deploy/mainnet/state@{head[:10]}"], "derived from the state file that claimed it"


def test_writing_again_does_not_pile_up_tags(tmp_path, monkeypatch):
    # Run twice on an unchanged tree and the second run has nothing to create: a commit any tag already
    # names is preserved, which is the same question `Review.untagged` asks.
    repo, deployed_a, head = a_repository_recording(tmp_path, '{"schemaVersion": 1, "baselines": {}}\n')
    recover = load_recover_baselines()
    driven(recover, monkeypatch, repo, deployed_a)
    recover.run(repo, say=recover.Printer(0), write=True)
    after_one = subprocess.run(
        ["git", "tag", "--points-at", head], cwd=repo, capture_output=True, text=True
    ).stdout.split()

    recover.run(repo, say=recover.Printer(0), write=True)

    after_two = subprocess.run(
        ["git", "tag", "--points-at", head], cwd=repo, capture_output=True, text=True
    ).stdout.split()
    assert after_two == after_one, "the second run created nothing"


def test_regeneration_returns_its_differences_as_data(tmp_path):
    # The caller reports the differences, so it is handed the differences themselves - not a transcript
    # to parse, and not an exit code that has forgotten which baseline moved. Two commands ask this
    # question and word the answer differently, which only one shared comparison can keep consistent.
    from deployment_baselines import add, write_baselines

    recover = load_recover_baselines()
    repo = tmp_path / "repo"
    repo.mkdir()
    write_baselines(repo, add({}, orphan_baseline(ADDRESS_A, "A")))

    difference = recover.regeneration_changes(repo, add({}, orphan_baseline(ADDRESS_B, "B")))

    assert difference.unreadable == "", "the committed record read cleanly"
    assert [(entry_key, was is None, now is None) for entry_key, was, now in difference.changes] == [
        (key(1, ADDRESS_A), False, True),
        (key(1, ADDRESS_B), True, False),
    ], "A recorded and not regenerated, B regenerated and not recorded - each named, in key order"


def test_an_unreadable_record_is_returned_as_a_difference_not_raised(tmp_path):
    # The one case regeneration exists to repair must not come back as an exception the caller has to
    # know to catch: it is an answer to "would this change", and the answer is "entirely".
    recover = load_recover_baselines()
    repo = tmp_path / "repo"
    repo.mkdir()
    (repo / "deployed.json").write_text('{"schemaVersion": 99, "baselines": {}}\n')

    difference = recover.regeneration_changes(repo, {})

    assert "99" in difference.unreadable, "it says what it found, not merely that something was wrong"
    assert difference.changes == [], "nothing can be compared against a record that cannot be read"
