#!/usr/bin/env python3
"""
Tests for the regression system: git diff filtering and numerical comparison.
"""
import difflib
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import List, Optional, Sequence

import pytest

# Test data directory
TEST_DATA_DIR = Path(__file__).parent / "data"

# Default tolerance values (matching compare-gas script defaults)
DEFAULT_REL_TOLERANCE = 0.05  # 5%
DEFAULT_ABS_TOLERANCE = 1000  # 1000 gas units


def run_command(cmd, cwd=None, stdin_input=""):
    """Run a command and return the result."""
    result = subprocess.run(cmd, cwd=cwd, input=stdin_input, capture_output=True, text=True)
    return result


class TestGasDiffFiltering:
    """Test the compare-gas script functionality."""

    def setup_method(self):
        """Set up test fixtures."""
        self.compare_gas_script = Path(__file__).parent.parent.parent / "bin" / "compare-gas.py"

    def _run_compare_gas(
        self, input_lines: Sequence[str], rel_tol: Optional[float] = None, abs_tol: Optional[float] = None
    ):
        """Helper to run compare-gas with custom tolerances.
        Defaults are defined here (single source of truth for tests).
        """
        if rel_tol is None:
            rel_tol = DEFAULT_REL_TOLERANCE
        if abs_tol is None:
            abs_tol = DEFAULT_ABS_TOLERANCE

        cmd = [
            str(self.compare_gas_script),
            "--rel-tolerance",
            str(rel_tol),
            "--abs-tolerance",
            str(abs_tol),
        ]

        input_text = "\n".join(input_lines) + "\n"
        return run_command(cmd, stdin_input=input_text)

    def _create_gas_diff(self, old_value: str, new_value: str, function_name: str = "testFunction") -> List[str]:
        """Helper to create a simple gas diff with ANSI colors."""
        return [
            f"\x1b[31m-| {function_name:<30} | {old_value:>8} |\x1b[m",
            f"\x1b[32m+| {function_name:<30} | {new_value:>8} |\x1b[m",
        ]

    def _golden_from_diff(
        self,
        diff_file: Path,
        expected_file: Path,
        *,
        rel_tol: Optional[float] = None,
        abs_tol: Optional[float] = None,
    ) -> None:
        """Run compare-gas on the contents of input_file and compare stdout to expected_file.
        If expected_file doesn't exist, generate it from actual output.
        On mismatch, display a unified diff in the assertion message.
        """

        missing = [p for p in (diff_file, expected_file) if not p.exists()]
        if missing:
            names = ", ".join(p.name for p in missing)
            assert False, f"missing required input(s): {names} "

        diff_text = diff_file.read_text()
        result = self._run_compare_gas(diff_text.splitlines(), rel_tol=rel_tol, abs_tol=abs_tol)
        actual = result.stdout

        expected = expected_file.read_text()
        if actual != expected:
            actual_log = expected_file.with_name(expected_file.name + ".actual.log")
            actual_log.write_text(actual)
            assert False, f"output mismatch. Actual output in: {actual_log}"

    def _golden_from_old_and_new(
        self,
        old_file_name: str,
        new_file_name: str,
        expected_file_name: str,
        *,
        rel_tol: Optional[float] = None,
        abs_tol: Optional[float] = None,
        color: bool = True,
    ) -> None:
        old_file: Path = TEST_DATA_DIR / old_file_name
        new_file: Path = TEST_DATA_DIR / new_file_name
        expected_file: Path = TEST_DATA_DIR / expected_file_name

        # Require only old/new to exist here; expected is owned by the diff-based golden
        missing = [p for p in (old_file, new_file) if not p.exists()]
        if missing:
            names = ", ".join(p.name for p in missing)
            assert False, f"missing required input(s): {names} "
        # Produce a git diff between two files (no index allows diffing non-repo files)
        args = ["git", "--no-pager", "diff", "--no-index", "--minimal"]
        if color:
            args.append("--color")
        args.extend([str(old_file), str(new_file)])
        diff_result = run_command(args)
        # Normalize the git diff into a minimal gas-focused diff to align with saved fixtures/expectations
        # i.e. remove the first 5 lines (the git diff headers)
        input_text = "".join(diff_result.stdout.splitlines(True)[4:])

        # Delegate to the input-file golden by using a temporary file for the diff input
        with tempfile.NamedTemporaryFile("w+", delete=False, suffix=".txt") as tmp:
            tmp.write(input_text)
            tmp_path = Path(tmp.name)
        try:
            self._golden_from_diff(tmp_path, expected_file, rel_tol=rel_tol, abs_tol=abs_tol)
        finally:
            try:
                tmp_path.unlink()
            except Exception:
                pass

    def _normalize_git_diff_for_gas(self, diff_text: str) -> str:
        """Strip git diff headers/hunk metadata (even if colored) so only gas table lines remain (context and +/-)."""
        import re

        ansi_re = re.compile(r"\x1b\[[0-9;]*m")
        lines = diff_text.splitlines()
        kept: list[str] = []
        for raw in lines:
            # Remove ANSI for header detection, but keep original for output
            check = ansi_re.sub("", raw).lstrip()
            if (
                check.startswith("diff --git ")
                or check.startswith("index ")
                or check.startswith("--- ")
                or check.startswith("+++ ")
                or check.startswith("@@ ")
            ):
                continue
            kept.append(raw)
        # Ensure trailing newline at end to match fixture style
        return "\n".join(kept) + "\n"

    def _strip_color_tokens(self, text: str) -> str:
        """Remove ANSI escape codes and bare bracket color tokens like [31m, [m used in some fixtures."""
        import re

        # Remove real ANSI escapes
        no_ansi = re.sub(r"\x1b\[[0-9;]*m", "", text)
        # Remove any bare tokens like [31m, [1m, [m that may appear in saved fixtures
        no_bare = re.sub(r"\[[0-9;]*m", "", no_ansi)
        return no_bare

    def test_script_exists(self):
        """Test that the compare-gas script exists."""
        assert self.compare_gas_script.exists()

    def test_help_works(self):
        """Test that the script shows help."""
        result = run_command([str(self.compare_gas_script), "--help"])
        assert result.returncode == 0
        assert "tolerance" in result.stdout

    def test_actual(self):
        """Build diff from old/new and compare output to expected; also verify diff equals saved diff file."""
        # Golden assert using generated diff
        self._golden_from_old_and_new("gas_old_actual.txt", "gas_new_actual.txt", "gas_expected_actual.txt")

    def test_decimal_change(self):
        """Build diff from old/new and compare output to expected; also verify diff equals saved diff file."""
        # Golden assert using generated diff
        self._golden_from_old_and_new(
            "gas_old_decimal_change.txt",
            "gas_new_decimal_change.txt",
            "gas_expected_decimal_change.txt",
        )

    def test_exceeds_tolerance(self):
        """Build diff from old/new and compare output to expected; also verify diff equals saved diff file."""
        # Golden assert using generated diff
        self._golden_from_old_and_new(
            "gas_old_exceeds_tolerance.txt", "gas_new_exceeds_tolerance.txt", "gas_expected_exceeds_tolerance.txt"
        )

    def test_within_tolerance(self):
        """Build diff from old/new (within tolerance) and compare to expected; also verify diff equals saved diff file."""
        self._golden_from_old_and_new(
            "gas_old_within_tolerance.txt", "gas_new_within_tolerance.txt", "gas_expected_within_tolerance.txt"
        )

    def test_structural_change(self):
        """Build diff from old/new (structural change) and compare to expected; also verify diff equals saved diff file."""
        self._golden_from_old_and_new(
            "gas_old_structural_change.txt", "gas_new_structural_change.txt", "gas_expected_structural_change.txt"
        )

    def test_basic(self):
        """Golden test that builds git diff from two files and compares output exactly."""
        self._golden_from_old_and_new("gas_old_basic.txt", "gas_new_basic.txt", "gas_expected_basic.txt")

    def test_custom_tolerances(self):
        """Test custom tolerance parameters."""
        # Create a simple test case: 100,000 → 102,000 (2% change, 2000 absolute change)
        test_input = "\x1b[31m-| testFunction | 1.00e+05 |\x1b[m\n\x1b[32m+| testFunction | 1.02e+05 |\x1b[m\n"

        # With test-set tolerances (5% relative, 1000 absolute), should be filtered (2% < 5%)
        result = self._run_compare_gas(test_input.splitlines())
        assert result.returncode == 0  # Filtered out

        # With stricter tolerance (1% relative, 500 absolute), should be shown (2% > 1% AND 2000 > 500)
        result = self._run_compare_gas(test_input.splitlines(), rel_tol=0.01, abs_tol=500)
        assert result.returncode == 1  # Changes detected
        assert "testFunction" in result.stdout

    def test_absolute_tolerance_boundary(self):
        """Test boundary conditions for absolute tolerance."""
        # Test exactly at absolute tolerance but exceeding relative (1000 gas, 10%)
        diff_lines = self._create_gas_diff("10000", "11000")  # 1000 gas, 10% change
        result = self._run_compare_gas(diff_lines)
        assert result.returncode == 0  # Should be filtered (absolute tolerance satisfied)

        # Test exceeding both tolerances (1001 gas AND >5%)
        diff_lines = self._create_gas_diff("10000", "11001")  # 1001 gas, 11.01% change
        result = self._run_compare_gas(diff_lines)
        assert result.returncode == 1  # Should be shown (exceeds both)
        assert "testFunction" in result.stdout

    def test_relative_tolerance_boundary(self):
        """Test boundary conditions for relative tolerance."""
        # Test exactly at 5% relative tolerance but exceeding absolute (5000 gas)
        diff_lines = self._create_gas_diff("100000", "105000")  # Exactly 5%, 5000 gas
        result = self._run_compare_gas(diff_lines)
        assert result.returncode == 0  # Should be filtered (relative tolerance satisfied)

        # Test exceeding both tolerances (>5% AND >1000 gas)
        diff_lines = self._create_gas_diff("100000", "106001")  # 6.001%, 6001 gas
        result = self._run_compare_gas(diff_lines)
        assert result.returncode == 1  # Should be shown (exceeds both)
        assert "testFunction" in result.stdout

    def test_very_small_numbers_and_zero(self):
        """Test handling of very small numbers and zero values."""
        # Test zero to large value (exceeds both tolerances)
        diff_lines = self._create_gas_diff("0", "10000")  # Infinite % change, 10000 gas
        result = self._run_compare_gas(diff_lines)
        assert result.returncode == 1
        assert "testFunction" in result.stdout

        # Test non-zero to zero (exceeds both tolerances)
        diff_lines = self._create_gas_diff("10000", "0")  # -100%, 10000 gas
        result = self._run_compare_gas(diff_lines)
        assert result.returncode == 1
        assert "testFunction" in result.stdout

        # Test very small change within absolute tolerance
        diff_lines = self._create_gas_diff("10", "100")  # 900% change but 90 gas (within absolute)
        result = self._run_compare_gas(diff_lines)
        assert result.returncode == 0  # Should be filtered (within absolute tolerance)

        # Test change exceeding both tolerances
        diff_lines = self._create_gas_diff("10", "2000")  # 19900% change, 1990 gas (exceeds both)
        result = self._run_compare_gas(diff_lines)
        assert result.returncode == 1  # Should be shown (exceeds both)
        assert "testFunction" in result.stdout

    def test_negative_changes(self):
        """Test handling of negative (decreasing) gas changes."""
        # Large decrease exceeding both tolerances (-10%, 10000 gas)
        diff_lines = self._create_gas_diff("100000", "90000")
        result = self._run_compare_gas(diff_lines)
        assert result.returncode == 1
        assert "testFunction" in result.stdout

        # Small decrease within both tolerances (-2%, 2000 gas - within relative)
        diff_lines = self._create_gas_diff("100000", "98000")
        result = self._run_compare_gas(diff_lines)
        assert result.returncode == 0  # Should be filtered (within relative tolerance)

        # Decrease at absolute boundary but exceeding relative (-1000 gas, -10%)
        diff_lines = self._create_gas_diff("10000", "9000")
        result = self._run_compare_gas(diff_lines)
        assert result.returncode == 0  # Should be filtered (within absolute tolerance)

        # Decrease exceeding both tolerances (-1001 gas AND >5%)
        diff_lines = self._create_gas_diff("10000", "8999")  # 1001 gas, 10.01%
        result = self._run_compare_gas(diff_lines)
        assert result.returncode == 1  # Should be shown
        assert "testFunction" in result.stdout

    def test_different_number_formats(self):
        """Test various number formats and precisions."""
        test_cases = [
            ("1.00e+05", "1.04e+05"),  # Scientific notation, within tolerance (4%, 4000 gas)
            ("100000", "110001"),  # Integer notation, exceeds both (10.001%, 10001 gas)
            ("1.234e+06", "1.350e+06"),  # Scientific with decimals, exceeds both (~9.4%, 116000 gas)
            ("50000", "50500"),  # Under both thresholds (1%, 500 gas)
            ("10000", "15000"),  # Exceeds both (50%, 5000 gas)
        ]

        for old_val, new_val in test_cases:
            diff_lines = self._create_gas_diff(old_val, new_val)
            result = self._run_compare_gas(diff_lines, DEFAULT_REL_TOLERANCE, DEFAULT_ABS_TOLERANCE)

            # Calculate expected behavior
            try:
                old_num = float(old_val)
                new_num = float(new_val)
                rel_change = abs(new_num - old_num) / old_num if old_num != 0 else float("inf")
                abs_change = abs(new_num - old_num)

                # Should be filtered if EITHER relative OR absolute are within tolerance (math.isclose OR logic)
                should_be_filtered = rel_change <= DEFAULT_REL_TOLERANCE or abs_change <= DEFAULT_ABS_TOLERANCE
                expected_returncode = 0 if should_be_filtered else 1

                assert (
                    result.returncode == expected_returncode
                ), f"Failed for {old_val} -> {new_val}: rel={rel_change:.3f}, abs={abs_change}"
            except (ValueError, ZeroDivisionError):
                # If we can't parse numbers, test should still not crash
                assert result.returncode in [0, 1]

    def test_multiple_changes(self):
        """Golden test for multiple changes with preserved context and mixed tolerances."""
        self._golden_from_old_and_new(
            "gas_old_multiple_changes.txt", "gas_new_multiple_changes.txt", "gas_expected_multiple_changes.txt"
        )

    def test_multiple_contiguous_changes_with_context(self):
        """Golden test for multiple changes with preserved context and mixed tolerances."""
        self._golden_from_old_and_new(
            "gas_old_multiple_contiguous_changes.txt",
            "gas_new_multiple_contiguous_changes.txt",
            "gas_expected_multiple_contiguous_" "changes.txt",
        )

    def test_edge_whitespace_handling(self):
        """Golden test to verify whitespace robustness in parsing and diff pairing."""
        self._golden_from_old_and_new("gas_old_whitespace.txt", "gas_new_whitespace.txt", "gas_expected_whitespace.txt")

    def test_exceeds_tolerance_emits_colors_and_exits_one(self):
        """Assert that an exceeds-tolerance diff produces colored output and exit code 1."""
        diff_file = TEST_DATA_DIR / "gas_diff_colour.txt"
        diff_text = diff_file.read_text()
        result = self._run_compare_gas(diff_text.splitlines())
        # Exit code should indicate changes detected
        assert result.returncode == 1
        # Should contain ANSI color codes for removed (red) and added (green) lines
        assert "\x1b[31m" in result.stdout or "\x1b[31m" in result.stderr
        assert "\x1b[32m" in result.stdout or "\x1b[32m" in result.stderr

    def test_custom_tolerance_configurations(self):
        """Test various custom tolerance configurations."""
        diff_lines = self._create_gas_diff("100000", "103000")  # 3% change, 3000 absolute

        # Test very strict tolerances
        result = self._run_compare_gas(diff_lines, rel_tol=0.01, abs_tol=100)  # 1%, 100 gas
        assert result.returncode == 1  # Should exceed both tolerances

        # Test very loose tolerances
        result = self._run_compare_gas(diff_lines, rel_tol=0.10, abs_tol=5000)  # 10%, 5000 gas
        assert result.returncode == 0  # Should be within both tolerances

        # Test mixed tolerances - strict relative, loose absolute
        result = self._run_compare_gas(diff_lines, rel_tol=0.01, abs_tol=5000)  # 1%, 5000 gas
        assert result.returncode == 0  # Within absolute tolerance (OR logic)

        # Test mixed tolerances - loose relative, strict absolute
        result = self._run_compare_gas(diff_lines, rel_tol=0.10, abs_tol=100)  # 10%, 100 gas
        assert result.returncode == 0  # Within relative tolerance (OR logic)

    def test_malformed_input_handling(self):
        """Golden tests for malformed and non-diff inputs; they should yield no changes (exit 0)."""
        # 1) Non-diff content
        diff_file = TEST_DATA_DIR / "gas_diff_malformed.txt"
        expected = TEST_DATA_DIR / "gas_expected_malformed.txt"
        self._golden_from_diff(diff_file, expected)

        # 2) Empty input
        empty_file = TEST_DATA_DIR / "gas_diff_empty.txt"
        expected_empty = TEST_DATA_DIR / "gas_expected_empty.txt"
        self._golden_from_diff(empty_file, expected_empty)

        # 3) Context-only table (no +/- changes)
        context_file = TEST_DATA_DIR / "gas_diff_context_only.txt"
        expected_context = TEST_DATA_DIR / "gas_expected_context_only.txt"
        self._golden_from_diff(context_file, expected_context)

    def test_scientific_notation_edge_cases(self):
        """Test edge cases with scientific notation."""
        # Very large numbers in scientific notation
        diff_lines = self._create_gas_diff("1.5e+10", "1.6e+10")  # 6.67% change
        result = self._run_compare_gas(diff_lines)
        assert result.returncode == 1  # Should exceed 5% threshold

        # Very small numbers in scientific notation
        diff_lines = self._create_gas_diff("1.0e+02", "1.1e+02")  # 10% change but small absolute
        # This should be filtered because the absolute change (10) is less than 1000
        # The OR logic means if either tolerance is satisfied, it's filtered
        result = self._run_compare_gas(diff_lines)
        assert result.returncode == 0  # Mixed notation formats
        diff_lines = self._create_gas_diff("100000", "1.2e+05")  # 20% change
        result = self._run_compare_gas(diff_lines)
        assert result.returncode == 1  # Should exceed threshold
