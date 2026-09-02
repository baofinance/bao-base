"""Tests for bin/optional-yarn-script — running a project's optional package.json script.

The test-foundry action offers a consumer two of these: `debug`, a pre-test diagnostic run before
anything slow, and `wtf`, bespoke checks run at the end. They ask the same question — does this
project define the script at all? — and differ only in what printing something MEANS. For `debug`
output is information; for `wtf` output IS the verdict. So they share one implementation, and the
difference is the `--output-means-failure` flag.

Why a script rather than shell inside action.yml: shell embedded in a step is reachable only by
GitHub. Here it is reachable by `run`, which makes it both replayable through bin/CI and testable
from here.

Every test puts a stub `yarn` on PATH whose behaviour it chooses, so the four combinations of
"printed something" and "exited non-zero" are all reachable without a real project. Invoked as bash
directly rather than through `run`, which would add provisioning for no benefit — the same shape as
test_ci.py.
"""

import json
import os
import subprocess
from pathlib import Path

BAO_BASE = Path(__file__).resolve().parents[2]
SCRIPT = BAO_BASE / "bin" / "optional-yarn-script"

# Stands in for yarn. One stub covers every case; which branch it takes is chosen per test through
# YARN_MODE. An unset mode is a loud failure rather than a silent success, so a test that forgets to
# choose one cannot pass by accident.
STUB_YARN = """#!/usr/bin/env bash
case "$YARN_MODE" in
  silent) exit 0 ;;
  prints) echo "a line of output" ;;
  fails_quietly) exit 7 ;;
  fails_loudly) echo "the explanation of the failure"; exit 7 ;;
  *) echo "stub yarn: YARN_MODE not set" >&2; exit 99 ;;
esac
"""


def invoke(tmp_path, *args, scripts=None, package_json=True, yarn_mode="silent"):
    """Run the script in a throwaway project. `scripts` is package.json's scripts object;
    `package_json=False` leaves the file out altogether."""
    project = tmp_path / "project"
    stub_dir = tmp_path / "stub"
    project.mkdir(exist_ok=True)
    stub_dir.mkdir(exist_ok=True)

    yarn = stub_dir / "yarn"
    yarn.write_text(STUB_YARN)
    yarn.chmod(0o755)

    if package_json:
        (project / "package.json").write_text(json.dumps({"scripts": scripts or {}}))

    return subprocess.run(
        ["bash", str(SCRIPT), *args],
        cwd=project,
        env={**os.environ, "PATH": f"{stub_dir}{os.pathsep}{os.environ['PATH']}", "YARN_MODE": yarn_mode},
        capture_output=True,
        text=True,
    )


def test_a_project_without_the_script_is_not_a_failure(tmp_path):
    # The whole point of "optional": most repos define neither script, and their CI must stay green.
    result = invoke(tmp_path, "debug", scripts={"test": "forge test"})
    assert result.returncode == 0
    assert "debug" in result.stdout


def test_a_project_without_a_package_json_is_not_a_failure(tmp_path):
    # Reported separately from "the file exists but lacks the script": the check knows which of the
    # two it saw, and saying "no debug script in package.json" when there is no package.json at all
    # sends the reader looking for a key in a file that is not there.
    result = invoke(tmp_path, "debug", package_json=False)
    assert result.returncode == 0
    assert "package.json" in result.stdout


def test_a_defined_script_runs_and_its_output_is_shown(tmp_path):
    result = invoke(tmp_path, "debug", scripts={"debug": "x"}, yarn_mode="prints")
    assert result.returncode == 0
    assert "a line of output" in result.stdout


def test_output_alone_is_not_a_failure_by_default(tmp_path):
    # `debug` is a diagnostic: printing is what it is FOR, so it must not be read as a verdict.
    result = invoke(tmp_path, "debug", scripts={"debug": "x"}, yarn_mode="prints")
    assert result.returncode == 0


def test_a_script_that_exits_non_zero_fails_the_step(tmp_path):
    # A broken diagnostic is still broken. Silently passing would make it useless precisely when it
    # is needed.
    result = invoke(tmp_path, "debug", scripts={"debug": "x"}, yarn_mode="fails_quietly")
    assert result.returncode == 7


def test_a_failing_script_keeps_its_output(tmp_path):
    # The defect this extraction was written to fix. The old inline wtf step captured stdout into a
    # variable and printed it only after the exit-status check, so under `set -e` a script that
    # explained its failure and then exited non-zero had that explanation thrown away.
    result = invoke(tmp_path, "wtf", "--output-means-failure", scripts={"wtf": "x"}, yarn_mode="fails_loudly")
    assert result.returncode == 7
    assert "the explanation of the failure" in result.stdout


def test_output_means_failure_treats_printing_as_the_verdict(tmp_path):
    # `wtf`'s contract: it prints nothing when it is happy, so anything printed is an issue found.
    result = invoke(tmp_path, "wtf", "--output-means-failure", scripts={"wtf": "x"}, yarn_mode="prints")
    assert result.returncode == 1
    assert "a line of output" in result.stdout


def test_output_means_failure_passes_a_silent_script(tmp_path):
    result = invoke(tmp_path, "wtf", "--output-means-failure", scripts={"wtf": "x"}, yarn_mode="silent")
    assert result.returncode == 0


def test_a_failing_script_outranks_its_output(tmp_path):
    # Both conditions hold at once — it printed AND it exited non-zero. The exit status is the more
    # specific fact, so it is what the caller gets: "wtf found an issue" (1) and "wtf is broken" (7)
    # are different problems and must not be reported as the same one.
    result = invoke(tmp_path, "wtf", "--output-means-failure", scripts={"wtf": "x"}, yarn_mode="fails_loudly")
    assert result.returncode == 7


def test_an_unreadable_package_json_is_an_error_not_an_absent_script(tmp_path):
    # A malformed package.json makes the lookup fail, and treating that as "the script is not
    # defined" would report a broken repo as a healthy one with nothing to run. The check knows only
    # that it could not read the file, so that is what it says.
    project = tmp_path / "project"
    project.mkdir()
    (project / "package.json").write_text("{ not json")
    result = subprocess.run(["bash", str(SCRIPT), "debug"], cwd=project, capture_output=True, text=True)
    assert result.returncode != 0
    assert "package.json" in result.stderr


def test_a_missing_script_name_is_rejected(tmp_path):
    result = invoke(tmp_path, "--output-means-failure")
    assert result.returncode != 0
    assert "script name" in result.stderr


def test_an_unknown_flag_is_rejected(tmp_path):
    # Rather than being taken for a script name, which would report the far more confusing "no
    # '--verbose' script in package.json".
    result = invoke(tmp_path, "debug", "--verbose", scripts={"debug": "x"})
    assert result.returncode != 0
    assert "--verbose" in result.stderr
