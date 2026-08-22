"""Tests for bin/CI — how an unrecognised action name is reported.

The action name is bin/CI's sole positional argument, and the set of valid values is not written
down anywhere a caller can see: it is whichever directories under .github/actions/ contain an
action.yml. Naming the file that was not found tells you the guess was wrong but not what to guess
instead, so the message has to enumerate the actions that do exist.

The expected names are read from the filesystem here rather than hardcoded, so adding an action
does not make this test stale.
"""

import os
import subprocess
from pathlib import Path

BAO_BASE = Path(__file__).resolve().parents[2]
RUN = BAO_BASE / "run"
ACTIONS_DIR = BAO_BASE / ".github" / "actions"


def valid_action_names():
    return sorted(path.parent.name for path in ACTIONS_DIR.glob("*/action.yml"))


def run_ci(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([str(RUN), "CI", *args], cwd=BAO_BASE, capture_output=True, text=True)


def run_ci_against(base_dir: Path, *args: str) -> subprocess.CompletedProcess:
    """bin/CI against a substitute BAO_BASE_DIR, so the actions it finds can be controlled.

    Invoked directly rather than through `run`, which would supply the real BAO_BASE_DIR.
    """
    return subprocess.run(
        ["bash", str(BAO_BASE / "bin" / "CI"), *args],
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


def _action_with_steps(base_dir, body):
    """An actions directory holding one action whose action.yml contains `body`."""
    action_dir = base_dir / ".github" / "actions" / "an-action"
    action_dir.mkdir(parents=True)
    (action_dir / "action.yml").write_text(body)
    return "an-action"


def test_marked_run_command_is_executed(tmp_path):
    name = _action_with_steps(tmp_path, "runs:\n  steps:\n    - run: |\n        # ci-execute-next-line\n        \"$BAO_BASE_DIR\"/run some-target\n")
    result = run_ci_against(tmp_path, name, "--debug")
    assert result.returncode == 0
    assert '"$BAO_BASE_DIR"/run some-target' in result.stdout


def test_marked_yarn_command_is_still_executed(tmp_path):
    # the original form has to keep working — this is an extension, not a replacement
    name = _action_with_steps(tmp_path, "runs:\n  steps:\n    - run: |\n        # ci-execute-next-line\n        yarn test\n")
    result = run_ci_against(tmp_path, name, "--debug")
    assert result.returncode == 0
    assert "yarn test" in result.stdout


def test_marked_command_that_is_neither_is_rejected(tmp_path):
    # the guard still has to fire: the marker means "replay this locally", and a step bin/CI cannot
    # replay would be silently absent from every local run while appearing to be covered.
    name = _action_with_steps(tmp_path, "runs:\n  steps:\n    - run: |\n        # ci-execute-next-line\n        brew install bash\n")
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
    name = _action_with_steps(tmp_path, f"runs:\n  steps:\n    - run: |\n        # ci-execute-next-line\n        {command}\n")
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
