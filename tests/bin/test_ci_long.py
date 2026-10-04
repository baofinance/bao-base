"""
Tests for bin/CI-long.py - test-long and then CI, into one log, for overnight.

Driven end to end through the stand-in `run` in conftest, which runs the real test-long when asked, so
the hand-over of the log between the two is exercised as it happens in a real run.
"""

import re


def test_test_long_runs_first_with_the_arguments_then_CI(bao_base):
    bao_base.run_script("CI-long", "--match-path", "test/A.t.sol")
    commands = [call["argv"][0] for call in bao_base.calls()]
    assert commands == ["test-long", "test", "test", "test", "CI"]
    for call in bao_base.calls("test"):
        assert call["argv"][-2:] == ["--match-path", "test/A.t.sol"]
    assert bao_base.calls("CI")[0]["argv"] == ["CI"]


def test_run_is_reached_inside_bao_base_where_its_directory_is_dot(bao_base):
    # "./run" must not collapse to a bare "run", which PATH lookup hands to yarn's own `run`
    result = bao_base.run_script("CI-long", in_bao_base=True)
    assert "decoy run on PATH" not in result.stdout
    assert [call["argv"][0] for call in bao_base.calls()] == ["test-long", "test", "test", "test", "CI"]
    assert result.returncode == 0


def test_test_long_and_CI_share_one_new_timestamped_log(bao_base):
    result = bao_base.run_script("CI-long")
    (log_name,) = bao_base.logs()
    assert re.fullmatch(r"CI-long-\d{8}-\d{6}\.log", log_name)
    assert bao_base.calls("test-long")[0]["argv"][1:3] == ["--log-file", f"tmp/{log_name}"]
    log = (bao_base.work / "tmp" / log_name).read_text()
    assert log.index("output of run test --fuzz-seed 1\n") < log.index("output of run CI\n")
    assert "output of run CI" in result.stdout
    assert log.rstrip().endswith("=== CI-long: test-long exit 0, CI exit 0 ===")


def test_test_long_output_is_logged_once(bao_base):
    # test-long writes the shared log itself; CI-long copying its output too would double every line
    bao_base.run_script("CI-long")
    (log_name,) = bao_base.logs()
    log = (bao_base.work / "tmp" / log_name).read_text()
    # whole lines: "--fuzz-seed 1" alone is also the start of any fresh seed beginning with 1
    assert log.splitlines().count("output of run test --fuzz-seed 1") == 1


def test_both_passing_exits_zero(bao_base):
    assert bao_base.run_script("CI-long").returncode == 0


def test_CI_still_runs_when_test_long_fails_and_the_run_fails(bao_base):
    # the morning needs CI's baselines and checks as well as the fuzz failures
    result = bao_base.run_script("CI-long", fail_seeds=["random"])
    assert len(bao_base.calls("CI")) == 1
    assert result.returncode == 1
    assert "=== CI-long: test-long exit 1, CI exit 0 ===" in result.stdout


def test_a_CI_failure_fails_the_run(bao_base):
    result = bao_base.run_script("CI-long", fail_commands=["CI"])
    assert result.returncode == 1
    assert "=== CI-long: test-long exit 0, CI exit 1 ===" in result.stdout
