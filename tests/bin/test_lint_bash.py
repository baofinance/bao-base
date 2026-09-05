"""bin/lint-bash's command-substitution check must not report arithmetic expansion.

The check finds command substitutions by looking for `$(`, which also matches the `$((` that opens an
arithmetic expansion. Arithmetic contains no command and so has no exit status to check: reporting it
asks the author to put a `disable=command-substitution` comment on correct code, and every comment
added for a false positive makes the real findings harder to pick out.
"""

import subprocess
from pathlib import Path

BAO_BASE = Path(__file__).resolve().parents[2]
RUN = BAO_BASE / "run"

FINDING = "Command substitution used as argument without error checking"


def run_lint(cwd, target):
    done = subprocess.run(
        [str(RUN), "lint-bash", "--lint", str(target)],
        cwd=cwd,
        capture_output=True,
        text=True,
    )
    return done.returncode, done.stdout + done.stderr


def lint(tmp_path, body):
    """Run bin/lint-bash over a directory holding one script, and return its combined output."""
    (tmp_path / "subject.sh").write_text("#!/usr/bin/env bash\n" + body)
    return run_lint(BAO_BASE, tmp_path)[1]


def test_arithmetic_expansion_is_not_reported(tmp_path):
    assert FINDING not in lint(tmp_path, 'index=1\necho "step $((index + 1))"\n')


def test_command_substitution_is_still_reported(tmp_path):
    # the control: without it, a check that reports nothing at all would pass the test above
    assert FINDING in lint(tmp_path, 'echo "today $(date)"\n')


def ignore_project(tmp_path, ignore_lines):
    """A directory holding one failing script, plus the .lint-bash-ignore read from the WORKING dir."""
    (tmp_path / "bin").mkdir()
    (tmp_path / "bin" / "subject.sh").write_text('#!/usr/bin/env bash\necho "today $(date)"\n')
    (tmp_path / ".lint-bash-ignore").write_text(ignore_lines)
    return tmp_path


def test_an_ignored_file_is_not_checked(tmp_path):
    project = ignore_project(tmp_path, "bin/subject.sh\n")
    status, output = run_lint(project, project / "bin")
    assert status == 0, output
    assert FINDING not in output


def test_a_file_absent_from_the_ignore_list_is_still_checked(tmp_path):
    # the control: an ignore file that excluded everything would pass the test above for the wrong reason
    project = ignore_project(tmp_path, "# nothing ignored\n")
    status, output = run_lint(project, project / "bin")
    assert status != 0
    assert FINDING in output


def test_a_stale_ignore_entry_is_reported(tmp_path):
    # the list must not outlive what it excuses, so a path that no longer exists fails the run
    project = ignore_project(tmp_path, "bin/subject.sh\nbin/deleted-long-ago.sh\n")
    status, output = run_lint(project, project / "bin")
    assert status != 0
    assert "bin/deleted-long-ago.sh" in output
