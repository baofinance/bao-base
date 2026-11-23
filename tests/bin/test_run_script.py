"""Tests for bin/run-script.py — the forge script runner shared by every repo built on bao-base, and
the tooling that performs their deployments.

Almost none of these need a process or a fixture directory. The runner decides what to run in pure
functions — `forge_command`, `forge_arguments`, `deploy_state_dir`, `solidity_environment` — so a
test asserts the exact command and environment by calling them. The bash version this replaced could
only be checked by putting stub `forge` and `cast` executables on PATH and reading back what they
were handed, which tested the stubs as much as the runner.

Loaded by path: the file is named for the command it provides, and a hyphen is not importable.
"""

import importlib.util
import os
import pathlib
import re
import sys
from datetime import datetime, timezone

import pytest

_module_path = pathlib.Path(__file__).resolve().parents[2] / "bin" / "run-script.py"
_spec = importlib.util.spec_from_file_location("run_script", _module_path)
run_script = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
# Registered before executing: @dataclass resolves its own module through sys.modules, and a module
# loaded by path alone is not there, so the decorator fails at import with an unrelated-looking error.
sys.modules["run_script"] = run_script
_spec.loader.exec_module(run_script)

NOW = datetime(2026, 8, 25, 12, 30, 45, tzinfo=timezone.utc)


def _invocation(**overrides):
    """A minimal valid invocation, with the field under test overridden."""
    return run_script.Invocation(
        script_name=overrides.pop("script_name", "Deploy_Thing_mainnet"),
        salt=overrides.pop("salt", "harbor_v1"),
        network=overrides.pop("network", "mainnet"),
        **overrides,
    )


def _pair_index(command, first, second):
    """Index of `first` where `second` immediately follows it, or -1."""
    for i in range(len(command) - 1):
        if command[i] == first and command[i + 1] == second:
            return i
    return -1


# ── The default entry point ───────────────────────────────────────────────────────────────────────


def test_default_entry_point_passes_the_salt():
    # The default is bao-base's own entry point, Deployer.run(string): the salt prefix alone. The network reaches the
    # script in its environment, so nothing but the salt follows the signature.
    command = run_script.forge_command(_invocation())
    signature = _pair_index(command, "--sig", "run(string)")
    assert signature != -1, command
    assert command[signature + 2] == "harbor_v1"
    assert command[signature + 3] == "--rpc-url", command


def test_the_contract_and_the_file_are_named_the_same():
    # forge is given the path and the contract separately, so the two have to agree: a rename of one
    # is a rename of both, and disagreeing produces "source file not found" rather than anything
    # that points at the cause.
    command = run_script.forge_command(_invocation(script_name="Deploy_ETH_HarborYield_mainnet"))
    assert "script/Deploy_ETH_HarborYield_mainnet.s.sol" in command
    assert _pair_index(command, "--tc", "Deploy_ETH_HarborYield_mainnet") != -1


def test_a_passthrough_replaces_the_default_entry_point():
    # A script on a signature of its own is run this way. Adding the default as well would hand forge two --sig
    # flags, leaving it to run whichever it saw last.
    command = run_script.forge_command(_invocation(passthrough=("--sig", "run(string,bool)", "harbor_v1", "false")))
    assert command.count("--sig") == 1, command
    assert _pair_index(command, "--sig", "run(string,bool)") != -1, command


def test_a_passthrough_still_gets_the_mode_flags():
    # The caller overrides the entry point, not the run: --broadcast still has to reach forge.
    command = run_script.forge_command(_invocation(broadcast=True, passthrough=("--sig", "run()")))
    assert "--broadcast" in command


# ── Modes ─────────────────────────────────────────────────────────────────────────────────────────


def test_a_dry_run_does_not_broadcast():
    # The default has to be the harmless one: a runner that broadcast unless told otherwise would
    # make every mistyped command an on-chain one.
    assert "--broadcast" not in run_script.forge_arguments(_invocation())


def test_broadcast_adds_slow_and_verify():
    arguments = run_script.forge_arguments(_invocation(broadcast=True))
    assert {"--broadcast", "--slow", "--verify"} <= set(arguments)


def test_a_local_broadcast_neither_verifies_nor_paces():
    # There is no explorer to verify against on a local node, and no reason to pace transactions for
    # one that mines them instantly.
    arguments = run_script.forge_arguments(_invocation(local=True, broadcast=True))
    assert "--broadcast" in arguments
    assert "--verify" not in arguments
    assert "--slow" not in arguments


