"""Tests for bin/pytest.py, which `./run pytest` runs: pytest in bao-base's Python environment.

pytest reads each path from the folder it is typed in, and takes its test paths from the project's configuration
when given none. So the wrapper passes every argument unchanged, adding only `-v` when no verbosity is given.

Each test runs the wrapper from a folder outside bao-base, with `BAO_BASE_DIR` naming a folder that holds `tests/`,
as `run` sets it when typed from another repository. A stub `python3` first on PATH records the arguments it was
given and exits as told, so what reaches pytest is read back exactly. The wrapper runs directly, not through `run`,
which would run its own `python3` from PATH and so the stub.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

WRAPPER = Path(__file__).resolve().parents[2] / "bin" / "pytest.py"

# Stands in for python3. It runs under this interpreter by its absolute path, so it never finds itself on PATH.
STUB_PYTHON = """#!{interpreter}
import json, os, sys
with open(os.environ["STUB_RECORD"], "w") as record:
    json.dump(sys.argv[1:], record)
sys.exit(int(os.environ["STUB_EXIT"]))
"""


def invoke(tmp_path: Path, *args: str, exit_code: int = 0) -> tuple[subprocess.CompletedProcess, list[str] | None]:
    """Run the wrapper from `tmp_path/typed`, with `BAO_BASE_DIR` at `tmp_path/project`. Both folders hold
    `tests/test_a.py`. Returns the wrapper's completed process and the arguments the stub `python3` was given, or
    None when it was not run."""
    typed, project, stub = tmp_path / "typed", tmp_path / "project", tmp_path / "stub"
    for folder in (typed, project):
        (folder / "tests").mkdir(parents=True)
        (folder / "tests" / "test_a.py").write_text("")
    stub.mkdir()
    python = stub / "python3"
    python.write_text(STUB_PYTHON.format(interpreter=sys.executable))
    python.chmod(0o755)
    record = tmp_path / "record.json"
    completed = subprocess.run(
        [sys.executable, str(WRAPPER), *args],
        cwd=typed,
        env={
            **os.environ,
            "PATH": f"{stub}{os.pathsep}{os.environ['PATH']}",
            "BAO_BASE_DIR": str(project),
            "STUB_RECORD": str(record),
            "STUB_EXIT": str(exit_code),
        },
        capture_output=True,
        text=True,
    )
    return completed, json.loads(record.read_text()) if record.exists() else None


def test_a_long_keyword_expression_reaches_pytest_unchanged(tmp_path):
    # A `-k` expression longer than a file name can be is a value, not a path: pytest runs, and is given it as typed.
    expression = " or ".join(f"test_case_number_{i}" for i in range(20))
    assert len(expression) > 255, len(expression)

    completed, given = invoke(tmp_path, "-k", expression)

    assert completed.returncode == 0, completed.stderr
    assert given == ["-m", "pytest", "-v", "-k", expression], given


def test_an_option_value_naming_a_folder_reaches_pytest_unchanged(tmp_path):
    # `-k tests` selects by name. A folder of that name under bao-base does not make it a path.
    completed, given = invoke(tmp_path, "-k", "tests")

    assert completed.returncode == 0, completed.stderr
    assert given == ["-m", "pytest", "-v", "-k", "tests"], given


def test_a_path_reaches_pytest_as_typed(tmp_path):
    # A path is read from the folder it is typed in, as pytest reads it: one that also exists under bao-base is not
    # redirected there.
    completed, given = invoke(tmp_path, "tests/test_a.py")

    assert completed.returncode == 0, completed.stderr
    assert given == ["-m", "pytest", "-v", "tests/test_a.py"], given


def test_without_arguments_pytest_takes_its_own_test_paths(tmp_path):
    # With no path given, pytest takes `testpaths` from the project's configuration, so the wrapper adds none.
    completed, given = invoke(tmp_path)

    assert completed.returncode == 0, completed.stderr
    assert given == ["-m", "pytest", "-v"], given


def test_a_verbosity_given_is_not_added_to(tmp_path):
    # `-v` is added only when no verbosity is given: `-vv` stays as typed.
    completed, given = invoke(tmp_path, "-vv")

    assert completed.returncode == 0, completed.stderr
    assert given == ["-m", "pytest", "-vv"], given


def test_the_exit_status_is_pytests(tmp_path):
    # The wrapper's exit status is pytest's, so `yarn test:python` fails exactly when pytest does.
    completed, given = invoke(tmp_path, "tests/test_a.py", exit_code=5)

    assert given is not None, completed.stderr
    assert completed.returncode == 5, completed.stderr
