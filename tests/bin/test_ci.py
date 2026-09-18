"""Tests for bin/CI, which replays what GitHub runs — in sections, each headed by what it covers.

This first one is how an unrecognised action name is reported. The action name is bin/CI's only
positional argument, and the set of valid values is not written down anywhere a caller can see: it is
whichever directories under .github/actions/ contain an action.yml. Naming the file that was not
found tells you the guess was wrong but not what to guess instead, so the message has to enumerate
the actions that do exist.

The expected names are read from the filesystem here rather than hardcoded, so adding an action
does not make this test stale.
"""

import os
import re
import signal
import subprocess
import time
from pathlib import Path

import pytest

BAO_BASE = Path(__file__).resolve().parents[2]
RUN = BAO_BASE / "run"
ACTIONS_DIR = BAO_BASE / ".github" / "actions"


def valid_action_names():
    return sorted(path.parent.name for path in ACTIONS_DIR.glob("*/action.yml"))


def run_ci(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([str(RUN), "CI", *args], cwd=BAO_BASE, capture_output=True, text=True)


def run_ci_against(base_dir: Path, *args: str, cwd: Path = None) -> subprocess.CompletedProcess:
    """bin/CI against a substitute BAO_BASE_DIR, so the actions it finds can be controlled.

    Invoked directly rather than through `run`, which would supply the real BAO_BASE_DIR.

    cwd is the calling repo, which is where the workflows naming those actions are read from, and it
    defaults to the same fixture. The two are separate arguments because in a consumer they are
    separate directories: the workflows are the repo's, the actions are bao-base's.
    """
    return subprocess.run(
        ["bash", str(BAO_BASE / "bin" / "CI"), *args],
        cwd=str(cwd or base_dir),
        env={**os.environ, "BAO_BASE_DIR": str(base_dir)},
        capture_output=True,
        text=True,
    )


def test_there_is_at_least_one_action_to_report():
    # the rest of the file is vacuous if the actions directory is empty
    assert valid_action_names()


def test_unknown_action_lists_every_valid_action():
    result = run_ci("does-not-exist")
    output = result.stdout + result.stderr
    for name in valid_action_names():
        assert name in output, f"{name} missing from:\n{output}"


def test_unknown_action_fails():
    result = run_ci("does-not-exist")
    assert result.returncode != 0


def test_unknown_action_still_names_what_was_looked_for():
    # the listing supplements the original diagnosis, it does not replace it
    result = run_ci("does-not-exist")
    assert "does-not-exist" in (result.stdout + result.stderr)


def test_a_single_valid_action_is_listed(tmp_path):
    (tmp_path / ".github" / "actions" / "only-one").mkdir(parents=True)
    (tmp_path / ".github" / "actions" / "only-one" / "action.yml").write_text("runs:\n")
    result = run_ci_against(tmp_path, "does-not-exist")
    assert "only-one" in result.stderr
    assert result.returncode != 0


def test_no_actions_at_all_says_so_rather_than_listing_nothing(tmp_path):
    # an empty listing after "valid actions:" would read as though none of the names were valid,
    # when the real fact is that the directory holds no action.yml
    (tmp_path / ".github" / "actions").mkdir(parents=True)
    result = run_ci_against(tmp_path, "does-not-exist")
    assert "no action.yml found" in result.stderr
    assert "valid actions:" not in result.stderr
    assert result.returncode != 0


def test_a_valid_action_is_accepted():
    # guards the other direction: the listing must not fire for a name that does resolve.
    # --debug parses the action and prints the steps instead of executing them.
    result = run_ci(valid_action_names()[0], "--debug")
    assert result.returncode == 0


# ── which commands bin/CI will replay ─────────────────────────────────────────────────────────────
# The action reaches bao-base two ways: through a repo's yarn scripts, and directly through
# bao-base's own `run`, which needs neither node nor a package.json entry so CI can use it before
# yarn exists. Both must replay locally — a step that only ever runs on GitHub is one you discover
# in a pull request rather than before pushing.


def _action_with_steps(base_dir, body, name="an-action"):
    """An actions directory holding one action whose action.yml contains `body`."""
    action_dir = base_dir / ".github" / "actions" / name
    action_dir.mkdir(parents=True)
    (action_dir / "action.yml").write_text(body)
    return name


def test_marked_run_command_is_executed(tmp_path):
    name = _action_with_steps(
        tmp_path,
        'runs:\n  steps:\n    - run: |\n        # ci-execute-next-line\n        "$BAO_BASE_DIR"/run some-target\n',
    )
    result = run_ci_against(tmp_path, name, "--debug")
    assert result.returncode == 0
    assert '"$BAO_BASE_DIR"/run some-target' in result.stdout


def test_marked_yarn_command_is_still_executed(tmp_path):
    # the original form has to keep working — this is an extension, not a replacement
    name = _action_with_steps(
        tmp_path, "runs:\n  steps:\n    - run: |\n        # ci-execute-next-line\n        yarn test\n"
    )
    result = run_ci_against(tmp_path, name, "--debug")
    assert result.returncode == 0
    assert "yarn test" in result.stdout


def test_marked_command_that_is_neither_is_rejected(tmp_path):
    # the guard still has to fire: the marker means "replay this locally", and a step bin/CI cannot
    # replay would be silently absent from every local run while appearing to be covered.
    name = _action_with_steps(
        tmp_path, "runs:\n  steps:\n    - run: |\n        # ci-execute-next-line\n        brew install bash\n"
    )
    result = run_ci_against(tmp_path, name, "--debug")
    assert result.returncode != 0
    assert "brew install bash" in result.stderr


def test_unmarked_run_command_is_listed_as_not_executed(tmp_path):
    # an unmarked command is reported so it can be adopted, exactly as unmarked yarn commands are
    name = _action_with_steps(tmp_path, "runs:\n  steps:\n    - run: |\n        ./lib/bao-base/run some-target\n")
    result = run_ci_against(tmp_path, name, "--debug")
    assert result.returncode == 0
    assert "not executed" in result.stdout
    assert "./lib/bao-base/run some-target" in result.stdout


def test_marked_inline_if_choosing_between_run_paths_is_executed(tmp_path):
    # The shape the action actually uses. bao-base is lib/bao-base in a consumer and the repo itself
    # in bao-base, and `uses:` takes no expressions, so the step picks between them inline — which
    # puts the invocation after `then` and after `else` rather than at the start of the line.
    command = "if [[ -d lib/bao-base ]]; then lib/bao-base/run workflow_copy; else ./run workflow_copy; fi"
    name = _action_with_steps(
        tmp_path, f"runs:\n  steps:\n    - run: |\n        # ci-execute-next-line\n        {command}\n"
    )
    result = run_ci_against(tmp_path, name, "--debug")
    assert result.returncode == 0
    assert command in result.stdout


def test_a_run_inside_a_longer_command_is_not_mistaken_for_one(tmp_path):
    # the match is anchored at the start of the command: a word ending in "/run" elsewhere in a
    # shell line is not an invocation of bao-base's run, and treating it as one would put a
    # GitHub-only step into the local replay, where it would fail for reasons no one could place.
    name = _action_with_steps(tmp_path, "runs:\n  steps:\n    - run: |\n        echo do not /run this\n")
    result = run_ci_against(tmp_path, name, "--debug")
    assert result.returncode == 0
    assert "do not /run this" not in result.stdout


# ── how a replayed command is executed ────────────────────────────────────────────────────────────
# GitHub runs every step as `bash --noprofile --norc -eo pipefail`, so a failing command aborts the
# rest of that step. Local replay has to match, or `yarn CI` reports success for a step CI will fail.
# These are the only tests here that actually execute a marked command rather than parsing it.


def _stub_yarn(directory, exit_code):
    """A `yarn` on PATH that announces itself and exits as asked, so a test can tell "the command
    ran and failed" from "the command never ran"."""
    directory.mkdir(exist_ok=True)
    stub = directory / "yarn"
    stub.write_text(f'#!/usr/bin/env bash\necho "STUB-YARN-RAN"\nexit {exit_code}\n')
    stub.chmod(0o755)
    return directory


def execute_ci_against(base_dir, *args, stub_bin):
    """bin/CI actually executing, rather than parsing under --debug. cwd is the fixture directory so
    the .ci-state file it writes as it runs lands there and not in the repo."""
    return subprocess.run(
        ["bash", str(BAO_BASE / "bin" / "CI"), *args],
        cwd=base_dir,
        env={
            **os.environ,
            "BAO_BASE_DIR": str(base_dir),
            "PATH": f"{stub_bin}{os.pathsep}{os.environ['PATH']}",
        },
        capture_output=True,
        text=True,
    )


# Whether the tail of a compound command ran is probed through the filesystem, not through stdout:
# bin/CI announces each step by echoing the command itself, so any marker word in the command is in
# the output before the command has run at all.


def test_a_marked_command_stops_at_the_first_failure(tmp_path):
    # The command below fails at `yarn` and then touches a file. If the tail still runs, the
    # compound's exit status becomes the touch's — zero — and a failing step is reported as a
    # passing one, which is the worst outcome available to a CI replay.
    name = _action_with_steps(
        tmp_path,
        "runs:\n  steps:\n    - run: |\n        # ci-execute-next-line\n        yarn thing; touch tail-ran\n",
    )
    result = execute_ci_against(tmp_path, name, stub_bin=_stub_yarn(tmp_path / "stub", 3))
    assert "STUB-YARN-RAN" in result.stdout, "the marked command did not run at all"
    assert not (tmp_path / "tail-ran").exists()
    assert result.returncode != 0


def test_a_marked_command_that_succeeds_runs_to_the_end(tmp_path):
    # The other direction: aborting on failure must not turn into aborting on everything.
    name = _action_with_steps(
        tmp_path,
        "runs:\n  steps:\n    - run: |\n        # ci-execute-next-line\n        yarn thing; touch tail-ran\n",
    )
    result = execute_ci_against(tmp_path, name, stub_bin=_stub_yarn(tmp_path / "stub", 0))
    assert "STUB-YARN-RAN" in result.stdout
    assert (tmp_path / "tail-ran").exists()
    assert result.returncode == 0


# ── which step --retry resumes at ─────────────────────────────────────────────────────────────────
# The state file records the step to resume at, and a run stops for three reasons: the step failed,
# someone pressed Ctrl-C, or the machine went away. Only the first can run any code as it stops, so
# the record has to be on disk while the step is running rather than written as the run ends.

TWO_STEPS_THE_SECOND_BLOCKING = (
    "runs:\n"
    "  steps:\n"
    "    - run: |\n"
    "        # ci-execute-next-line\n"
    "        yarn quick\n"
    "    - run: |\n"
    "        # ci-execute-next-line\n"
    "        yarn blocks\n"
)


def _state_file(base_dir):
    """The single resume record for a run. One file rather than one per action: a run covers several
    actions, so the record has to say which of them stopped as well as where."""
    return base_dir / "tmp" / ".ci-state"


def _state(base_dir):
    """The resume record as {keyword: words}: the action argument the run was given (empty when its
    actions were derived), where it stopped, and the actions it had finished."""
    return {line.split()[0]: line.split()[1:] for line in _state_file(base_dir).read_text().splitlines()}


def _stub_yarn_that_blocks_on(directory, blocking_argument):
    """A `yarn` on PATH that hangs when given `blocking_argument`, so a test can interrupt bin/CI
    while a step is genuinely mid-flight. It announces the start through a file rather than stdout
    because the test has to wait for that moment, and bin/CI's own pipes are read only on exit."""
    directory.mkdir(exist_ok=True)
    stub = directory / "yarn"
    stub.write_text(
        "#!/usr/bin/env bash\n"
        f'if [[ "$1" == "{blocking_argument}" ]]; then\n'
        "  touch step-running\n"
        "  sleep 60\n"
        "fi\n"
        'echo "STUB-YARN-RAN $1"\n'
    )
    stub.chmod(0o755)
    return directory


def interrupt_ci_during_the_blocking_step(base_dir, *args, stub_bin):
    """Run bin/CI and Ctrl-C it while the blocking step runs.

    Ctrl-C reaches every process in the terminal's foreground process group — the step's shell and
    bin/CI alike — so the signal goes to the group, not to bin/CI's pid; signalling the pid alone
    would exercise a path no keypress produces. start_new_session puts the run in a group of its own
    so pytest is not signalled along with it.
    """
    process = subprocess.Popen(
        ["bash", str(BAO_BASE / "bin" / "CI"), *args],
        cwd=base_dir,
        env={
            **os.environ,
            "BAO_BASE_DIR": str(base_dir),
            "PATH": f"{stub_bin}{os.pathsep}{os.environ['PATH']}",
        },
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    deadline = time.monotonic() + 30
    while not (base_dir / "step-running").exists():
        assert process.poll() is None, "bin/CI exited before reaching the blocking step"
        assert time.monotonic() < deadline, "the blocking step never started"
        time.sleep(0.05)
    os.killpg(process.pid, signal.SIGINT)
    stdout, stderr = process.communicate(timeout=30)
    return subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)


def test_an_interrupted_step_is_recorded_as_the_one_to_resume_at(tmp_path):
    # Ctrl-C kills bin/CI along with the step, so nothing it could run as it exits would record
    # anything — and a power cut would not even allow that much.
    name = _action_with_steps(tmp_path, TWO_STEPS_THE_SECOND_BLOCKING)
    stub = _stub_yarn_that_blocks_on(tmp_path / "stub", "blocks")
    interrupt_ci_during_the_blocking_step(tmp_path, name, stub_bin=stub)
    # the action, then its step index 0-based — so the second of the two steps
    assert _state(tmp_path)["stopped"] == [name, "1"]


# Each of the two resumption flags has a long and a short spelling, and both are exercised here: a
# short form that parsed but set nothing would fall through to running the whole action from step 1,
# which looks enough like working to go unnoticed.


@pytest.mark.parametrize("flag", ["--retry", "-r"])
def test_retry_after_an_interrupt_resumes_at_the_interrupted_step(tmp_path, flag):
    name = _action_with_steps(tmp_path, TWO_STEPS_THE_SECOND_BLOCKING)
    stub = _stub_yarn_that_blocks_on(tmp_path / "stub", "blocks")
    interrupt_ci_during_the_blocking_step(tmp_path, name, stub_bin=stub)

    # the same argument no longer hangs, so the retried step can finish
    result = execute_ci_against(tmp_path, name, flag, stub_bin=_stub_yarn(tmp_path / "stub", 0))
    assert result.returncode == 0, result.stdout + result.stderr
    assert f"=== {name} [2/2]" in result.stdout
    assert f"=== {name} [1/2]" not in result.stdout, "the step that had already passed was run again"


@pytest.mark.parametrize("flag", ["--skip", "-s"])
def test_skip_after_an_interrupt_moves_past_the_interrupted_step(tmp_path, flag):
    name = _action_with_steps(tmp_path, TWO_STEPS_THE_SECOND_BLOCKING)
    stub = _stub_yarn_that_blocks_on(tmp_path / "stub", "blocks")
    interrupt_ci_during_the_blocking_step(tmp_path, name, stub_bin=stub)

    result = execute_ci_against(tmp_path, name, flag, stub_bin=_stub_yarn(tmp_path / "stub", 0))
    assert result.returncode == 0, result.stdout + result.stderr
    assert f"Skipping {name} step 2 of 2" in result.stdout
    assert f"=== {name} [2/2]" not in result.stdout, "the skipped step was run"
    assert not _state_file(tmp_path).exists()


# ── what a stopped run tells you to do next ───────────────────────────────────────────────────────
# A run that stopped part-way is resumable, but only if the person watching knows it. Both places a
# run can stop say the same two things: where it stopped, and both spellings of each way to carry on
# — the short forms appear nowhere else, so a hint that gave only the long ones would leave them
# undiscoverable in the one situation that involves repeated typing.


def _assert_names_every_way_to_resume(text):
    """Every spelling of both flags is offered, each as a flag in its own right.

    Matched on a boundary rather than as a substring: "-r" occurs inside "--retry", so a plain
    containment check would report the short forms as present in a hint that never mentions them.
    """
    for flag in ("--retry", "-r", "--skip", "-s"):
        pattern = rf"(?<![-\w]){re.escape(flag)}(?![\w-])"
        assert re.search(pattern, text), f"{flag} is not offered in:\n{text}"


def test_an_interrupt_says_which_step_it_stopped_at(tmp_path):
    name = _action_with_steps(tmp_path, TWO_STEPS_THE_SECOND_BLOCKING)
    stub = _stub_yarn_that_blocks_on(tmp_path / "stub", "blocks")
    result = interrupt_ci_during_the_blocking_step(tmp_path, name, stub_bin=stub)
    assert f"INTERRUPTED at {name} step 2/2: yarn blocks" in result.stderr


def test_an_interrupt_names_both_spellings_of_both_ways_to_resume(tmp_path):
    name = _action_with_steps(tmp_path, TWO_STEPS_THE_SECOND_BLOCKING)
    stub = _stub_yarn_that_blocks_on(tmp_path / "stub", "blocks")
    result = interrupt_ci_during_the_blocking_step(tmp_path, name, stub_bin=stub)
    _assert_names_every_way_to_resume(result.stderr)


def test_a_failed_step_names_both_spellings_of_both_ways_to_resume(tmp_path):
    # the other place a run stops; the two reports are the same offer and must not drift apart
    name = _action_with_steps(
        tmp_path, "runs:\n  steps:\n    - run: |\n        # ci-execute-next-line\n        yarn thing\n"
    )
    result = execute_ci_against(tmp_path, name, stub_bin=_stub_yarn(tmp_path / "stub", 3))
    assert result.returncode != 0
    _assert_names_every_way_to_resume(result.stderr)


def test_an_interrupt_before_any_step_starts_reports_nothing_to_resume(tmp_path):
    # --retry does not clear the state file, so one is on disk from the very first line of a retried
    # run. Reporting a stopping point from its mere presence would name a step this run never
    # reached, on a run that stopped before it had started anything.
    name = _action_with_steps(tmp_path, TWO_STEPS_THE_SECOND_BLOCKING)
    stub = _stub_yarn_that_blocks_on(tmp_path / "stub", "blocks")
    interrupt_ci_during_the_blocking_step(tmp_path, name, stub_bin=stub)

    process = subprocess.Popen(
        ["bash", str(BAO_BASE / "bin" / "CI"), name, "--retry", "--debug"],
        cwd=tmp_path,
        env={**os.environ, "BAO_BASE_DIR": str(tmp_path)},
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    os.killpg(process.pid, signal.SIGINT)
    _, stderr = process.communicate(timeout=30)
    assert "INTERRUPTED" not in stderr


def test_a_successful_run_leaves_no_state_file(tmp_path):
    # The other direction: a record kept for the whole run must still be cleared by the end of it,
    # or the next --retry would resume a run that had finished.
    name = _action_with_steps(
        tmp_path, "runs:\n  steps:\n    - run: |\n        # ci-execute-next-line\n        yarn thing\n"
    )
    result = execute_ci_against(tmp_path, name, stub_bin=_stub_yarn(tmp_path / "stub", 0))
    assert result.returncode == 0
    assert not _state_file(tmp_path).exists()


# ── which actions a run covers ────────────────────────────────────────────────────────────────────
# GitHub runs every workflow the repo has, so a local replay that runs one action passes while the
# rest was never tried. The list is derived from the CALLING repo's .github/workflows — each workflow
# names the action it uses — so a repo replays the jobs it actually has and no others. Workflows
# ending "latest.yml" are left out: they differ from their stable twin only in the foundry version,
# which the local replay never installs, so running one would repeat the other step for step.


def _workflow(base_dir, filename, action_path):
    """A workflow file whose job reaches `action_path`, alongside the checkout step every real
    workflow starts with."""
    workflows = base_dir / ".github" / "workflows"
    workflows.mkdir(parents=True, exist_ok=True)
    (workflows / filename).write_text(
        "name: a workflow\n"
        "on:\n"
        "  push:\n"
        "jobs:\n"
        "  a_job:\n"
        "    runs-on: ubuntu-latest\n"
        "    steps:\n"
        "      - name: Checkout repository with submodules\n"
        "        uses: actions/checkout@v6\n"
        "      - name: Run Bao-base CI actions\n"
        f"        uses: {action_path}\n"
    )
    return workflows / filename


def _action_announcing_itself(base_dir, name):
    """An action whose one marked command names the action, so the output of a run says which actions
    it covered and in what order."""
    return _action_with_steps(
        base_dir,
        f"runs:\n  steps:\n    - run: |\n        # ci-execute-next-line\n        yarn {name}\n",
        name,
    )


def test_every_workflows_action_is_run(tmp_path):
    _action_announcing_itself(tmp_path, "first")
    _action_announcing_itself(tmp_path, "second")
    _workflow(tmp_path, "CI-first.yml", "./.github/actions/first")
    _workflow(tmp_path, "CI-second.yml", "./.github/actions/second")

    result = run_ci_against(tmp_path, "--debug")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "yarn first" in result.stdout
    assert "yarn second" in result.stdout


def test_actions_run_in_workflow_filename_order(tmp_path):
    # the order is derived from the filenames, so it is the same on every machine — the fixture
    # writes them in the opposite order to prove the glob is what sorts them
    _action_announcing_itself(tmp_path, "beta")
    _action_announcing_itself(tmp_path, "alpha")
    _workflow(tmp_path, "2-beta.yml", "./.github/actions/beta")
    _workflow(tmp_path, "1-alpha.yml", "./.github/actions/alpha")

    result = run_ci_against(tmp_path, "--debug")
    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stdout.index("yarn alpha") < result.stdout.index("yarn beta")


def test_a_latest_workflow_is_excluded(tmp_path):
    _action_announcing_itself(tmp_path, "stable-action")
    _action_announcing_itself(tmp_path, "nightly-action")
    _workflow(tmp_path, "CI-thing-stable.yml", "./.github/actions/stable-action")
    _workflow(tmp_path, "CI-thing-latest.yml", "./.github/actions/nightly-action")

    result = run_ci_against(tmp_path, "--debug")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "yarn stable-action" in result.stdout
    assert "yarn nightly-action" not in result.stdout


def test_each_action_is_announced_with_the_workflow_that_named_it(tmp_path):
    # a run covers several workflows and the longest takes tens of minutes, so what is under way is
    # named the way GitHub names it — by the workflow file, not only by the action it reaches
    _action_announcing_itself(tmp_path, "an-action")
    _workflow(tmp_path, "CI-a-workflow.yml", "./.github/actions/an-action")

    result = run_ci_against(tmp_path, "--debug")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "CI-a-workflow.yml" in result.stdout
    assert result.stdout.index("CI-a-workflow.yml") < result.stdout.index("yarn an-action")


def test_an_action_named_as_the_argument_is_announced_without_a_workflow(tmp_path):
    # it was not reached through one, and naming the workflow that happens to mention it would say
    # this run covers that workflow when it does not
    _action_announcing_itself(tmp_path, "an-action")
    _workflow(tmp_path, "CI-a-workflow.yml", "./.github/actions/an-action")

    result = run_ci_against(tmp_path, "an-action", "--debug")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "CI-a-workflow.yml" not in result.stdout


def test_two_workflows_naming_one_action_run_it_once(tmp_path):
    # the stable and latest workflows use the same action, and so may any other pair — replaying its
    # steps twice would double the longest part of a run for nothing
    _action_announcing_itself(tmp_path, "shared")
    _workflow(tmp_path, "CI-one.yml", "./.github/actions/shared")
    _workflow(tmp_path, "CI-two.yml", "./.github/actions/shared")

    result = run_ci_against(tmp_path, "--debug")
    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stdout.count("yarn shared") == 1


def test_a_consumer_spelling_of_the_action_path_is_recognised(tmp_path):
    # A consumer's workflow is a copy of bao-base's with one difference: the action is under
    # lib/bao-base rather than at the repo root. So the two directories are genuinely separate there
    # — the workflows are the consumer's, the actions are bao-base's — and both spellings of the path
    # name the same action.
    consumer = tmp_path / "consumer"
    bao_base = tmp_path / "consumer" / "lib" / "bao-base"
    bao_base.mkdir(parents=True)
    _action_announcing_itself(bao_base, "an-action-under-bao-base")
    _workflow(consumer, "CI-stable.yml", "./lib/bao-base/.github/actions/an-action-under-bao-base")

    result = run_ci_against(bao_base, "--debug", cwd=consumer)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "yarn an-action-under-bao-base" in result.stdout


def test_a_published_action_reference_is_not_taken_for_a_local_one(tmp_path):
    # every workflow starts by using actions/checkout, which is a published action and not a
    # directory in this repo — taking it for one would look for an action named "checkout@v6"
    _action_announcing_itself(tmp_path, "local-action")
    _workflow(tmp_path, "CI-thing.yml", "./.github/actions/local-action")

    result = run_ci_against(tmp_path, "--debug")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "checkout" not in result.stdout + result.stderr


def test_no_workflows_is_an_error_naming_where_it_looked(tmp_path):
    # a repo with no workflows has nothing for CI to replay, and saying so beats exiting zero on a
    # run that did nothing
    _action_announcing_itself(tmp_path, "an-action")

    result = run_ci_against(tmp_path, "--debug")
    assert result.returncode != 0
    assert ".github/workflows" in result.stderr


def test_workflows_that_name_no_local_action_is_an_error_naming_where_it_looked(tmp_path):
    # the other way to end up with nothing to run: workflow files exist, but none of them reaches an
    # action in this repo. Silently doing nothing would read as a clean run.
    _action_announcing_itself(tmp_path, "an-action")
    (tmp_path / ".github" / "workflows").mkdir(parents=True)
    (tmp_path / ".github" / "workflows" / "CI-thing.yml").write_text(
        "jobs:\n  a_job:\n    steps:\n      - uses: actions/checkout@v6\n"
    )

    result = run_ci_against(tmp_path, "--debug")
    assert result.returncode != 0
    assert ".github/workflows" in result.stderr


def test_an_action_argument_replaces_the_derived_list(tmp_path):
    # the argument is how you run one action on its own, so it has to override the derivation rather
    # than add to it
    _action_announcing_itself(tmp_path, "derived")
    _action_announcing_itself(tmp_path, "given")
    _workflow(tmp_path, "CI-derived.yml", "./.github/actions/derived")

    result = run_ci_against(tmp_path, "given", "--debug")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "yarn given" in result.stdout
    assert "yarn derived" not in result.stdout


# ── resuming a run that covers several actions ────────────────────────────────────────────────────
# The resume record has to name the action as well as the step: the run that stopped had more actions
# behind it, and carrying on means finishing the one that stopped and then running the rest.


def _stub_yarn_logging(directory, failing_argument=None):
    """A `yarn` on PATH that records each invocation in ran.log and fails on one chosen argument.

    The log is how a test tells which steps ran: bin/CI echoes each command before running it, so a
    command's presence in stdout says only that it was announced.
    """
    directory.mkdir(exist_ok=True)
    stub = directory / "yarn"
    stub.write_text(
        f'#!/usr/bin/env bash\necho "$1" >>ran.log\nif [[ "$1" == "{failing_argument}" ]]; then\n  exit 3\nfi\n'
    )
    stub.chmod(0o755)
    return directory


def _two_actions_from_workflows(base_dir):
    """Two actions of two steps each, reached through one workflow apiece."""
    for name in ("first", "second"):
        _action_with_steps(
            base_dir,
            "runs:\n"
            "  steps:\n"
            "    - run: |\n"
            "        # ci-execute-next-line\n"
            f"        yarn {name}-one\n"
            "    - run: |\n"
            "        # ci-execute-next-line\n"
            f"        yarn {name}-two\n",
            name,
        )
        _workflow(base_dir, f"CI-{name}.yml", f"./.github/actions/{name}")


def test_a_failure_records_the_action_as_well_as_the_step(tmp_path):
    _two_actions_from_workflows(tmp_path)
    result = execute_ci_against(tmp_path, stub_bin=_stub_yarn_logging(tmp_path / "stub", "second-one"))
    assert result.returncode != 0
    # 0-based, so the first step of the second action
    assert _state(tmp_path)["stopped"] == ["second", "0"]
    assert _state(tmp_path)["completed"] == ["first"]


def test_a_failure_records_the_run_it_belongs_to(tmp_path):
    # the argument the run was given, so carrying on resumes that run — an empty record is the run
    # that named no action and derived its own
    _two_actions_from_workflows(tmp_path)
    execute_ci_against(tmp_path, stub_bin=_stub_yarn_logging(tmp_path / "stub", "first-one"))
    assert _state(tmp_path)["action"] == []

    execute_ci_against(tmp_path, "first", stub_bin=_stub_yarn_logging(tmp_path / "stub", "first-one"))
    assert _state(tmp_path)["action"] == ["first"]


def test_retry_resumes_in_the_failing_action_then_runs_the_rest(tmp_path):
    # three actions so there is both a step left in the failing action and a whole action after it
    _two_actions_from_workflows(tmp_path)
    _action_announcing_itself(tmp_path, "third")
    _workflow(tmp_path, "CI-third.yml", "./.github/actions/third")

    execute_ci_against(tmp_path, stub_bin=_stub_yarn_logging(tmp_path / "stub", "first-two"))
    (tmp_path / "ran.log").unlink()

    result = execute_ci_against(tmp_path, "--retry", stub_bin=_stub_yarn_logging(tmp_path / "stub"))
    assert result.returncode == 0, result.stdout + result.stderr
    assert (tmp_path / "ran.log").read_text().split() == ["first-two", "second-one", "second-two", "third"]


def test_skip_moves_past_the_failed_step_within_its_action(tmp_path):
    _two_actions_from_workflows(tmp_path)
    execute_ci_against(tmp_path, stub_bin=_stub_yarn_logging(tmp_path / "stub", "first-one"))
    (tmp_path / "ran.log").unlink()

    result = execute_ci_against(tmp_path, "--skip", stub_bin=_stub_yarn_logging(tmp_path / "stub"))
    assert result.returncode == 0, result.stdout + result.stderr
    assert (tmp_path / "ran.log").read_text().split() == ["first-two", "second-one", "second-two"]


def test_skip_past_an_actions_last_step_continues_into_the_next_action(tmp_path):
    # the boundary the per-action record could not express: the step to resume at is the first step
    # of the action after the one that stopped
    _two_actions_from_workflows(tmp_path)
    execute_ci_against(tmp_path, stub_bin=_stub_yarn_logging(tmp_path / "stub", "first-two"))
    (tmp_path / "ran.log").unlink()

    result = execute_ci_against(tmp_path, "--skip", stub_bin=_stub_yarn_logging(tmp_path / "stub"))
    assert result.returncode == 0, result.stdout + result.stderr
    assert (tmp_path / "ran.log").read_text().split() == ["second-one", "second-two"]


def test_a_bare_retry_carries_on_with_the_run_that_stopped(tmp_path):
    # the run that stopped named one action, so carrying on is that action and no others — without
    # having to name it again, which is the whole of what a resume is for
    _two_actions_from_workflows(tmp_path)
    execute_ci_against(tmp_path, "first", stub_bin=_stub_yarn_logging(tmp_path / "stub", "first-two"))
    (tmp_path / "ran.log").unlink()

    result = execute_ci_against(tmp_path, "--retry", stub_bin=_stub_yarn_logging(tmp_path / "stub"))
    assert result.returncode == 0, result.stdout + result.stderr
    assert (tmp_path / "ran.log").read_text().split() == ["first-two"]


def test_resuming_as_an_action_the_stopped_run_was_not_is_an_error(tmp_path):
    # An action argument says which action to run, and --retry says to carry on with the run that
    # stopped. Naming a different run than the one on disk asks for both at once, and either reading
    # of it does something nobody asked for.
    _two_actions_from_workflows(tmp_path)
    execute_ci_against(tmp_path, stub_bin=_stub_yarn_logging(tmp_path / "stub", "second-one"))
    (tmp_path / "ran.log").unlink()

    result = execute_ci_against(tmp_path, "first", "--retry", stub_bin=_stub_yarn_logging(tmp_path / "stub"))
    assert result.returncode != 0
    assert "first" in result.stderr
    assert not (tmp_path / "ran.log").exists(), "a contradicted resume ran a step anyway"


def test_resuming_a_run_whose_action_is_no_longer_covered_says_so(tmp_path):
    # the actions can change between a stop and a resume — a workflow removed, or one that no longer
    # names that action. Resuming into a run that does not contain the stopping point would silently
    # leave it unfinished.
    _two_actions_from_workflows(tmp_path)
    execute_ci_against(tmp_path, stub_bin=_stub_yarn_logging(tmp_path / "stub", "second-one"))
    (tmp_path / ".github" / "workflows" / "CI-second.yml").unlink()

    result = execute_ci_against(tmp_path, "--retry", stub_bin=_stub_yarn_logging(tmp_path / "stub"))
    assert result.returncode != 0
    assert "second" in result.stderr


def test_a_looped_run_that_passes_leaves_no_state_file(tmp_path):
    # the record is cleared at the end of the LAST action, not the first — one left behind would make
    # the next --retry resume a run that had finished
    _two_actions_from_workflows(tmp_path)
    result = execute_ci_against(tmp_path, stub_bin=_stub_yarn_logging(tmp_path / "stub"))
    assert result.returncode == 0, result.stdout + result.stderr
    assert (tmp_path / "ran.log").read_text().split() == ["first-one", "first-two", "second-one", "second-two"]
    assert not _state_file(tmp_path).exists()