def test_local_impersonates_the_anvil_sender():
    arguments = run_script.forge_arguments(_invocation(local=True))
    assert "--unlocked" in arguments
    assert _pair_index(arguments, "--sender", run_script.ANVIL_SENDER) != -1


def test_an_explicit_account_replaces_the_impersonated_sender():
    # Naming an account means signing as it; also passing the impersonated default would leave forge
    # with two senders and no way for the caller to know which signed.
    arguments = run_script.forge_arguments(_invocation(local=True, account="deployer"))
    assert _pair_index(arguments, "--account", "deployer") != -1
    assert "--sender" not in arguments


def test_resume_is_forwarded():
    assert "--resume" in run_script.forge_arguments(_invocation(resume=True))


def test_ffi_is_always_enabled():
    # The deploy scripts shell out for address prediction, so a run without it fails partway rather
    # than at the start.
    assert "--ffi" in run_script.forge_arguments(_invocation())
    assert "--ffi" in run_script.forge_arguments(_invocation(local=True, broadcast=True))


def test_local_runs_against_the_local_rpc_not_the_named_network():
    # --network still names the chain being modelled, and the state files are kept under it, but the
    # transactions go to the local node.
    arguments = run_script.forge_arguments(_invocation(local=True, network="mainnet"))
    assert _pair_index(arguments, "--rpc-url", "local") != -1


def test_the_script_s_connection_retries_the_provider_s_refusals():
    # A provider refuses a request over its rate limit (HTTP 429): the fork and the endpoint the script sends through
    # retry it with a backoff, on a network and on a local node, whose fork reads through the same provider.
    for invocation in (_invocation(), _invocation(local=True)):
        arguments = run_script.forge_arguments(invocation)
        assert _pair_index(arguments, "--fork-retries", "100") != -1, arguments
        assert _pair_index(arguments, "--fork-retry-backoff", "5000") != -1, arguments


def test_a_local_run_sends_legacy_transactions():
    # A legacy transaction needs no fee estimate. The estimate asks anvil for a fee history, anvil asks the provider for
    # the block it forked, and for a block far behind the head the provider answers HTTP 503 until the request times
    # out: a fork of an old block could not broadcast. A network's fees are real, so it keeps the estimate.
    assert "--legacy" in run_script.forge_arguments(_invocation(local=True))
    assert "--legacy" not in run_script.forge_arguments(_invocation(broadcast=True, account="deployer"))


# ── Deployment state ──────────────────────────────────────────────────────────────────────────────


def test_a_real_run_writes_state_under_its_network():
    assert run_script.deploy_state_dir(_invocation(), pathlib.Path("/repo"), NOW) == pathlib.Path(
        "/repo/deployments/mainnet"
    )


def test_a_local_run_is_kept_apart_from_the_real_one():
    # A throwaway anvil deployment must never be readable as the state of a real network.
    assert run_script.deploy_state_dir(_invocation(local=True), pathlib.Path("/repo"), NOW) == pathlib.Path(
        "/repo/deployments/local/mainnet"
    )


def test_timestamping_separates_successive_local_runs():
    state_dir = run_script.deploy_state_dir(_invocation(local=True, timestamp=True), pathlib.Path("/repo"), NOW)
    assert state_dir == pathlib.Path("/repo/deployments/local-2026-08-25T12:30:45Z/mainnet")


def test_the_script_reads_one_state_file_and_writes_its_pending_sibling():
    # The separation is what stops forge's simulation pass polluting the file the broadcast pass
    # reads — the two passes run the same Solidity against the same paths.
    environment = run_script.solidity_environment(_invocation(), pathlib.Path("/repo/deployments/mainnet"), NOW)
    assert environment["DEPLOY_STATE_FILE_READ"] == "/repo/deployments/mainnet/harbor_v1.state.json"
    assert environment["DEPLOY_STATE_FILE_WRITE"] == "/repo/deployments/mainnet/harbor_v1.state.json.pending"


def test_the_network_reaches_the_script_in_its_environment():
    # The default entry point takes the salt alone: the deploy machinery reads the network from the environment.
    environment = run_script.solidity_environment(_invocation(), pathlib.Path("/repo"), NOW)
    assert environment["NETWORK"] == "mainnet"


