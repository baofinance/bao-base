"""Recovering baselines for many contracts in one run.

`recover-baselines` builds every contract waiting at a commit in ONE `forge build`, because they share
most of their closure. That grouping may make a run cheaper; it must never change an answer. A
contract's baseline has to be the same whether it is recovered alone or beside contracts whose source
does not compile at the same commit.

These tests drive the real recovery loop against a small repository with real builds. Only the chain is
replaced, because it is the one input a test cannot reach: the code at each address, the block each
contract was created in, and what running a constructor returns.
"""

from __future__ import annotations

import importlib.util
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
    """The script under test, loaded by path because its file name is not a module name."""
    spec = importlib.util.spec_from_file_location("recover_baselines", BIN / "recover-baselines.py")
    module = importlib.util.module_from_spec(spec)
    # Registered before it runs: `dataclasses` resolves the script's string annotations through
    # `sys.modules[<module name>]`, where an unregistered module is None.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


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


def runtime(repo: Path, source: str, contract: str, scratch: Path) -> bytes:
    """What `contract` compiles to in the working tree now: the code a deploy from this tree places."""
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
    artefact = json.loads((out / Path(source).name / f"{contract}.json").read_text())
    return bytes.fromhex(artefact["deployedBytecode"]["object"][2:])


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
    monkeypatch.setattr(sys, "argv", ["recover-baselines", "--write"])

    recover.main()

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
    monkeypatch.setattr(sys, "argv", ["recover-baselines", "--write"])

    recover.main()

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
