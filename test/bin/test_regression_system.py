#!/usr/bin/env python3
"""
Tests for the regression merge (bin/compare-gas.py).

The merge takes two files — the committed baseline and the freshly-extracted values — and
writes a merged baseline, per (section, row), with:
  - a ratchet on the "better" side (an improvement is ALWAYS locked in, so the baseline stays
    anchored at the best value and within-tolerance creep can't hide a real regression);
  - an abs-AND-rel tolerance on the other side (a regression within BOTH is held, no churn;
    breaking EITHER flags it and locks in the new value);
  - structural add/remove flagged;
  - a header-less (old-format) baseline migrated to the new format without crashing.
Exit 1 iff anything changed; only flagged rows differ from the committed baseline.
"""
import os
import subprocess
import sys
import tempfile
from collections.abc import Mapping
from pathlib import Path

COMPARE = Path(__file__).parent.parent.parent / "bin" / "compare-gas.py"
DEFAULT_HEADER = "# regression: better=lower abs=500 rel=0.001 display={:.3e}"
PATH = "src/X.sol:X"


def committed(rows: Mapping[str, float], header: str = DEFAULT_HEADER, path: str = PATH) -> str:
    """Build a new-format baseline file (header + exact + display) from {name: value}."""
    lines = [header, path, "| function name | max | display |", "|---|---|---|"]
    lines += [f"| {name} | {int(v)} | {v:.3e} |" for name, v in rows.items()]
    return "\n".join(lines) + "\n"


def old_format(rows: Mapping[str, float], path: str = PATH) -> str:
    """Build an old-format baseline: no header, scientific values, 2 columns."""
    lines = [path, "| function name | max |", "|---|---|"]
    lines += [f"| {name} | {v:.3e} |" for name, v in rows.items()]
    return "\n".join(lines) + "\n"


def fresh(rows: Mapping[str, float], path: str = PATH) -> str:
    """Build a freshly-extracted file: no header, exact integers, 2 columns."""
    lines = [path, "| function name | max |", "|---|---|"]
    lines += [f"| {name} | {int(v)} |" for name, v in rows.items()]
    return "\n".join(lines) + "\n"


def run_merge(committed_text: str, fresh_text: str, *extra_args: str) -> tuple[int, dict[str, int], str, str]:
    """Run compare-gas.py on two temp files; return (returncode, merged_values, stdout, stderr)."""
    with tempfile.NamedTemporaryFile("w", suffix=".committed", delete=False) as c, tempfile.NamedTemporaryFile(
        "w", suffix=".fresh", delete=False
    ) as f:
        c.write(committed_text)
        f.write(fresh_text)
        c_path, f_path = c.name, f.name
    # Run under the same interpreter as the test so pandas/forge_tables (bin uv env) resolve.
    result = subprocess.run(
        [sys.executable, str(COMPARE), c_path, f_path, *extra_args], capture_output=True, text=True
    )
    Path(c_path).unlink(missing_ok=True)
    Path(f_path).unlink(missing_ok=True)
    return result.returncode, _merged_values(result.stdout), result.stdout, result.stderr


def run_source_result(source_text: str, committed_text: str, fresh_text: str) -> tuple[int, dict[str, int]]:
    """Run a (possibly mutated) copy of compare-gas.py; return (returncode, merged_values).

    The mutated copy sits in a temp dir, so `import forge_tables` is resolved by putting the
    real bin dir on PYTHONPATH.
    """
    paths: list[str] = []
    for suffix, text in ((".py", source_text), (".committed", committed_text), (".fresh", fresh_text)):
        handle = tempfile.NamedTemporaryFile("w", suffix=suffix, delete=False)
        handle.write(text)
        handle.close()
        paths.append(handle.name)
    src_path, c_path, f_path = paths
    env = dict(os.environ)
    env["PYTHONPATH"] = str(COMPARE.parent) + os.pathsep + env.get("PYTHONPATH", "")
    result = subprocess.run([sys.executable, src_path, c_path, f_path], capture_output=True, text=True, env=env)
    for p in paths:
        Path(p).unlink(missing_ok=True)
    return result.returncode, _merged_values(result.stdout)


def _merged_values(stdout: str) -> dict[str, int]:
    """Parse the merged output back into {name: int value} (the exact 'max' column)."""
    out = {}
    for line in stdout.splitlines():
        s = line.strip()
        if not s.startswith("|"):
            continue
        cells = [c.strip() for c in s.strip("|").split("|")]
        if len(cells) < 2 or cells[0].lower() == "function name" or set(cells[0]) <= set("-: "):
            continue
        try:
            out[cells[0]] = int(float(cells[1]))
        except ValueError:
            pass
    return out