def test_no_run_asks_the_script_to_execute_its_batches():
    # A local run saves its batches as a mainnet run does: each is left for its signer, on the node as on mainnet.
    assert "EXECUTE_LOCAL" not in run_script.solidity_environment(_invocation(), pathlib.Path("/r"), NOW)
    assert "EXECUTE_LOCAL" not in run_script.solidity_environment(_invocation(local=True), pathlib.Path("/r"), NOW)


def test_a_batch_is_described_by_its_script_and_salt_when_no_message_is_given():
    assert run_script.safe_batch_description(_invocation()) == "Deploy_Thing_mainnet --salt harbor_v1"


def test_an_over_long_description_is_truncated_rather_than_rejected():
    # Safe refuses a longer one, and finding that out at the end of a deployment is the worst moment.
    description = run_script.safe_batch_description(_invocation(message="x" * 500))
    assert len(description) == run_script.MAX_DESCRIPTION
    assert description.endswith("...")


# ── Settling the pending state file ───────────────────────────────────────────────────────────────


def test_a_broadcast_run_promotes_its_pending_state(tmp_path):
    pending, final = tmp_path / "s.json.pending", tmp_path / "s.json"
    pending.write_text("new")
    final.write_text("old")
    run_script.promote_or_discard(pending, final, broadcast=True)
    assert final.read_text() == "new"
    assert not pending.exists()


def test_a_dry_run_discards_its_pending_state(tmp_path):
    # Its addresses were never deployed, so keeping them would leave a state file describing a chain
    # that does not exist — and the next run would read it as though it did.
    pending, final = tmp_path / "s.json.pending", tmp_path / "s.json"
    pending.write_text("simulated")
    final.write_text("real")
    run_script.promote_or_discard(pending, final, broadcast=False)
    assert final.read_text() == "real"
    assert not pending.exists()


def test_nothing_is_settled_when_the_script_wrote_no_state(tmp_path):
    final = tmp_path / "s.json"
    final.write_text("real")
    assert run_script.promote_or_discard(tmp_path / "s.json.pending", final, broadcast=True) is None
    assert final.read_text() == "real"


# ── The argument contract ─────────────────────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "argv, expected",
    [
        (["Deploy_Thing_mainnet", "--salt", "s"], "--network"),
        (["Deploy_Thing_mainnet", "--network", "mainnet"], "--salt"),
        (["--salt", "s", "--network", "mainnet"], "script_name"),
    ],
    ids=["network missing", "salt missing", "script name missing"],
)
def test_a_missing_requirement_names_itself(argv, expected):
    # --network names the RPC, the state folder and the script's NETWORK: without it the deployment would target
    # whatever the RPC defaulted to.
    with pytest.raises(SystemExit) as raised:
        run_script.parse_arguments(argv)
    assert expected in str(raised.value)


def test_a_broadcast_not_on_a_local_node_needs_an_account():
    # A broadcast that is not local is signed with a keystore account; a dry run sends nothing, and a local node's
    # sender is impersonated.
    with pytest.raises(SystemExit) as raised:
        run_script.parse_arguments(["Deploy_Thing_mainnet", "--salt", "s", "--network", "mainnet", "--broadcast"])
    assert "❌ --account required: a broadcast that is not --local signs with a keystore account" == str(raised.value)
    for accepted in (["--broadcast", "--account", "deployer"], [], ["--local", "--broadcast"]):
        run_script.parse_arguments(["Deploy_Thing_mainnet", "--salt", "s", "--network", "mainnet", *accepted])


def test_timestamp_without_local_is_refused():
    # It names a subdirectory of the local state directory, which only exists in local mode; accepted
    # silently it would write state somewhere no later run reads.
    with pytest.raises(SystemExit) as raised:
        run_script.parse_arguments(["Deploy_Thing_mainnet", "--salt", "s", "--network", "mainnet", "--timestamp"])
    assert "--timestamp requires --local" in str(raised.value)


def test_an_unknown_option_is_refused_rather_than_forwarded_to_forge():
    # Forwarding it would surface as a forge error about a flag the caller never typed at forge.
    with pytest.raises(SystemExit) as raised:
        run_script.parse_arguments(["Deploy_Thing_mainnet", "--salt", "s", "--network", "mainnet", "--wat"])
    assert "--wat" in str(raised.value)


