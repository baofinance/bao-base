#!/usr/bin/env python3
"""
Tests for the regression merge, driven through its gas entry point (bin/compare-gas.py, which
sets the gas policy and calls the shared bin/compare.py).

Tolerances come from the entry script's policy, not from the file: the `# regression:` header is
OUTPUT, re-emitted each run, so a hand-edited header is overwritten rather than obeyed and a
policy change is reported by name.

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
import re
import subprocess
import sys
import tempfile
from collections.abc import Mapping
from pathlib import Path

COMPARE = Path(__file__).parent.parent.parent / "bin" / "compare-gas.py"
MODULE = COMPARE.parent / "compare.py"
DEFAULT_HEADER = "# regression: better=lower abs=500 rel=0.001 display={:.3e} ratchet=on"
# The coverage direction, driven through the CLI override since the gas entry script's policy is
# better=lower. The baseline states the same direction so the run reports no policy change and the
# test isolates the direction logic.
# Policies for tests that need something other than the shipped gas one. Each carries the header it
# will emit, so a fixture's committed header matches and a behaviour test is not satisfied by the
# policy-change report instead.
GAS = {"better": "lower", "abs": 500.0, "rel": 0.001, "display": "{:.3e}", "ratchet": True}
NO_RATCHET = dict(GAS, ratchet=False)
NO_RATCHET_HEADER = "# regression: better=lower abs=500 rel=0.001 display={:.3e} ratchet=off"
TIGHT_ABS = dict(GAS, abs=100.0)
TIGHT_ABS_HEADER = "# regression: better=lower abs=100 rel=0.001 display={:.3e} ratchet=on"
COVERAGE = dict(GAS, better="higher")
HIGHER_HEADER = "# regression: better=higher abs=500 rel=0.001 display={:.3e} ratchet=on"
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


def entry_script(policy: dict) -> str:
    """A minimal compare entry point with a given policy.

    The policy is the ONLY configuration surface — there are no command-line overrides — so a test
    that needs something other than the gas policy supplies its own entry point, exactly as a real
    regression type does.
    """
    return (
        "import sys\n"
        f"sys.path.insert(0, {str(COMPARE.parent)!r})\n"
        "import compare\n"
        f"compare.main({policy!r}, 'test policy')\n"
    )


def run_merge(committed_text: str, fresh_text: str, policy: dict | None = None) -> tuple[int, dict[str, int], str, str]:
    """Run a compare entry point on two temp files; return (returncode, merged_values, stdout, stderr).

    `policy` None runs the real `compare-gas.py`, so the default path is exercised as shipped.
    """
    with tempfile.TemporaryDirectory() as directory:
        base = Path(directory)
        (base / "committed.txt").write_text(committed_text)
        (base / "fresh.txt").write_text(fresh_text)
        if policy is None:
            script = COMPARE
        else:
            script = base / "entry.py"
            script.write_text(entry_script(policy))
        # Run under the same interpreter as the test so pandas/forge_tables (bin uv env) resolve.
        result = subprocess.run(
            [sys.executable, str(script), str(base / "committed.txt"), str(base / "fresh.txt")],
            capture_output=True,
            text=True,
        )
    return result.returncode, _merged_values(result.stdout), result.stdout, result.stderr


def run_mutated_module(module_text: str, committed_text: str, fresh_text: str) -> tuple[int, dict[str, int]]:
    """Run the real entry script against a MUTATED copy of the shared compare module.

    The mutated compare.py and an unmodified copy of the entry script share a temp dir, so the
    entry script's own `sys.path.insert(0, dirname(__file__))` resolves `import compare` to the
    mutant there; PYTHONPATH supplies the real bin dir for forge_tables and pandas.
    """
    with tempfile.TemporaryDirectory() as directory:
        base = Path(directory)
        (base / MODULE.name).write_text(module_text)
        (base / COMPARE.name).write_text(COMPARE.read_text())
        (base / "committed.txt").write_text(committed_text)
        (base / "fresh.txt").write_text(fresh_text)
        env = dict(os.environ)
        env["PYTHONPATH"] = str(COMPARE.parent) + os.pathsep + env.get("PYTHONPATH", "")
        result = subprocess.run(
            [
                sys.executable,
                str(base / COMPARE.name),
                str(base / "committed.txt"),
                str(base / "fresh.txt"),
            ],
            capture_output=True,
            text=True,
            env=env,
        )
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
    # Gas ratchets: even a 1-unit improvement is flagged and locked in, so the baseline stays anchored
    # at the best value achieved and a later regression is measured from there rather than from a
    # stale higher one. Flagging an improvement is the point — it is what forces the win to be
    # recorded, so the ratchet actually ratchets.
    rc, vals, _, _ = run_merge(committed({"foo": 100000}), fresh({"foo": 99999}))
    assert rc == 1
    assert vals["foo"] == 99999


def test_an_improvement_is_labelled_improved():
    _, _, _, err = run_merge(committed({"foo": 100000}), fresh({"foo": 50000}))
    assert "improved" in err
    assert "regressed" not in err


def test_an_improvement_is_labelled_improved_without_the_ratchet_too():
    # Without the ratchet an improvement beyond tolerance takes the same branch as a regression, so
    # the label has to come from the direction rather than from which branch was taken.
    _, vals, _, err = run_merge(
        committed({"foo": 100000}, header=NO_RATCHET_HEADER), fresh({"foo": 50000}), NO_RATCHET
    )
    assert vals["foo"] == 50000
    assert "improved" in err
    assert "regressed" not in err


def test_a_small_improvement_is_held_without_the_ratchet():
    rc, vals, _, _ = run_merge(
        committed({"foo": 100000}, header=NO_RATCHET_HEADER), fresh({"foo": 99999}), NO_RATCHET
    )
    assert rc == 0
    assert vals["foo"] == 100000


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


# ── the tolerances come from the entry script's policy, not the file ─────────

def test_policy_emitted_into_header():
    # The emitted header states the policy the run actually applied, whatever the input said.
    loose = "# regression: better=lower abs=1000 rel=0.01 display={:.3e}"
    _, _, out, _ = run_merge(committed({"foo": 100000}, header=loose), fresh({"foo": 100000}))
    assert DEFAULT_HEADER in out


def test_hand_edited_header_is_overwritten():
    # A loosened header does NOT loosen the applied tolerance: +500 on 100000 breaks the policy's
    # rel (0.1%) and is flagged, even though the file's own header would have held it.
    loose = "# regression: better=lower abs=1000 rel=0.01 display={:.3e}"
    rc, vals, _, _ = run_merge(committed({"foo": 100000}, header=loose), fresh({"foo": 100500}))
    assert rc == 1
    assert vals["foo"] == 100500


def test_policy_change_is_reported():
    # The policy lives in a shared submodule, so a change to it can move every regression file with
    # the reason recorded elsewhere. Name the old and new values rather than silently re-emitting.
    loose = "# regression: better=lower abs=1000 rel=0.01 display={:.3e}"
    rc, _, _, err = run_merge(committed({"foo": 100000}, header=loose), fresh({"foo": 100000}))
    assert rc == 1  # the header line itself changed, so the file must be committed
    assert "policy changed" in err
    assert "1000" in err and "500" in err  # abs: old -> new
    assert "0.01" in err and "0.001" in err  # rel: old -> new


def test_cli_overrides_policy():
    rc, vals, _, _ = run_merge(committed({"foo": 100000}, header=TIGHT_ABS_HEADER), fresh({"foo": 100500}), TIGHT_ABS)
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
    rc, vals, _, _ = run_merge(committed({"cov": 8000}, header=HIGHER_HEADER), fresh({"cov": 9000}), COVERAGE)
    assert rc == 1  # an increase is the improvement for coverage -> ratchet
    assert vals["cov"] == 9000


def test_better_higher_holds_a_within_tolerance_decrease():
    rc, vals, _, _ = run_merge(committed({"cov": 800000}, header=HIGHER_HEADER), fresh({"cov": 799600}), COVERAGE)
    assert rc == 0  # -400 is a regression side, within abs(500) AND rel(800) -> held
    assert vals["cov"] == 800000


# ── the baseline comes from the git INDEX, so staging a regression file is enough ────

REGRESSION_OF = COMPARE.parent / "regression-of"
BASELINE_RE = re.compile(r"git show (\S+) 2>/dev/null")
FIXTURE_FILE = "regression/f.txt"


def baseline_via_script_expression(committed: str, staged: str | None, worktree: str | None) -> str:
    """What regression-of's OWN baseline expression yields for a repo in the given states.

    The ref is extracted from the script rather than restated here, so these tests exercise the
    expression the script actually runs — not merely git's behaviour.
    """
    refs = BASELINE_RE.findall(REGRESSION_OF.read_text())
    assert refs, "regression-of has no `git show … 2>/dev/null` baseline read"
    assert len(set(refs)) == 1, f"baseline read sites disagree on the ref: {sorted(set(refs))}"
    with tempfile.TemporaryDirectory() as directory:

        def git(*args):
            subprocess.run(["git", *args], cwd=directory, check=True, capture_output=True)

        target = Path(directory) / FIXTURE_FILE
        target.parent.mkdir(parents=True)
        git("init", "-q", ".")
        git("config", "user.email", "test@example.com")
        git("config", "user.name", "test")
        target.write_text(committed)
        git("add", "-A")
        git("commit", "-qm", "baseline")
        if staged is not None:
            target.write_text(staged)
            git("add", FIXTURE_FILE)
        if worktree is not None:
            target.write_text(worktree)
        result = subprocess.run(
            ["bash", "-c", f'REGRESSION_FILE="{FIXTURE_FILE}"; git show {refs[0]} 2>/dev/null'],
            cwd=directory,
            capture_output=True,
            text=True,
        )
        return result.stdout


def test_all_baseline_read_sites_use_the_same_ref():
    # The tolerance path and the exact-diff path (which reads twice) must agree, or a staged file
    # would be the baseline for one comparison and not the other.
    refs = BASELINE_RE.findall(REGRESSION_OF.read_text())
    assert len(refs) == 3
    assert len(set(refs)) == 1


def test_baseline_read_from_index_when_staged():
    assert baseline_via_script_expression("COMMITTED", staged="STAGED", worktree=None) == "STAGED"


def test_baseline_falls_back_to_head_when_nothing_staged():
    # One code path serves both cases: with a clean index the index ref IS the committed content.
    assert baseline_via_script_expression("COMMITTED", staged=None, worktree=None) == "COMMITTED"


def test_unstaged_edit_is_not_the_baseline():
    # Editing the regression file in the working tree must not move the baseline — only staging does.
    assert baseline_via_script_expression("COMMITTED", staged="STAGED", worktree="WORKTREE") == "STAGED"


def test_no_change_does_not_restore_the_working_tree():
    # A no-regression run must leave the working tree alone. `git restore --worktree` was removed: it
    # silently discards any uncommitted edit to the regression file, so a check that finds no
    # regression could wipe the developer's working copy. Writing only on a real change means there is
    # nothing to restore — so no CODE path may invoke it (comments may still mention the removal).
    code_lines = [line for line in REGRESSION_OF.read_text().splitlines() if not line.lstrip().startswith("#")]
    assert not any("git restore" in line for line in code_lines), "git restore must not run in any code path"


# ── discrimination guard: prove, on every run, that the tests kill known logic mutations ──────

def test_suite_kills_mutants():
    """Every listed logic mutation of the shared compare module must change a scenario's result.

    This is the in-suite, every-run version of a one-off mutation check: if a mutant produces the
    same answer as the real script, the tests do NOT discriminate it — a gap to close, not a
    harmless mutation. Each mutation is paired with a scenario an existing test also exercises.
    """
    src = MODULE.read_text()
    scenarios = {
        "rel_breach": (committed({"foo": 100000}), fresh({"foo": 100200})),  # within abs, breaks rel
        "decrease": (committed({"foo": 100000}), fresh({"foo": 99990})),  # improvement within tolerance
        "abs_edge": (committed({"foo": 10_000_000}), fresh({"foo": 10_000_500})),  # at abs, rel loose
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
        mutant = run_mutated_module(src.replace(find, repl, 1), committed_text, fresh_text)
        assert mutant != correct, f"MUTATION SURVIVED — the tests do not discriminate: {find!r} -> {repl!r}"
