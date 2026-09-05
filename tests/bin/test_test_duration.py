"""
Tests for bin/test-duration.py — per-test timings from `forge test --json`.

The shape of that JSON depends on the flags: with `--gas-report` forge emits the GAS REPORT (a list
of per-contract objects) INSTEAD of test results, so there are no durations in it at all. The tool
has to say so, because asking for both in one run looks entirely reasonable and the combination
silently answers a different question.
"""

import importlib.util
import json
import pathlib

import pytest

MODULE_PATH = pathlib.Path(__file__).resolve().parents[2] / "bin" / "test-duration.py"


def load_module():
    spec = importlib.util.spec_from_file_location("test_duration", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)  # type: ignore[attr-defined]
    return module


def results_json() -> str:
    """What `forge test --json` emits: suite id -> duration + per-test results."""
    return json.dumps(
        {
            "test/A.t.sol:ATest": {
                "duration": "2s 750ms",
                "test_results": {
                    "test_one()": {"status": "Success", "duration": "2s 500ms"},
                    "test_two()": {"status": "Success", "duration": "250ms"},
                    "test_three()": {"status": "Skipped", "duration": "0ns"},
                    "test_four()": {"status": "Failure", "reason": "assertion failed", "duration": "1ms"},
                },
            }
        }
    )


def gas_report_json() -> str:
    """What `forge test --json --gas-report` emits instead: a LIST of per-contract gas reports."""
    return json.dumps(
        [
            {
                "contract": "src/minter/Minter_v3.sol:Minter_v3",
                "deployment": {"gas": 5432033, "size": 26460},
                "functions": {"PEGGED_TOKEN()": {"calls": 6, "min": 283, "mean": 283, "median": 283, "max": 283}},
            }
        ]
    )


def test_durations_are_read_from_test_results():
    rows, _, _ = load_module().durations(json.loads(results_json()))
    milliseconds = {test: value for value, _suite, test in rows}
    assert milliseconds["test_one"] == pytest.approx(2500.0)
    assert milliseconds["test_two"] == pytest.approx(250.0)


def test_a_skipped_test_is_not_counted_as_a_failure():
    # "not Success" would report a skip as a failure, sending you looking for a break that never happened.
    _, failures, skipped = load_module().durations(json.loads(results_json()))
    assert skipped == 1
    assert len(failures) == 1
    assert "test_four" in failures[0] and "assertion failed" in failures[0]


def test_gas_report_output_is_rejected_with_an_explanation():
    # Asking for durations AND a gas report in one run is a reasonable thing to try, so the failure has
    # to name what forge actually returned and what to do about it — not surface as a shape error.
    with pytest.raises(SystemExit) as raised:
        load_module().durations(json.loads(gas_report_json()))
    message = str(raised.value)
    assert "--gas-report" in message
    assert "duration" in message.lower()