def test_everything_after_the_separator_is_left_for_forge():
    # Including things that look like the runner's own flags: past `--` they are forge's.
    invocation = run_script.parse_arguments(
        ["Deploy_Thing_mainnet", "--salt", "s", "--network", "mainnet", "--", "--sig", "run()", "--local"]
    )
    assert invocation.passthrough == ("--sig", "run()", "--local")
    assert invocation.local is False


def test_the_runner_s_own_flags_are_read_wherever_they_appear():
    # The script name is positional, so a flag after it must still be the runner's — argparse's
    # REMAINDER would have swallowed these, which is why `--` is split off before it runs.
    invocation = run_script.parse_arguments(
        ["Deploy_Thing_mainnet", "--salt", "s", "--network", "mainnet", "--broadcast", "--account", "deployer"]
    )
    assert invocation.broadcast is True


# ── main: the order things happen in ──────────────────────────────────────────────────────────────
# The pure functions above say what a run WOULD be. These say what actually happens around it, which
# is where a deployment's state file can be lost: cleaned up too late, promoted when it should not
# have been, or deleted when it was the only record of a broadcast that half-succeeded. This is the
# one place a fake process earns its keep, because the sequencing is the behaviour.


# The owner the local node's BaoFactory answers: not BaoFactory's owner on mainnet, so a run that used a copy of that
# address instead of asking the factory would send as the wrong account.
NODE_FACTORY_OWNER = "0x000000000000000000000000000000000000fAc7"


class _Forge:
    """Stands in for every process `main` starts, and for what forge does to the state file.

    `cast chain-id` must answer or the runner aborts before composing anything; on a local node the factory answers
    `owner()` with NODE_FACTORY_OWNER, each `cast rpc` answers `null` and the owner's balance is 1 ETH. A `cast send`
    with `--value` is a transfer, any other the operator grant: each can be refused on its own. The forge call
    optionally writes the `.pending` file, as the real one does through the Solidity script, so a test can drive
    promote-and-discard through `main` rather than around it, and saves a batch file for each of `batches`, in that
    order, as the script's flushes would."""

    def __init__(self):
        self.calls = []
        self.returncode = 0
        self.rpc_fails = False
        self.owner_fails = False
        self.transfer_fails = False
        self.send_fails = False
        self.pending_written = None
        self.pending_seen_by_forge = None
        self.forge_environment = None
        self.batches = ()

    def run(self, command, **kwargs):
        self.calls.append(command)
        if command[0] == "cast":
            return self._cast(command)
        # forge: record whether a stale pending file was still there when it started, then write the
        # one the Solidity script would have written.
        self.forge_environment = kwargs.get("env", {})
        pending = pathlib.Path(self.forge_environment["DEPLOY_STATE_FILE_WRITE"])
        self.pending_seen_by_forge = pending.exists()
        if self.pending_written is not None:
            pending.parent.mkdir(parents=True, exist_ok=True)
            pending.write_text(self.pending_written)
        folder = pathlib.Path(self.forge_environment["DEPLOY_STATE_DIR"]) / "batch"
        name = f"{self.forge_environment['SAFE_BATCH_NAME']}_{self.forge_environment['SAFE_BATCH_TIMESTAMP']}"
        for order, suffix in enumerate(self.batches):
            folder.mkdir(parents=True, exist_ok=True)
            batch = folder / f"{name}_{suffix}.json"
            batch.write_text("{}")
            # saved one second apart, in this order
            os.utime(batch, ns=(order * 10**9, (1_000_000_000 + order) * 10**9))
        return _Completed(returncode=self.returncode)

    def _cast(self, command):
        subcommand = command[1]
        if subcommand == "chain-id":
            return (
                _Completed(returncode=1, stderr="Error: error sending request\n")
                if self.rpc_fails
                else _Completed("1\n")
            )
        if subcommand == "call":
            if self.owner_fails:
                return _Completed(
                    returncode=1,
                    stderr="Error: could not decode output; did you specify the wrong function return data type?\n",
                )
            return _Completed(f"{NODE_FACTORY_OWNER}\n")
        if subcommand == "send" and "--value" in command:
            return (
                _Completed(returncode=1, stderr="Error: insufficient funds for gas * price + value\n")
                if self.transfer_fails
                else _Completed()
            )
        if subcommand == "send":
            return (
                _Completed(returncode=1, stderr="Error: execution reverted: Unauthorized\n")
                if self.send_fails
                else _Completed()
            )
        if subcommand == "balance":
            return _Completed("1.000000000000000000\n")
        return _Completed("null\n")


