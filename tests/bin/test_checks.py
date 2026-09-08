"""bin/checks.py renders a check, and decides how much of it a reader is made to read.

The report is the product here - `yarn doctor` is read far more often than it is changed - so what is
asserted is what reaches the terminal, captured through rich rather than reasoned about. Every case
below is something that was wrong when it was read beside `yarn verify-audit`, whose whole advantage
was that it had no passing half.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "bin"))

from checks import Check, report  # noqa: E402

PASSING = Check("a passing check", "why it is here", "what ignoring it costs", [])
FAILING = Check("a failing check", "why it is here", "what ignoring it costs", ["something: is wrong"])


def printed(checks: list[Check], capsys, verbose: bool = False) -> str:
    """What reaches the terminal, minus the styling. `report` exits non-zero when anything fired, and
    that is its result rather than an error, so it is caught here and the output returned."""
    with pytest.raises(SystemExit) if any(check.problems for check in checks) else _nothing():
        report(checks, verbose=verbose)
    return capsys.readouterr().out


class _nothing:
    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False


def test_a_passing_check_is_one_line(capsys):
    # The rationale is written for a reader who has not met the check before, and that reader exists
    # on the first run. By the tenth it is prose to scroll past to reach the thing that fired.
    found = printed([PASSING], capsys)

    assert "a passing check" in found
    assert "why it is here" not in found, found


def test_verbose_says_what_every_check_is_for(capsys):
    # The first reader's flag, and exactly what this printed unconditionally before.
    found = printed([PASSING], capsys, verbose=True)

    assert "why it is here" in found, found


def test_a_failing_check_states_its_reason_without_being_asked(capsys):
    # A reader who does not know what a check is FOR cannot judge whether its failure is urgent or
    # cosmetic, so the one that fired carries its reason whatever the flag says.
    found = printed([FAILING], capsys)

    assert "why it is here" in found and "what ignoring it costs" in found, found
    assert "something: is wrong" in found


def test_the_reason_and_the_cost_are_one_sentence(capsys):
    # Both are written lowercase, to be read as one continuous explanation. Joining them with ". "
    # produced "…why it is here. what ignoring it costs" on every failing check there has ever been,
    # and only a failure ever showed it.
    found = printed([FAILING], capsys)

    assert "why it is here; what ignoring it costs" in found, found


def test_a_run_with_nothing_wrong_does_not_exit_non_zero(capsys):
    report([PASSING])  # no SystemExit to catch


def test_a_failing_check_exits_non_zero(capsys):
    # The caller is a command whose exit status IS its result, so this is raised here rather than
    # returned as a flag a caller could forget to re-raise.
    with pytest.raises(SystemExit) as exit_code:
        report([PASSING, FAILING])

    assert exit_code.value.code == 1