# ── the merge exists and is callable ────────────────────────────────────────

def test_script_exists():
    assert COMPARE.exists()


def test_help_mentions_tolerance():
    r = subprocess.run([sys.executable, str(COMPARE), "--help"], capture_output=True, text=True)
    assert r.returncode == 0
    assert "tolerance" in r.stdout


# ── the tolerance: within BOTH holds; breaking EITHER flags (abs-AND-rel) ─────

def test_within_both_tolerances_is_held():
    # +50 on 100000: within abs (<=500) AND within rel (<=100.05). Held, no change.
    rc, vals, _, _ = run_merge(committed({"foo": 100000}), fresh({"foo": 100050}))
    assert rc == 0
    assert vals["foo"] == 100000  # committed value preserved


def test_absolute_breach_flags_and_locks_in():
    # +600 on 100000: breaks abs (600 > 500). Flag and adopt the new value.
    rc, vals, _, _ = run_merge(committed({"foo": 100000}), fresh({"foo": 100600}))
    assert rc == 1
    assert vals["foo"] == 100600


def test_relative_breach_flags_even_when_within_abs():
    # +200 on 100000: within abs (<=500) but breaks rel (200 > 0.1% = 100.2). Break-either -> flag.
    rc, vals, _, _ = run_merge(committed({"foo": 100000}), fresh({"foo": 100200}))
    assert rc == 1
    assert vals["foo"] == 100200


def test_abs_boundary_pinned():
    # rel is loose here (0.1% of 10M = 10000), so the abs edge is the discriminator:
    # +500 (== abs) is held; +501 (> abs) is flagged. Pins the abs threshold to the unit.
    rc_in, vals_in, _, _ = run_merge(committed({"foo": 10_000_000}), fresh({"foo": 10_000_500}))
    assert (rc_in, vals_in["foo"]) == (0, 10_000_000)
    rc_out, vals_out, _, _ = run_merge(committed({"foo": 10_000_000}), fresh({"foo": 10_000_501}))
    assert (rc_out, vals_out["foo"]) == (1, 10_000_501)


def test_rel_boundary_pinned():
    # abs is loose here (both deltas < 500), so the rel edge is the discriminator:
    # +100 (== 0.1% of 100k) is held; +101 (> rel) is flagged. Pins the rel threshold to the unit.
    rc_in, vals_in, _, _ = run_merge(committed({"foo": 100000}), fresh({"foo": 100100}))
    assert (rc_in, vals_in["foo"]) == (0, 100000)
    rc_out, vals_out, _, _ = run_merge(committed({"foo": 100000}), fresh({"foo": 100101}))
    assert (rc_out, vals_out["foo"]) == (1, 100101)


# ── the ratchet: ANY improvement is locked in ────────────────────────────────

def test_any_decrease_is_ratcheted_in():
    # even a 1-unit improvement is locked in — the ratchet keeps the baseline anchored at the best.
    rc, vals, _, _ = run_merge(committed({"foo": 100000}), fresh({"foo": 99999}))
    assert rc == 1
    assert vals["foo"] == 99999


# ── structural changes ───────────────────────────────────────────────────────

def test_added_row_flags():
    rc, vals, _, _ = run_merge(committed({"foo": 100000}), fresh({"foo": 100000, "bar": 5000}))
    assert rc == 1
    assert vals == {"foo": 100000, "bar": 5000}


def test_removed_row_flags_and_drops():
    rc, vals, _, _ = run_merge(committed({"foo": 100000, "bar": 5000}), fresh({"foo": 100000}))
    assert rc == 1
    assert "bar" not in vals


def test_no_change_holds_everything():
    rc, vals, out, _ = run_merge(committed({"foo": 100000, "bar": 5000}), fresh({"foo": 100000, "bar": 5000}))
    assert rc == 0
    assert vals == {"foo": 100000, "bar": 5000}


# ── the tolerances come from the header, and can be overridden ───────────────

def test_header_tolerance_is_used_not_the_defaults():
    # A loose header holds a +500 change that the DEFAULT rel (0.1%) would flag.
    loose = "# regression: better=lower abs=1000 rel=0.01 display={:.3e}"
    rc, vals, _, _ = run_merge(committed({"foo": 100000}, header=loose), fresh({"foo": 100500}))
    assert rc == 0
    assert vals["foo"] == 100000