class _Completed:
    def __init__(self, stdout="", returncode=0, stderr=""):
        self.stdout = stdout
        self.returncode = returncode
        self.stderr = stderr


@pytest.fixture
def project(tmp_path, monkeypatch):
    """A project root holding one script, with every process `main` would start replaced."""
    (tmp_path / "foundry.toml").write_text('[profile.default]\nsrc = "src"\n')
    (tmp_path / "script").mkdir()
    (tmp_path / "script" / "Deploy_Thing_mainnet.s.sol").write_text("")
    monkeypatch.chdir(tmp_path)

    forge = _Forge()
    monkeypatch.setattr(run_script.subprocess, "run", forge.run)
    return forge


def _invoke(monkeypatch, *arguments):
    monkeypatch.setattr(sys, "argv", ["run-script", "Deploy_Thing_mainnet", *arguments])
    run_script.main()


def _state_files(tmp_path):
    directory = tmp_path / "deployments" / "mainnet"
    return directory / "harbor_v1.state.json.pending", directory / "harbor_v1.state.json"


def test_a_stale_pending_file_is_removed_before_forge_runs(project, tmp_path, monkeypatch):
    # Ordering is the whole point: cleaned up after forge instead, it would delete the state that
    # run had just written and the deployment would be unrecorded.
    pending, _ = _state_files(tmp_path)
    pending.parent.mkdir(parents=True)
    pending.write_text("left by a prior failed run")
    _invoke(monkeypatch, "--salt", "harbor_v1", "--network", "mainnet")
    assert project.pending_seen_by_forge is False


def test_a_failed_run_keeps_its_pending_file_and_exits_non_zero(project, tmp_path, monkeypatch):
    # It is the only record of how far a broadcast got, so it is deliberately not tidied away.
    pending, _ = _state_files(tmp_path)
    project.returncode = 1
    project.pending_written = "partial"
    with pytest.raises(SystemExit) as raised:
        _invoke(monkeypatch, "--salt", "harbor_v1", "--network", "mainnet", "--broadcast", "--account", "deployer")
    assert raised.value.code == 1
    assert pending.read_text() == "partial"


def test_a_broadcast_promotes_its_pending_file(project, tmp_path, monkeypatch):
    pending, final = _state_files(tmp_path)
    project.pending_written = "deployed"
    _invoke(monkeypatch, "--salt", "harbor_v1", "--network", "mainnet", "--broadcast", "--account", "deployer")
    assert final.read_text() == "deployed"
    assert not pending.exists()


def test_a_dry_run_discards_its_pending_file(project, tmp_path, monkeypatch):
    # Nothing was deployed, so keeping it would leave a state file describing a chain that does not
    # exist — and the next run would read it as though it did.
    pending, final = _state_files(tmp_path)
    project.pending_written = "simulated"
    _invoke(monkeypatch, "--salt", "harbor_v1", "--network", "mainnet")
    assert not pending.exists()
    assert not final.exists()


def test_forge_is_told_where_the_state_files_are(project, tmp_path, monkeypatch):
    # The pure function builds the environment; this is the wiring that hands it over. Without it the
    # script would read and write wherever the ambient environment happened to point.
    pending, final = _state_files(tmp_path)
    _invoke(monkeypatch, "--salt", "harbor_v1", "--network", "mainnet")
    assert project.forge_environment["DEPLOY_STATE_FILE_READ"] == str(final)
    assert project.forge_environment["DEPLOY_STATE_FILE_WRITE"] == str(pending)
    assert project.forge_environment["NETWORK"] == "mainnet"


def test_forge_keeps_the_ambient_environment_as_well(project, monkeypatch):
    # Added to the environment rather than replacing it: forge needs PATH to find solc, and the RPC
    # aliases it resolves live in the caller's environment too.
    monkeypatch.setenv("SOME_AMBIENT_SETTING", "kept")
    _invoke(monkeypatch, "--salt", "harbor_v1", "--network", "mainnet")
    assert project.forge_environment["SOME_AMBIENT_SETTING"] == "kept"
    assert "PATH" in project.forge_environment


