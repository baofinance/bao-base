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
import pathlib
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


def test_default_entry_point_passes_the_salt_then_the_network():
    # Both values the runner requires reach the script the same way, as arguments. Order is asserted
    # because a signature naming two strings is worth nothing if the values arrive reversed — forge
    # would accept either without complaint and the deployment would target the wrong chain.
    command = run_script.forge_command(_invocation())
    signature = _pair_index(command, "--sig", "run(string,string)")
    assert signature != -1, command
    assert command[signature + 2 : signature + 4] == ["harbor_v1", "mainnet"]


def test_the_contract_and_the_file_are_named_the_same():
    # forge is given the path and the contract separately, so the two have to agree: a rename of one
    # is a rename of both, and disagreeing produces "source file not found" rather than anything
    # that points at the cause.
    command = run_script.forge_command(_invocation(script_name="Deploy_ETH_HarborYield_mainnet"))
    assert "script/Deploy_ETH_HarborYield_mainnet.s.sol" in command
    assert _pair_index(command, "--tc", "Deploy_ETH_HarborYield_mainnet") != -1


def test_a_passthrough_replaces_the_default_entry_point():
    # Every harbor deploy script is on an older signature and overrides this way. Adding the default
    # as well would hand forge two --sig flags, leaving it to run whichever it saw last.
    command = run_script.forge_command(_invocation(passthrough=("--sig", "run(string,bool)", "harbor_v1", "false")))
    assert "run(string,bool)" in command
    assert "run(string,string)" not in command


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


def test_the_network_reaches_the_script_in_its_environment_too():
    # Passed as an argument AND exported: scripts on the default signature take it as an argument,
    # and the shared deploy machinery beneath them reads it from the environment.
    environment = run_script.solidity_environment(_invocation(), pathlib.Path("/repo"), NOW)
    assert environment["NETWORK"] == "mainnet"


def test_execute_local_is_set_only_for_a_local_run():
    assert "EXECUTE_LOCAL" not in run_script.solidity_environment(_invocation(), pathlib.Path("/r"), NOW)
    assert run_script.solidity_environment(_invocation(local=True), pathlib.Path("/r"), NOW)["EXECUTE_LOCAL"] == "true"


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
    # --network is required precisely because the default entry point hands it to the script: without
    # it there would be nothing to pass, and the deployment would target whatever the RPC defaulted to.
    with pytest.raises(SystemExit) as raised:
        run_script.parse_arguments(argv)
    assert expected in str(raised.value)


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
        ["Deploy_Thing_mainnet", "--salt", "s", "--network", "mainnet", "--broadcast"]
    )
    assert invocation.broadcast is True


# ── main: the order things happen in ──────────────────────────────────────────────────────────────
# The pure functions above say what a run WOULD be. These say what actually happens around it, which
# is where a deployment's state file can be lost: cleaned up too late, promoted when it should not
# have been, or deleted when it was the only record of a broadcast that half-succeeded. This is the
# one place a fake process earns its keep, because the sequencing is the behaviour.


class _Forge:
    """Stands in for every process `main` starts, and for what forge does to the state file.

    `cast chain-id` must answer or the runner aborts before composing anything. The forge call
    optionally writes the `.pending` file, as the real one does through the Solidity script, so a
    test can drive promote-and-discard through `main` rather than around it."""

    def __init__(self):
        self.calls = []
        self.returncode = 0
        self.rpc_fails = False
        self.pending_written = None
        self.pending_seen_by_forge = None
        self.forge_environment = None

    def run(self, command, **kwargs):
        self.calls.append(command)
        if command[0] == "cast":
            if command[1] == "chain-id" and self.rpc_fails:
                raise run_script.subprocess.CalledProcessError(1, command)
            return _Completed(stdout="31337\n")
        # forge: record whether a stale pending file was still there when it started, then write the
        # one the Solidity script would have written.
        self.forge_environment = kwargs.get("env", {})
        pending = pathlib.Path(self.forge_environment["DEPLOY_STATE_FILE_WRITE"])
        self.pending_seen_by_forge = pending.exists()
        if self.pending_written is not None:
            pending.parent.mkdir(parents=True, exist_ok=True)
            pending.write_text(self.pending_written)
        return _Completed(returncode=self.returncode)


class _Completed:
    def __init__(self, stdout="", returncode=0):
        self.stdout = stdout
        self.returncode = returncode


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
        _invoke(monkeypatch, "--salt", "harbor_v1", "--network", "mainnet", "--broadcast")
    assert raised.value.code == 1
    assert pending.read_text() == "partial"


def test_a_broadcast_promotes_its_pending_file(project, tmp_path, monkeypatch):
    pending, final = _state_files(tmp_path)
    project.pending_written = "deployed"
    _invoke(monkeypatch, "--salt", "harbor_v1", "--network", "mainnet", "--broadcast")
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
