"""Tests for bin/pinned-pragma.js: every deployable declaration in a Solidity source pins one compiler version.

A deployable declaration is a contract that is not abstract, or a library with a public or external function
(a library of internal functions is compiled into the code that uses it and is never deployed on its own). A
pinned pragma names a single exact version, `0.8.30` or `=0.8.30`. A pragma that allows more than one version
leaves the choice to whichever compilers a machine has installed, which is what the check exists to prevent.

The check reads source text with @solidity-parser/parser and never builds, so its verdict cannot depend on the
compilers installed either. These tests run the real script on small source trees in a temporary directory.
"""

import shutil
import subprocess
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "bin" / "pinned-pragma.js"


def write(root: Path, relative: str, text: str) -> None:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def check(root: Path, *arguments: str, environment: dict | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(["node", str(SCRIPT), *arguments], cwd=root, capture_output=True, text=True, env=environment)


def contract(name: str, pragma: str) -> str:
    return f"pragma solidity {pragma};\ncontract {name} {{\n    function f() external {{}}\n}}\n"


def test_a_contract_pinned_to_one_version_passes(tmp_path):
    # the accepted form: one exact version
    write(tmp_path, "src/Exact.sol", contract("Exact", "0.8.30"))
    result = check(tmp_path, "src")
    assert result.returncode == 0, result.stdout + result.stderr


def test_an_equals_sign_before_the_version_still_pins_it(tmp_path):
    # `=0.8.30` allows exactly one version, the same as `0.8.30`
    write(tmp_path, "src/EqualsExact.sol", contract("EqualsExact", "=0.8.30"))
    result = check(tmp_path, "src")
    assert result.returncode == 0, result.stdout + result.stderr


def test_a_caret_pragma_on_a_contract_fails(tmp_path):
    # `^0.8.30` allows every later 0.8 release
    write(tmp_path, "src/Caret.sol", contract("Caret", "^0.8.30"))
    result = check(tmp_path, "src")
    assert result.returncode == 1
    assert "src/Caret.sol: deployable contract 'Caret' has pragma '^0.8.30'" in result.stdout


def test_a_range_pragma_on_a_contract_fails(tmp_path):
    # a bounded range allows more than one version
    write(tmp_path, "src/Ranged.sol", contract("Ranged", ">=0.8.28 <0.9.0"))
    result = check(tmp_path, "src")
    assert result.returncode == 1
    assert "src/Ranged.sol: deployable contract 'Ranged'" in result.stdout


def test_a_contract_beside_an_abstract_base_is_still_checked(tmp_path):
    # deployability is decided per declaration: an abstract base in the same file exempts nothing
    write(
        tmp_path,
        "src/WithBase.sol",
        "pragma solidity >=0.8.28 <0.9.0;\n"
        "abstract contract Base {\n    function f() external virtual;\n}\n"
        "contract WithBase is Base {\n    function f() external override {}\n}\n",
    )
    result = check(tmp_path, "src")
    assert result.returncode == 1
    assert "src/WithBase.sol: deployable contract 'WithBase'" in result.stdout
    assert "'Base'" not in result.stdout


def test_an_abstract_contract_inside_a_comment_does_not_exempt_the_file(tmp_path):
    # commented-out code is not a declaration
    write(
        tmp_path,
        "src/Commented.sol",
        "pragma solidity >=0.8.28 <0.9.0;\n/*\nabstract contract Old {}\n*/\n"
        "contract Commented {\n    function f() external {}\n}\n",
    )
    result = check(tmp_path, "src")
    assert result.returncode == 1
    assert "src/Commented.sol: deployable contract 'Commented'" in result.stdout


def test_a_library_with_an_external_function_is_deployable_even_when_the_signature_spans_lines(tmp_path):
    # `external` on a later line of a multi-line signature still makes the library deployable
    write(
        tmp_path,
        "src/Checks.sol",
        "pragma solidity >=0.8.28 <0.9.0;\n"
        "library Checks {\n"
        "    function check(\n        address target,\n        string memory name\n"
        "    ) external view returns (bool) {\n"
        "        return target != address(0) && bytes(name).length > 0;\n"
        "    }\n"
        "}\n",
    )
    result = check(tmp_path, "src")
    assert result.returncode == 1
    assert "src/Checks.sol: deployable library 'Checks'" in result.stdout


def test_a_library_with_a_public_function_is_deployable(tmp_path):
    # a public library function is called through a deployed library, like an external one
    write(
        tmp_path,
        "src/Shared.sol",
        "pragma solidity ^0.8.30;\n"
        "library Shared {\n    function twice(uint256 x) public pure returns (uint256) {\n        return 2 * x;\n    }\n}\n",
    )
    result = check(tmp_path, "src")
    assert result.returncode == 1
    assert "src/Shared.sol: deployable library 'Shared'" in result.stdout


def test_a_library_of_internal_functions_may_keep_a_range(tmp_path):
    # an internal library is compiled into its users, whose own pragmas fix the compiler
    write(
        tmp_path,
        "src/Inlined.sol",
        "pragma solidity >=0.8.28 <0.9.0;\n"
        "library Inlined {\n    function twice(uint256 x) internal pure returns (uint256) {\n        return 2 * x;\n    }\n}\n",
    )
    result = check(tmp_path, "src")
    assert result.returncode == 0, result.stdout + result.stderr


def test_interfaces_and_abstract_contracts_may_keep_a_range(tmp_path):
    # neither is deployed, so a range is how they stay usable across compiler versions
    write(
        tmp_path,
        "src/Shapes.sol",
        "pragma solidity >=0.8.28 <0.9.0;\n"
        "interface IShape {\n    function area() external view returns (uint256);\n}\n"
        "abstract contract Shape is IShape {}\n",
    )
    result = check(tmp_path, "src")
    assert result.returncode == 0, result.stdout + result.stderr


def test_a_deployable_contract_without_a_pragma_fails(tmp_path):
    # no pragma allows every compiler version
    write(tmp_path, "src/Unpragmad.sol", "contract Unpragmad {\n    function f() external {}\n}\n")
    result = check(tmp_path, "src")
    assert result.returncode == 1
    assert "src/Unpragmad.sol: deployable contract 'Unpragmad' has no solidity pragma" in result.stdout


def test_every_solidity_pragma_in_the_file_must_be_exact(tmp_path):
    # a second, looser version pragma is still a range written into the file
    write(
        tmp_path,
        "src/Twice.sol",
        "pragma solidity 0.8.30;\npragma solidity >=0.8.0;\ncontract Twice {\n    function f() external {}\n}\n",
    )
    result = check(tmp_path, "src")
    assert result.returncode == 1
    assert "src/Twice.sol: deployable contract 'Twice' has pragma '>=0.8.0'" in result.stdout


def test_other_pragmas_are_not_version_pragmas(tmp_path):
    # `pragma abicoder v2` says nothing about the compiler version
    write(
        tmp_path,
        "src/Abicoder.sol",
        "pragma solidity 0.8.30;\npragma abicoder v2;\ncontract Abicoder {\n    function f() external {}\n}\n",
    )
    result = check(tmp_path, "src")
    assert result.returncode == 0, result.stdout + result.stderr


def test_a_source_that_does_not_parse_fails(tmp_path):
    # an unreadable file is a failure, never a silent pass
    write(tmp_path, "src/Broken.sol", "pragma solidity 0.8.30;\ncontract Broken { function f( }\n")
    result = check(tmp_path, "src")
    assert result.returncode == 1
    assert "src/Broken.sol: does not parse" in result.stdout


def test_an_ignored_file_is_reported_and_not_failed(tmp_path):
    # a .validate-ignore `pragma` entry exempts its file, visibly
    write(tmp_path, "src/Legacy.sol", contract("Legacy", "^0.8.20"))
    result = check(tmp_path, "--ignore", "src/Legacy.sol", "src")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "src/Legacy.sol: pragma check ignored via .validate-ignore" in result.stdout


def test_an_ignore_entry_for_a_file_that_passes_is_reported_as_stale(tmp_path):
    # an exemption for a file that passes is reported, so it cannot hide a range added later
    write(tmp_path, "src/Fixed.sol", contract("Fixed", "0.8.30"))
    result = check(tmp_path, "--ignore", "src/Fixed.sol", "src")
    assert result.returncode == 1
    assert 'stale .validate-ignore entry: pragma "src/Fixed.sol"' in result.stdout


def test_a_tree_with_no_sources_passes(tmp_path):
    # zero files: nothing to report
    (tmp_path / "src").mkdir()
    result = check(tmp_path, "src")
    assert result.returncode == 0, result.stdout + result.stderr


def test_every_failing_file_is_reported_in_path_order(tmp_path):
    # several files, nested directories included: each failure is reported once, passing files are not
    write(tmp_path, "src/b/Second.sol", contract("Second", "^0.8.30"))
    write(tmp_path, "src/a/First.sol", contract("First", ">=0.8.0"))
    write(tmp_path, "src/Fine.sol", contract("Fine", "0.8.30"))
    result = check(tmp_path, "src")
    assert result.returncode == 1
    reported = [line for line in result.stdout.splitlines() if "deployable contract" in line]
    assert len(reported) == 2, result.stdout
    assert "src/a/First.sol" in reported[0]
    assert "src/b/Second.sol" in reported[1]
    assert "Fine" not in result.stdout


def test_the_check_needs_no_compiler(tmp_path):
    # nothing but node is reachable, so no solc or forge can take part in the verdict
    write(tmp_path, "src/Exact.sol", contract("Exact", "0.8.30"))
    write(tmp_path, "src/Caret.sol", contract("Caret", "^0.8.30"))
    (tmp_path / "home").mkdir()
    only_node = {"PATH": str(Path(shutil.which("node")).parent), "HOME": str(tmp_path / "home")}
    result = check(tmp_path, "src", environment=only_node)
    assert result.returncode == 1, result.stdout + result.stderr
    assert "src/Caret.sol: deployable contract 'Caret'" in result.stdout
    assert "'Exact'" not in result.stdout