def test_an_unreachable_rpc_stops_before_forge_runs(project, monkeypatch):
    # Nothing downstream is meaningful without a chain id, and running forge anyway would fail with
    # forge's own error rather than the one naming the RPC that could not be reached.
    project.rpc_fails = True
    with pytest.raises(SystemExit) as raised:
        _invoke(monkeypatch, "--salt", "harbor_v1", "--network", "mainnet")
    assert "RPC failed" in str(raised.value)
    assert not any(command[0] == "forge" for command in project.calls)


def test_a_script_that_does_not_exist_stops_before_any_process_starts(project, monkeypatch):
    monkeypatch.setattr(sys, "argv", ["run-script", "Deploy_Missing_mainnet", "--salt", "s", "--network", "mainnet"])
    with pytest.raises(SystemExit) as raised:
        run_script.main()
    assert "script/Deploy_Missing_mainnet.s.sol" in str(raised.value)
    assert project.calls == []


def test_running_outside_a_project_root_is_refused(tmp_path, monkeypatch):
    # Every path it builds is relative to the working directory, so from the wrong one it would
    # compose a command that is wrong rather than one that fails.
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(sys, "argv", ["run-script", "Deploy_Thing_mainnet", "--salt", "s", "--network", "mainnet"])
    with pytest.raises(SystemExit) as raised:
        run_script.main()
    assert "project root" in str(raised.value)


# ── main: what a local run does to the node before forge runs ─────────────────────────────────────

_BAO_BASE = pathlib.Path(__file__).resolve().parents[2]


def _solidity(relative, pattern):
    """The first group of `pattern` in bao-base's file `relative`."""
    match = re.search(pattern, (_BAO_BASE / relative).read_text())
    assert match, f"{pattern} not found in {relative}"
    return match.group(1)


def _position(calls, *first_words):
    """Index of the first call starting with these words, or -1."""
    for index, command in enumerate(calls):
        if tuple(command[: len(first_words)]) == first_words:
            return index
    return -1


def test_the_factory_is_the_one_the_deploy_scripts_use():
    # The runner cannot ask Solidity for it, so it holds the address: this keeps that copy equal to the deploy
    # scripts' own.
    deployers = _solidity(
        "script/deployment/FactoryDeployer.sol",
        r"function baoFactory\(\)[^{]*\{(?:\s*//[^\n]*)*\s*return (0x[0-9a-fA-F]{40});",
    )
    assert run_script.BAO_FACTORY == deployers


def _sends(calls, *words):
    """Index of the first `cast send` holding each of `words`, or -1."""
    for index, command in enumerate(calls):
        if command[:2] == ["cast", "send"] and set(words) <= set(command):
            return index
    return -1


def test_a_local_run_funds_the_owner_by_a_transfer_and_rewrites_no_state(project, monkeypatch):
    # A node keeps each block it mines, and a check reads earlier blocks. A cheat rewrites the state of the latest
    # block, which can be a block a batch was executed in: a transfer is a transaction of a block of its own, as on a
    # network. It is sent by the node's first account, which the node holds the key of, so with any --account.
    for arguments in ([], ["--account", "deployer"]):
        project.calls.clear()
        _invoke(monkeypatch, "--salt", "harbor_v1", "--network", "mainnet", "--local", "--broadcast", *arguments)
        calls = project.calls

        assert [command for command in calls if command[:2] == ["cast", "rpc"]] == [], calls
        transfer = _sends(calls, "--value")
        assert transfer != -1, calls
        command = calls[transfer]
        assert _pair_index(command, "--from", run_script.ANVIL_SENDER) != -1, command
        assert _pair_index(command, "--value", run_script.LOCAL_OWNER_FUNDING_WEI) != -1, command
        assert {"--unlocked", "--legacy"} <= set(command), command
        assert _pair_index(command, "--rpc-url", "local") != -1, command
        # the recipient is the one argument that is not an option or an option's value
        assert command[-1] == NODE_FACTORY_OWNER, command


def test_a_refused_funding_stops_the_run_before_forge(project, monkeypatch):
    project.transfer_fails = True
    with pytest.raises(SystemExit) as raised:
        _invoke(monkeypatch, "--salt", "harbor_v1", "--network", "mainnet", "--local", "--broadcast")

    assert str(raised.value) == (
        f"❌ the transfer to {NODE_FACTORY_OWNER} from {run_script.ANVIL_SENDER} was refused: "
        "Error: insufficient funds for gas * price + value"
    )
    assert _position(project.calls, "forge") == -1, project.calls