def test_cli_overrides_header():
    loose = "# regression: better=lower abs=1000 rel=0.01 display={:.3e}"
    rc, vals, _, _ = run_merge(committed({"foo": 100000}, header=loose), fresh({"foo": 100500}), "--abs-tolerance", "100")
    assert rc == 1
    assert vals["foo"] == 100500


# ── old-format baseline: migrate, don't crash ────────────────────────────────

def test_old_format_migrates_and_fires_a_diff():
    rc, vals, out, err = run_merge(old_format({"foo": 100000}), fresh({"foo": 100000}))
    assert rc == 1  # migration is a change to commit
    assert "# regression:" in out  # header materialised
    assert vals["foo"] == 100000  # exact value adopted from fresh
    assert "migrat" in err.lower()


def test_scientific_values_parse():
    # Large scientific value in an old-format baseline round-trips through the migration.
    rc, vals, _, _ = run_merge(old_format({"foo": 1.5e10}), fresh({"foo": 16_000_000_000}))
    assert rc == 1
    assert vals["foo"] == 16_000_000_000


# ── zero / small values don't divide by zero and behave sanely ───────────────

def test_zero_to_zero_is_held():
    rc, vals, _, _ = run_merge(committed({"foo": 0}), fresh({"foo": 0}))
    assert rc == 0
    assert vals["foo"] == 0


def test_zero_to_nonzero_flags():
    rc, vals, _, _ = run_merge(committed({"foo": 0}), fresh({"foo": 100}))
    assert rc == 1
    assert vals["foo"] == 100


# ── better=higher (coverage direction) inverts improvement vs regression ──────

def test_better_higher_locks_in_an_increase():
    hdr = "# regression: better=higher abs=500 rel=0.001 display={:.1f}"
    rc, vals, _, _ = run_merge(committed({"cov": 8000}, header=hdr), fresh({"cov": 9000}))
    assert rc == 1  # an increase is the improvement for coverage -> ratchet
    assert vals["cov"] == 9000


def test_better_higher_holds_a_within_tolerance_decrease():
    hdr = "# regression: better=higher abs=500 rel=0.001 display={:.1f}"
    rc, vals, _, _ = run_merge(committed({"cov": 800000}, header=hdr), fresh({"cov": 799600}))
    assert rc == 0  # -400 is a regression side, within abs(500) AND rel(800) -> held
    assert vals["cov"] == 800000


# ── discrimination guard: prove, on every run, that the tests kill known logic mutations ──────

def test_suite_kills_mutants():
    """Every listed logic mutation of compare-gas.py must change a scenario's result.

    This is the in-suite, every-run version of a one-off mutation check: if a mutant produces the
    same answer as the real script, the tests do NOT discriminate it — a gap to close, not a
    harmless mutation. Each mutation is paired with a scenario an existing test also exercises.
    """
    src = COMPARE.read_text()
    scenarios = {
        "rel_breach": (committed({"foo": 100000}), fresh({"foo": 100200})),  # within abs, breaks rel
        "decrease": (committed({"foo": 100000}), fresh({"foo": 99990})),  # improvement within tolerance
        "abs_edge": (committed({"foo": 10_000_000}), fresh({"foo": 10_000_500})),  # exactly at abs, rel loose
    }
    mutants = [
        ("and delta <= rel_tol", "or delta <= rel_tol", "rel_breach"),  # AND -> OR (the old lenient logic)
        ('changes.append((path, name, "improved", old, new))', "pass", "decrease"),  # drop the ratchet flag
        ("(new < old) if better_lower", "(new > old) if better_lower", "decrease"),  # flip the better direction
        ("delta <= abs_tol", "delta < abs_tol", "abs_edge"),  # off-by-one at the abs edge
        ("out[name] = new  # ratchet", "out[name] = old  # ratchet", "decrease"),  # lock in the wrong value
    ]
    for find, repl, scenario in mutants:
        assert src.count(find) == 1, f"mutation guard is stale — {find!r} no longer appears exactly once"
        committed_text, fresh_text = scenarios[scenario]
        correct = run_merge(committed_text, fresh_text)[:2]
        mutant = run_source_result(src.replace(find, repl, 1), committed_text, fresh_text)
        assert mutant != correct, f"MUTATION SURVIVED — the tests do not discriminate: {find!r} -> {repl!r}"
