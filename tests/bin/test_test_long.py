"""
Tests for bin/test-long.py - the suite run once per fuzz seed, many fuzz runs each, for overnight.

Driven end to end through the stand-in `run` in conftest, so what is asserted is what test-long asks
`run test` to do and what it leaves in its log.
"""

import re


def test_seed_1_runs_first_then_two_fresh_seeds(bao_base):
    # seed 1 is the one coverage fuzzes with; the others must be new ground
    bao_base.run_script("test-long")
    seeds = bao_base.seeds()
    assert len(seeds) == 3
    assert seeds[0] == "1"
    assert all(seed.isdigit() and seed != "1" for seed in seeds[1:])
    assert seeds[1] != seeds[2]


def test_fresh_seeds_change_from_one_run_to_the_next(bao_base):
    # a repeat of last night's seeds would only replay inputs that already passed
    bao_base.run_script("test-long", "--log-file", "first.log")
    bao_base.run_script("test-long", "--log-file", "second.log")
    seeds = bao_base.seeds()
    assert seeds[0] == seeds[3] == "1"
    assert set(seeds[1:3]).isdisjoint(seeds[4:6])


def test_each_seed_runs_the_suite_through_run_test_with_the_forge_arguments(bao_base):
    bao_base.run_script("test-long", "--match-path", "test/A.t.sol", "-vvv")
    calls = bao_base.calls()
    assert [call["argv"][0] for call in calls] == ["test", "test", "test"]
    for call, seed in zip(calls, bao_base.seeds()):
        assert call["argv"] == ["test", "--fuzz-seed", seed, "--match-path", "test/A.t.sol", "-vvv"]


def test_run_is_reached_inside_bao_base_where_its_directory_is_dot(bao_base):
    # "./run" must not collapse to a bare "run", which PATH lookup hands to yarn's own `run`
    result = bao_base.run_script("test-long", in_bao_base=True)
    assert "decoy run on PATH" not in result.stdout
    assert len(bao_base.seeds()) == 3
    assert result.returncode == 0


def test_fuzz_runs_default_to_5000(bao_base):
    bao_base.run_script("test-long")
    assert [call["fuzz_runs"] for call in bao_base.calls()] == ["5000", "5000", "5000"]


def test_fuzz_runs_follow_the_environment_when_set(bao_base):
    bao_base.run_script("test-long", env={"FOUNDRY_FUZZ_RUNS": "20000"})
    assert [call["fuzz_runs"] for call in bao_base.calls()] == ["20000", "20000", "20000"]


def test_all_seeds_passing_exits_zero_and_says_so(bao_base):
    result = bao_base.run_script("test-long")
    assert result.returncode == 0
    assert "=== test-long passed for every seed ===" in result.stdout


def test_every_seed_runs_after_the_first_fails_and_the_failure_names_it(bao_base):
    # the night's remaining seeds are worth having even once one has failed
    result = bao_base.run_script("test-long", fail_seeds=["1"])
    assert result.returncode == 1
    assert len(bao_base.seeds()) == 3
    assert "=== test-long FAILED for --fuzz-seed: 1 ===" in result.stdout


def test_several_failing_seeds_are_all_named(bao_base):
    result = bao_base.run_script("test-long", fail_seeds=["random"])
    assert result.returncode == 1
    _, second, third = bao_base.seeds()
    assert f"=== test-long FAILED for --fuzz-seed: {second} {third} ===" in result.stdout


def test_output_goes_to_the_console_and_a_new_timestamped_log(bao_base):
    result = bao_base.run_script("test-long")
    (log_name,) = bao_base.logs()
    assert re.fullmatch(r"test-long-\d{8}-\d{6}\.log", log_name)
    log = (bao_base.work / "tmp" / log_name).read_text()
    # whole lines: "--fuzz-seed 1" alone is also the start of any fresh seed beginning with 1
    log_lines = log.splitlines()
    for seed in bao_base.seeds():
        line = f"output of run test --fuzz-seed {seed}"
        assert line in log_lines
        assert line in result.stdout.splitlines()
        assert f"=== test-long --fuzz-seed {seed}, 5000 fuzz runs ===" in log_lines
    assert log.rstrip().endswith("=== test-long passed for every seed ===")


def test_a_given_log_file_is_appended_to_and_no_new_log_is_made(bao_base):
    # CI-long hands its log over this way, so what CI wrote before must survive
    log = bao_base.work / "tmp" / "shared.log"
    log.parent.mkdir()
    log.write_text("written before test-long\n")
    bao_base.run_script("test-long", "--log-file", str(log))
    assert bao_base.logs() == ["shared.log"]
    text = log.read_text()
    assert text.startswith("written before test-long\n")
    assert f"output of run test --fuzz-seed {bao_base.seeds()[2]}" in text.splitlines()