def test_a_local_run_makes_its_sender_an_operator_as_the_factory_s_owner_before_forge_runs(project, monkeypatch):
    # BaoFactory deploys only for its owner or an operator, and only its owner can set an operator. The owner is the
    # one the node's factory answers; it is funded, then sends the grant, with no key on a node that impersonates.
    _invoke(monkeypatch, "--salt", "harbor_v1", "--network", "mainnet", "--local", "--broadcast")
    calls = project.calls

    owner = _position(calls, "cast", "call", run_script.BAO_FACTORY, "owner()(address)")
    funded = _sends(calls, "--value", NODE_FACTORY_OWNER)
    send = _sends(calls, "setOperator(address,uint256)")
    forge = _position(calls, "forge", "script")
    assert -1 not in (owner, funded, send, forge), calls
    assert owner < funded < send < forge, calls
    command = calls[send]
    assert _pair_index(command, "--from", NODE_FACTORY_OWNER) != -1, command
    assert {"--unlocked", "--legacy"} <= set(command), command
    assert _pair_index(command, "--rpc-url", "local") != -1, command
    arguments = command[command.index(run_script.BAO_FACTORY) :]
    assert arguments[1:3] == ["setOperator(address,uint256)", run_script.ANVIL_SENDER], command
    # The deploy refuses a run with less than OPERATOR_ALLOWANCE_MARGIN of its allowance left: a local node is granted
    # far more.
    margin_days = int(_solidity("script/deployment/FactoryDeployer.sol", r"OPERATOR_ALLOWANCE_MARGIN = (\d+) days;"))
    assert int(arguments[3]) > margin_days * 24 * 60 * 60, command


def test_a_local_run_says_what_it_did_to_the_node(project, monkeypatch, capsys):
    _invoke(monkeypatch, "--salt", "harbor_v1", "--network", "mainnet", "--local", "--broadcast")

    printed = capsys.readouterr().err.splitlines()
    assert f"  Local node: the factory owner {NODE_FACTORY_OWNER} holds 1.000000000000000000 ETH" in printed
    assert f"  Local node: the sender {run_script.ANVIL_SENDER} is a BaoFactory operator for a year" in printed


def test_a_local_run_with_an_account_sets_no_operator(project, monkeypatch):
    # The sender is then the keystore account, whose address only forge resolves: FactoryDeployer's own check speaks
    # for it. The factory's owner is funded all the same: it pays for any batch it signs on the node.
    _invoke(monkeypatch, "--salt", "harbor_v1", "--network", "mainnet", "--local", "--broadcast", "--account", "d")

    assert _sends(project.calls, "--value", NODE_FACTORY_OWNER) != -1, project.calls
    assert _sends(project.calls, "setOperator(address,uint256)") == -1, project.calls


def test_a_run_on_a_network_leaves_the_node_alone(project, monkeypatch):
    # On a network the factory's owner is a multisig and the fees are real: nothing is asked of a node but its chain id.
    _invoke(monkeypatch, "--salt", "harbor_v1", "--network", "mainnet", "--broadcast", "--account", "deployer")

    casts = [command for command in project.calls if command[0] == "cast"]
    assert [command[1] for command in casts] == ["chain-id"], casts


def test_a_factory_that_does_not_answer_stops_the_run_before_forge(project, monkeypatch):
    project.owner_fails = True
    with pytest.raises(SystemExit) as raised:
        _invoke(monkeypatch, "--salt", "harbor_v1", "--network", "mainnet", "--local", "--broadcast")

    assert str(raised.value).startswith(
        f"❌ BaoFactory {run_script.BAO_FACTORY} did not answer owner() on the local node: Error: could not decode"
    ), raised.value
    assert _position(project.calls, "forge") == -1, project.calls


def test_a_refused_operator_grant_stops_the_run_before_forge(project, monkeypatch):
    project.send_fails = True
    with pytest.raises(SystemExit) as raised:
        _invoke(monkeypatch, "--salt", "harbor_v1", "--network", "mainnet", "--local", "--broadcast")

    assert str(raised.value) == (
        f"❌ the operator grant to {run_script.ANVIL_SENDER} was refused: Error: execution reverted: Unauthorized"
    )
    assert _position(project.calls, "forge") == -1, project.calls


# ── main: the batches a run saved, for their signer ───────────────────────────────────────────────


def _next_steps(printed):
    """The lines a run ends with, from the one that says what comes next."""
    lines = printed.splitlines()
    starts = [index for index, line in enumerate(lines) if line.startswith("  Next")]
    return lines[starts[0] :] if starts else []


def test_a_local_run_ends_with_one_run_batch_command_naming_each_batch_in_the_order_saved(
    project, tmp_path, monkeypatch, capsys
):
    # Two batches, saved in an order their names do not sort in. An earlier run's batch of the same script and another
    # script's are in the folder too, and are not named. The command is bao-base's run-batch, by its path from here.
    folder = tmp_path / "deployments" / "local" / "mainnet" / "batch"
    folder.mkdir(parents=True)
    (folder / "Deploy_Thing_mainnet_2026-01-01T00:00:00Z_harbor_multisig.json").write_text("{}")
    (folder / "Pause_AllStabilityPools_2026-01-01T00:00:00Z_harbor_multisig.json").write_text("{}")
    project.batches = ("seed@harbor_multisig", "configure@harbor_multisig")
    _invoke(monkeypatch, "--salt", "harbor_v1", "--network", "mainnet", "--local", "--broadcast")

    steps = _next_steps(capsys.readouterr().err)
    timestamp = project.forge_environment["SAFE_BATCH_TIMESTAMP"]
    assert steps[0] == "  Next, on the node, as each batch's signer, in this order:", steps
    command, *files = (line.strip().removesuffix(" \\").strip() for line in steps[1:])
    run, name = command.split(" ")
    assert (tmp_path / run).resolve() == _BAO_BASE / "run", command
    assert name == "run-batch", command
    assert files == [
        f"deployments/local/mainnet/batch/Deploy_Thing_mainnet_{timestamp}_seed@harbor_multisig.json",
        f"deployments/local/mainnet/batch/Deploy_Thing_mainnet_{timestamp}_configure@harbor_multisig.json",
    ], steps
    # one command, continued onto a line per file
    assert [line.endswith(" \\") for line in steps[1:]] == [True, True, False], steps


def test_a_run_on_a_network_ends_naming_each_batch_for_the_safe_app(project, monkeypatch, capsys):
    project.batches = ("GOLD@harbor_multisig",)
    _invoke(monkeypatch, "--salt", "harbor_v1", "--network", "mainnet", "--broadcast", "--account", "deployer")

    timestamp = project.forge_environment["SAFE_BATCH_TIMESTAMP"]
    assert _next_steps(capsys.readouterr().err) == [
        "  Next, for the signers to execute in the Safe app, in this order:",
        f"    deployments/mainnet/batch/Deploy_Thing_mainnet_{timestamp}_GOLD@harbor_multisig.json",
    ]


def test_a_run_that_saved_no_batch_names_no_next_step(project, monkeypatch, capsys):
    _invoke(monkeypatch, "--salt", "harbor_v1", "--network", "mainnet", "--local", "--broadcast")

    assert _next_steps(capsys.readouterr().err) == []


def test_a_dry_run_lists_its_batches_for_review_with_no_next_step(project, monkeypatch, capsys):
    # A dry run deploys nothing, but its script saves its batches all the same: they can call contracts that were never
    # deployed, so they are listed to be read, not to be executed. On a local node and on a network.
    for case, arguments in enumerate((["--local"], [])):
        project.batches = (f"case{case}@harbor_multisig",)
        _invoke(monkeypatch, "--salt", "harbor_v1", "--network", "mainnet", *arguments)

        printed = capsys.readouterr().err
        timestamp = project.forge_environment["SAFE_BATCH_TIMESTAMP"]
        folder = "deployments/local/mainnet" if arguments else "deployments/mainnet"
        assert _next_steps(printed) == [], printed
        lines = printed.splitlines()
        assert "  Saved by a dry run, for review: nothing was deployed" in lines, printed
        start = lines.index("  Saved by a dry run, for review: nothing was deployed")
        assert lines[start + 1 :] == [
            f"    {folder}/batch/Deploy_Thing_mainnet_{timestamp}_case{case}@harbor_multisig.json"
        ], printed
