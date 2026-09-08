"""Tests for bin/verify-audit.py: what it reports, with what exit status, and its build primitives.

Most tests build a throwaway foundry git repo, drive it into one state, and run verify-audit over it,
asserting on the combined output and the exit status. Those are entered through `run`, as every
script under bin/ is: `run` exports the environment the script reaches other tools by
(BAO_BASE_BIN_DIR), so executing the file directly leaves that unset and the failure lands on
whichever line reaches for it first.

The last section reaches individual functions instead, for properties that are clearer pinned at the
function than inferred from a whole run - whether a signature survives a rename, and whether the
metadata guard reads `forge config` correctly.
"""

import importlib.util
import os
import subprocess
from pathlib import Path

import pytest

BAO_BASE = Path(__file__).resolve().parents[2]
RUN = BAO_BASE / "run"

_spec = importlib.util.spec_from_file_location("verify_audit", BAO_BASE / "bin" / "verify-audit.py")
verify_audit = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(verify_audit)

FOUNDRY_TOML = '[profile.default]\nsrc = "src"\nout = "out"\n'


def run_verify_audit(cwd, *args, env=None):
    """Run verify-audit in `cwd`; returns (exit status, stdout+stderr).

    `env` adds to the caller's environment, for the tests that check what the run does with a
    variable it was handed. The verbosity is pinned because `run` takes a `-q` anywhere in its
    argument list as its own quiet flag and exports the resulting level, so `run pytest -q` would
    otherwise suppress the INFO lines some of these tests assert on - and the suite's result would
    depend on how it was invoked.
    """
    done = subprocess.run(
        [str(RUN), "verify-audit", *args],
        cwd=cwd,
        capture_output=True,
        text=True,
        env={**os.environ, "BAO_BASE_VERBOSITY": "0", **(env or {})},
    )
    return done.returncode, done.stdout + done.stderr


class FoundryFixture:
    """A self-contained foundry git repo with an `origin` remote, so the script's fetch succeeds.

    `root` holds the working repo, the bare origin, and room for a clone, so one temp directory
    covers everything a test needs and pytest reclaims all of it.
    """

    def __init__(self, root: Path):
        self.root = root
        self.work = root / "work"
        self.bare = root / "origin.git"
        self.work.mkdir()
        subprocess.run(["git", "init", "-q", "--bare", str(self.bare)], check=True, capture_output=True)
        self.git("init", "-q")
        self.git("config", "user.email", "t@t")
        self.git("config", "user.name", "test")
        self.git("remote", "add", "origin", str(self.bare))
        self.write("foundry.toml", FOUNDRY_TOML)
        (self.work / "src").mkdir()

    def git(self, *args, check=True, cwd=None):
        done = subprocess.run(["git", *args], cwd=cwd or self.work, check=check, capture_output=True, text=True)
        return done.stdout.strip()

    def write(self, relpath, text):
        path = self.work / relpath
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def edit(self, relpath, old, new):
        """Replace `old` with `new` in a fixture file.

        Asserts the text was there: a fixture edit that silently matches nothing would leave the
        test asserting against a state it never created.
        """
        path = self.work / relpath
        text = path.read_text()
        assert old in text, f"{relpath} does not contain {old!r}"
        path.write_text(text.replace(old, new))

    def commit(self, message="snapshot"):
        """Commit the current state and push it, leaving it untagged; returns the commit SHA."""
        self.git("add", "-A")
        self.git("commit", "-qm", message)
        self.git("push", "-q", "origin", "HEAD", check=False)
        return self.git("rev-parse", "HEAD")

    def tag(self, name):
        """Commit the current state, tag it, and push so the script's `git fetch --tags` sees it."""
        self.git("add", "-A")
        self.git("commit", "-qm", "snapshot")
        self.git("tag", name)
        self.git("push", "-q", "origin", "HEAD", "--tags", check=False)

    def verify_audit(self, *args, cwd=None, env=None):
        """Run verify-audit over the fixture; returns (exit status, stdout+stderr)."""
        return run_verify_audit(cwd or self.work, *args, env=env)


@pytest.fixture
def fix(tmp_path):
    return FoundryFixture(tmp_path)


FOO = (
    "// SPDX-License-Identifier: MIT\n"
    "pragma solidity ^0.8.20;\n"
    "contract Foo { function f() external pure returns (uint256) { return 1; } }\n"
)


def _scope_fixture(fix):
    """src/a/X.sol and src/b/Y.sol, tagged deploy/test, for the scope-restriction tests."""
    for directory, name in (("a", "X"), ("b", "Y")):
        fix.write(
            f"src/{directory}/{name}.sol",
            "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\n"
            f"contract {name} {{ function f() external pure returns (uint256){{ return 1; }} }}\n",
        )
    fix.tag("deploy/test")


def _mispair_fixture(fix):
    """A deployed contract deleted in the same commit that adds an unrelated one of similar shape.

    Git pairs them as a rename (measured: R068), so `--diff-filter=D` yields nothing and the
    deletion is absorbed. Returns the revision to audit against.
    """
    fix.write(
        "src/Deployed.sol",
        "// SPDX-License-Identifier: MIT\n"
        "pragma solidity ^0.8.20;\n"
        "contract Deployed {\n"
        "    uint256 public constant DECIMALS = 18;\n"
        "    uint256 public constant HEARTBEAT = 3600;\n"
        "    function latestAnswer() external pure returns (uint256) { return 1234; }\n"
        '    function description() external pure returns (string memory) { return "deployed"; }\n'
        "}\n",
    )
    base = fix.commit()
    fix.git("rm", "-q", "src/Deployed.sol")
    fix.write(
        "src/Unrelated.sol",
        "// SPDX-License-Identifier: MIT\n"
        "pragma solidity ^0.8.20;\n"
        "contract Unrelated {\n"
        "    uint256 public constant DECIMALS = 18;\n"
        "    uint256 public constant HEARTBEAT = 7200;\n"
        "    function latestAnswer() external pure returns (uint256) { return 9999; }\n"
        '    function description() external pure returns (string memory) { return "unrelated"; }\n'
        "}\n",
    )
    fix.git("add", "-A")
    fix.git("commit", "-qm", "swap")
    return base


def _unpairable_by_git_fixture(fix, contract, destination):
    """A file mostly of comments, so dropping them puts similarity below git's 50% rename threshold.

    The bytecode is unchanged, so this is the case neither git nor _locate_moved can pair - the
    latter needs byte-identical content. Returns the revision to audit against.
    """
    prose = "".join(f"// explanatory prose line {i} about the pricing model and its bounds\n" for i in range(1, 41))
    body = (
        "    uint256 public constant K = 3;\n"
        "    function f(uint256 x) external pure returns (uint256) { return x + K; }\n"
    )
    fix.write(
        "src/old/Moved.sol",
        "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\n" + prose + "contract Moved {\n" + body + "}\n",
    )
    base = fix.commit()
    fix.git("rm", "-q", "src/old/Moved.sol")
    fix.write(
        destination,
        f"// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\ncontract {contract} {{\n" + body + "}\n",
    )
    fix.git("add", "-A")
    fix.git("commit", "-qm", "move")
    return base


# ── what the script reports for an unchanged, changed, or renamed source file ──────────────────────


def test_no_changes_under_src_is_green(fix):
    """A revision whose sources are untouched at HEAD passes and says nothing changed."""
    fix.write("src/Foo.sol", FOO)
    fix.tag("deploy/test")
    status, output = fix.verify_audit("deploy/test")
    assert status == 0, output
    assert "no changes under src" in output


def test_plain_modification_is_reported_as_changed(fix):
    """A change that alters bytecode, with no ignore entry, is reported and fails the run."""
    fix.write("src/Foo.sol", FOO)
    fix.tag("deploy/test")
    fix.edit("src/Foo.sol", "return 1;", "return 2;")
    fix.commit("change")
    status, output = fix.verify_audit("deploy/test")
    assert status != 0, output
    assert "CHANGED (not ignored)" in output


def test_renamed_file_with_import_only_change_is_cleared(fix):
    """A rename whose only edit is which dependency it imports does not alter bytecode."""
    for dep in ("dep1", "dep2"):
        fix.write(f"src/{dep}.sol", "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\n")
    fix.write(
        "src/Old.sol",
        "// SPDX-License-Identifier: MIT\n"
        "pragma solidity ^0.8.20;\n"
        'import "./dep1.sol";\n'
        "contract Old { function f() external pure returns (uint256) { return 1; } }\n",
    )
    fix.tag("deploy/test")
    fix.git("mv", "src/Old.sol", "src/New.sol")
    fix.edit("src/New.sol", "./dep1.sol", "./dep2.sol")
    fix.commit("reimport")
    status, output = fix.verify_audit("deploy/test")
    assert status == 0, output
    assert "auto-suppressed" in output or "cleared" in output


def test_renamed_file_with_name_and_natspec_change_clears_via_bytecode(fix):
    """A rename that also changes the contract name and a NatSpec line keeps the same bytecode."""
    body = (
        "    uint256 public constant A = 1;\n"
        "    uint256 public constant B = 2;\n"
        "    function f() external pure returns (uint256) { return 7; }\n"
        "    function g() external pure returns (uint256) { return A + B; }\n"
        "    function h(uint256 x) external pure returns (uint256) { return x * 2; }\n"
    )
    # realistically sized, so git pairs the rename (>50% similar)
    fix.write(
        "src/Old.sol",
        "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\n"
        "/// @notice old docs\ncontract Old {\n" + body + "}\n",
    )
    fix.tag("deploy/test")
    fix.git("mv", "src/Old.sol", "src/New.sol")
    fix.write(
        "src/New.sol",
        "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\n"
        "/// @notice new docs\ncontract New {\n" + body + "}\n",
    )
    fix.commit("rename")
    status, output = fix.verify_audit("deploy/test")
    assert status == 0, output
    assert "bytecode-equivalent" in output


def test_comment_and_whitespace_only_change_clears_via_bytecode(fix):
    """Added comments and reindentation never affect bytecode, so they clear."""
    fix.write(
        "src/Foo.sol",
        "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\n"
        "contract Foo {\n    function f() external pure returns (uint256) { return 1; }\n}\n",
    )
    fix.tag("deploy/test")
    fix.write(
        "src/Foo.sol",
        "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\n"
        "// a brand new explanatory comment\n"
        "contract Foo {\n        function f() external pure returns (uint256) { return 1; }\n}\n",
    )
    fix.commit("comment+reindent")
    status, output = fix.verify_audit("deploy/test")
    assert status == 0, output
    assert "bytecode-equivalent" in output


def test_constructor_only_change_fails_because_creation_bytecode_is_compared(fix):
    """An immutable's constructor value changes creation bytecode while runtime is identical."""
    fix.write(
        "src/Imm.sol",
        "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\n"
        "contract Imm {\n"
        "    uint256 public immutable X;\n"
        "    constructor() { X = 1; }\n"
        "    function f() external view returns (uint256) { return X; }\n"
        "}\n",
    )
    fix.tag("deploy/test")
    fix.edit("src/Imm.sol", "X = 1;", "X = 2;")
    fix.commit("ctor")
    status, output = fix.verify_audit("deploy/test")
    assert status != 0, output
    assert "CHANGED (not ignored)" in output


def test_deleting_a_deployed_contract_is_reported_as_drift(fix):
    """A deleted file cannot be bytecode-cleared, so its removal is reported."""
    fix.write(
        "src/Gone.sol",
        "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\n"
        "contract Gone { function f() external pure returns (uint256) { return 1; } }\n",
    )
    fix.tag("deploy/test")
    fix.git("rm", "-q", "src/Gone.sol")
    fix.git("commit", "-qm", "del")
    status, output = fix.verify_audit("deploy/test")
    assert status != 0, output
    assert "CHANGED (not ignored)" in output
    assert "src/Gone.sol" in output


# ── .verify-audit-ignore entries: what they suppress, and when they are stale ──────────────────────


def test_whole_revision_ignore_suppresses_the_revision(fix):
    """A bare revision name in the ignore file suppresses everything under that revision."""
    fix.write("src/Foo.sol", FOO)
    fix.tag("deploy/test")
    fix.edit("src/Foo.sol", "return 1;", "return 2;")
    fix.commit("change")
    fix.write(".verify-audit-ignore", "deploy/test\n")
    status, output = fix.verify_audit("deploy/test")
    assert status == 0, output
    assert "ignored via .verify-audit-ignore" in output


def test_file_level_ignore_suppresses_the_named_file(fix):
    """A revision plus file names suppresses only those files."""
    fix.write("src/Foo.sol", FOO)
    fix.tag("deploy/test")
    fix.edit("src/Foo.sol", "return 1;", "return 2;")
    fix.commit("change")
    fix.write(".verify-audit-ignore", "deploy/test src/Foo.sol\n")
    status, output = fix.verify_audit("deploy/test")
    assert status == 0, output
    assert "src/Foo.sol (ignored via .verify-audit-ignore)" in output


def test_stale_whole_revision_ignore_entry_errors(fix):
    """A whole-revision ignore for a revision with no changes is stale and must be removed."""
    fix.write("src/Foo.sol", FOO)
    fix.tag("deploy/test")
    fix.write(".verify-audit-ignore", "deploy/test\n")
    status, output = fix.verify_audit("deploy/test")
    assert status != 0, output
    assert "stale .verify-audit-ignore entry" in output


def test_stale_file_level_ignore_entry_errors(fix):
    """A named file that never changed is a stale entry, even alongside a legitimate one."""
    fix.write("src/Foo.sol", FOO)
    fix.tag("deploy/test")
    fix.edit("src/Foo.sol", "return 1;", "return 2;")
    fix.commit("change")
    fix.write(".verify-audit-ignore", "deploy/test src/Foo.sol src/Ghost.sol\n")
    status, output = fix.verify_audit("deploy/test")
    assert status != 0, output
    assert 'stale .verify-audit-ignore entry: "src/Ghost.sol"' in output


def test_ignore_entry_for_a_would_now_clear_file_is_flagged_redundant(fix):
    """An entry whose file would now clear on bytecode is redundant and must be removed."""
    fix.write(
        "src/Widget.sol",
        "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\n"
        "contract Widget {\n"
        "    uint256 public constant K = 9;\n"
        "    function f(uint256 x) external pure returns (uint256) { return x + K; }\n"
        "    function g(uint256 x) external pure returns (uint256) { return x * K; }\n"
        "}\n",
    )
    fix.tag("deploy/test")
    fix.git("mv", "src/Widget.sol", "src/WidgetV2.sol")
    fix.edit("src/WidgetV2.sol", "contract Widget ", "contract WidgetV2 ")
    fix.commit("rename")
    fix.write(".verify-audit-ignore", "deploy/test src/WidgetV2.sol\n")
    status, output = fix.verify_audit("deploy/test")
    assert status != 0, output
    assert "src/WidgetV2.sol" in output
    assert "would now clear" in output


def test_ignore_entry_for_a_genuinely_changed_file_is_kept(fix):
    """An entry suppressing a real bytecode change is doing its job and is not flagged."""
    fix.write(
        "src/Widget.sol",
        "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\n"
        "contract Widget {\n    function f() external pure returns (uint256) { return 1; }\n}\n",
    )
    fix.tag("deploy/test")
    fix.edit("src/Widget.sol", "return 1;", "return 2;")
    fix.commit("change")
    fix.write(".verify-audit-ignore", "deploy/test src/Widget.sol\n")
    status, output = fix.verify_audit("deploy/test")
    assert status == 0, output
    assert "ignored via .verify-audit-ignore" in output
    assert "would now clear" not in output


def test_ignore_entry_that_suppresses_a_deletion_is_kept(fix):
    """A deleted file cannot be built, so its entry suppresses real drift and is never flagged."""
    fix.write(
        "src/Gone.sol",
        "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\n"
        "contract Gone { function f() external pure returns (uint256) { return 1; } }\n",
    )
    fix.tag("deploy/test")
    fix.git("rm", "-q", "src/Gone.sol")
    fix.git("commit", "-qm", "del")
    fix.write(".verify-audit-ignore", "deploy/test src/Gone.sol\n")
    status, output = fix.verify_audit("deploy/test")
    assert status == 0, output
    assert "src/Gone.sol (ignored via .verify-audit-ignore)" in output
    assert "would now clear" not in output


# ── scope: which paths a revision's comparison covers ──────────────────────────────────────────────


def test_scope_restricts_the_diff_so_out_of_scope_drift_is_not_flagged(fix):
    """A declared scope limits the comparison to those directories."""
    _scope_fixture(fix)
    fix.edit("src/b/Y.sol", "return 1;", "return 2;")  # real change OUTSIDE scope
    fix.commit("change-b")
    fix.write(".verify-audit-ignore", "deploy/test {src/a}\n")
    status, output = fix.verify_audit("deploy/test")
    assert status == 0, output
    assert "Y.sol" not in output


def test_scope_still_flags_in_scope_drift(fix):
    """A scope narrows what is checked without weakening the check inside it."""
    _scope_fixture(fix)
    fix.edit("src/a/X.sol", "return 1;", "return 2;")  # real change INSIDE scope
    fix.commit("change-a")
    fix.write(".verify-audit-ignore", "deploy/test {src/a}\n")
    status, output = fix.verify_audit("deploy/test")
    assert status != 0, output
    assert "src/a/X.sol" in output


def test_ignore_entry_outside_the_declared_scope_is_an_error(fix):
    """An ignore entry for a path the scope excludes can never fire, so it is an error."""
    _scope_fixture(fix)
    fix.edit("src/b/Y.sol", "return 1;", "return 2;")
    fix.commit("change-b")
    fix.write(".verify-audit-ignore", "deploy/test {src/a} src/b/Y.sol\n")
    status, output = fix.verify_audit("deploy/test")
    assert status != 0, output
    assert "outside" in output
    assert "scope" in output


def test_manifest_scope_checks_exactly_the_deployed_contracts(fix):
    """A deployment manifest as the scope checks the contracts it lists and nothing else."""
    for directory, name in (("a", "X"), ("b", "Y")):
        fix.write(
            f"src/{directory}/{name}.sol",
            "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\n"
            f"contract {name} {{ function f() external pure returns (uint256){{ return 1; }} }}\n",
        )
    # the manifest is part of the deploy, so it exists AT the revision
    fix.write("deployments/m.json", '{"oracles":{"X":{"contractPath":"src/a/X.sol:X"}}}')
    fix.tag("deploy/test")
    fix.edit("src/a/X.sol", "return 1;", "return 2;")
    fix.edit("src/b/Y.sol", "return 1;", "return 2;")
    fix.commit("change-both")
    fix.write(".verify-audit-ignore", "deploy/test {deployments/m.json:contractPath}\n")
    status, output = fix.verify_audit("deploy/test")
    assert status != 0, output
    assert "src/a/X.sol" in output  # deployed -> in scope -> flagged
    assert "Y.sol" not in output  # not deployed -> out of scope -> not checked


def test_manifest_scope_still_pairs_renamed_deployed_contracts(fix):
    """A manifest scope does not cost the rename pairing that bytecode equivalence provides."""
    fix.write(
        "src/m/Old.sol",
        "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\n"
        "contract Old {\n"
        "  uint256 public constant K = 3;\n"
        "  function f(uint256 x) external pure returns (uint256){ return x + K; }\n"
        "}\n",
    )
    fix.write("deployments/m.json", '{"oracles":{"Old":{"contractPath":"src/m/Old.sol:Old"}}}')
    fix.tag("deploy/test")
    fix.git("mv", "src/m/Old.sol", "src/m/New.sol")
    fix.edit("src/m/New.sol", "contract Old ", "contract New ")
    fix.commit("rename")
    fix.write(".verify-audit-ignore", "deploy/test {deployments/m.json:contractPath}\n")
    status, output = fix.verify_audit("deploy/test")
    assert status == 0, output
    assert "src/m/New.sol (cleared: bytecode-equivalent)" in output


# ── resolving the revisions named on the command line ──────────────────────────────────────────────


def test_explicit_name_that_does_not_resolve_is_an_error(fix):
    """A deliberately named revision is a claim it exists; a typo must not report success."""
    fix.write("src/Foo.sol", FOO)
    fix.tag("deploy/test")
    status, output = fix.verify_audit("deploy/definitely-not-a-tag")
    assert status != 0, output
    assert "deploy/definitely-not-a-tag" in output


def test_pattern_matching_nothing_is_informational(fix):
    """A wildcard is a search, so finding nothing is a legitimate answer, not a failure."""
    fix.write("src/Foo.sol", FOO)
    fix.commit()
    status, output = fix.verify_audit("deploy*")
    assert status == 0, output
    assert "No tags match" in output


def test_commit_sha_is_resolved_and_compared(fix):
    """A repo that cuts no tags can still audit against the commit its deploy was built from."""
    fix.write("src/Foo.sol", FOO)
    base = fix.commit()
    fix.edit("src/Foo.sol", "return 1;", "return 2;")
    fix.commit("change")
    status, output = fix.verify_audit(base)
    assert status != 0, output
    assert "CHANGED (not ignored)" in output
    assert "src/Foo.sol" in output


def test_branch_name_is_resolved_and_compared(fix):
    """A branch is a valid baseline, resolved like any other revision."""
    fix.write("src/Foo.sol", FOO)
    fix.commit()
    fix.git("branch", "deploy-baseline")
    fix.edit("src/Foo.sol", "return 1;", "return 2;")
    fix.commit("change")
    status, output = fix.verify_audit("deploy-baseline")
    assert status != 0, output
    assert "CHANGED (not ignored)" in output
    assert "src/Foo.sol" in output


def test_name_that_is_both_tag_and_branch_resolves_as_the_tag(fix):
    """With the tag at the unchanged version and the branch at the changed one, the status says which.

    Resolving the branch would compare HEAD against itself and pass.
    """
    fix.write("src/Foo.sol", FOO)
    fix.tag("both")
    fix.edit("src/Foo.sol", "return 1;", "return 2;")
    fix.commit("change")
    fix.git("branch", "both", check=False)
    status, output = fix.verify_audit("both")
    assert status != 0, output
    assert "src/Foo.sol" in output
    assert "is both a tag and a branch; using the tag" in output


# ── renames git pairs by textual similarity, and what happens when it is wrong ─────────────────────


def test_renames_are_paired_despite_hostile_git_config(fix):
    """The run forces rename detection on, so a repo's diff.renames config cannot mis-report drift."""
    fix.git("config", "diff.renames", "false")
    fix.git("config", "diff.renameLimit", "1")
    for name, constant, value in (("One", "A = 1", "11"), ("Two", "B = 2", "22")):
        letter = constant.split(" ")[0]
        fix.write(
            f"src/{name}.sol",
            "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\n"
            f"contract {name} {{\n"
            f"    uint256 public constant {constant};\n"
            f"    function f() external pure returns (uint256) {{ return {value}; }}\n"
            f"    function g(uint256 x) external pure returns (uint256) {{ return x + {letter}; }}\n"
            "}\n",
        )
    fix.tag("deploy/test")
    for name in ("One", "Two"):
        fix.git("mv", f"src/{name}.sol", f"src/{name}Renamed.sol")
        fix.edit(f"src/{name}Renamed.sol", f"contract {name} ", f"contract {name}Renamed ")
    fix.commit("rename2")
    status, output = fix.verify_audit("deploy/test")
    assert status == 0, output
    assert "src/OneRenamed.sol (cleared: bytecode-equivalent)" in output
    assert "src/TwoRenamed.sol (cleared: bytecode-equivalent)" in output


def test_mispaired_deletion_is_still_named_in_the_report(fix):
    """Noticing that a deployed contract went away is the point; the old path must be named."""
    base = _mispair_fixture(fix)
    status, output = fix.verify_audit(base)
    assert status != 0, output
    assert "src/Deployed.sol" in output


def test_pairing_whose_bytecode_differs_reports_possible_mispaired_deletion(fix):
    """Bytecode cannot separate a changed contract from a mis-paired deletion, so both are stated."""
    base = _mispair_fixture(fix)
    status, output = fix.verify_audit(base)
    assert status != 0, output
    assert "src/Deployed.sol" in output and "src/Unrelated.sol" in output
    assert "removed" in output


def test_move_git_could_not_pair_is_paired_by_bytecode(fix):
    """A move below git's similarity threshold is paired on bytecode, naming both paths."""
    base = _unpairable_by_git_fixture(fix, "Renamed", "src/new/Renamed.sol")
    status, output = fix.verify_audit(base)
    assert "src/old/Moved.sol" in output
    assert "src/new/Renamed.sol" in output
    assert status == 0, output


def test_two_current_files_sharing_a_signature_is_an_ambiguity(fix):
    """A contract's name does not reach its creation bytecode, so identical bodies cannot be told apart."""
    body = (
        "  uint256 public constant K = 3;\n  function f(uint256 x) external pure returns (uint256){ return x + K; }\n"
    )
    fix.write(
        "src/old/Moved.sol",
        "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\ncontract Moved {\n" + body + "}\n",
    )
    base = fix.commit()
    fix.git("rm", "-q", "src/old/Moved.sol")
    for twin in ("Twin1", "Twin2"):
        fix.write(
            f"src/new/{twin}.sol",
            f"// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\ncontract {twin} {{\n" + body + "}\n",
        )
    fix.git("add", "-A")
    fix.git("commit", "-qm", "twins")
    status, output = fix.verify_audit(base)
    assert status != 0, output
    assert "src/old/Moved.sol" in output
    assert "more than one" in output


def test_signature_that_identifies_nothing_never_pairs(fix):
    """Abstract contracts compile to an empty creation object every such file shares."""
    fix.write(
        "src/old/Gone.sol",
        "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\n"
        "abstract contract Gone {\n  function f() external pure virtual returns (uint256);\n}\n",
    )
    base = fix.commit()
    fix.git("rm", "-q", "src/old/Gone.sol")
    fix.write(
        "src/new/Fresh.sol",
        "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\n"
        "abstract contract Fresh {\n  function g() external pure virtual returns (uint256);\n}\n",
    )
    fix.git("add", "-A")
    fix.git("commit", "-qm", "abstracts")
    status, output = fix.verify_audit(base)
    assert status != 0, output
    assert "src/old/Gone.sol" in output
    assert "src/new/Fresh.sol is the same" not in output


# ── conditions that must stop the run rather than produce a partial verdict ────────────────────────


def test_uncompilable_revision_version_is_a_loud_error(fix):
    """A revision whose sources do not compile cannot be compared, and must not pass silently."""
    fix.write(
        "src/Bad.sol",
        "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\ncontract Bad { this is not valid solidity }\n",
    )
    fix.tag("deploy/test")
    fix.write(
        "src/Bad.sol",
        "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\n"
        "contract Bad { function f() external pure returns (uint256) { return 1; } }\n",
    )
    fix.commit("fix")
    status, output = fix.verify_audit("deploy/test")
    assert status != 0, output
    assert "build at" in output


def test_shallow_clone_is_a_loud_error(fix):
    """A shallow clone holds an unknown subset of tagged commits, so the audit cannot be complete.

    The patterns would match only whatever happens to be present and the run would report success
    having checked a subset it never names - the worst outcome for a check whose job is noticing
    drift, and undetectable from the tag list itself.
    """
    fix.write(
        "src/A.sol",
        "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\n"
        "contract A { function f() external pure returns (uint256) { return 1; } }\n",
    )
    fix.tag("deploy/test")
    shallow = fix.root / "shallow"
    subprocess.run(
        ["git", "clone", "-q", "--depth=1", f"file://{fix.bare}", str(shallow)],
        check=True,
        capture_output=True,
    )
    status, output = fix.verify_audit(cwd=shallow)
    assert status != 0, output
    assert "shallow" in output


def test_revision_compiler_settings_cannot_drift_the_comparison(fix):
    """The revision's own compiler settings are not used, so they cannot change the verdict.

    The revision has via_ir off and the current tree has it on, with identical logic and a neutral
    comment change, so the file is compared and clears.
    """
    fix.write("foundry.toml", FOUNDRY_TOML.replace('out = "out"\n', 'out = "out"\nvia_ir = false\noptimizer = true\n'))
    fix.write(
        "src/Loop.sol",
        "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\n"
        "contract Loop {\n"
        "    function sum(uint256 n) external pure returns (uint256 s) {\n"
        "        for (uint256 i = 0; i < n; ++i) {\n"
        "            s += i * 2 + 1;\n"
        "        }\n"
        "    }\n"
        "}\n",
    )
    fix.tag("deploy/test")
    fix.write("foundry.toml", FOUNDRY_TOML.replace('out = "out"\n', 'out = "out"\nvia_ir = true\noptimizer = true\n'))
    # a comment-only edit, so Loop.sol shows up in the diff and actually gets compared
    (fix.work / "src/Loop.sol").write_text((fix.work / "src/Loop.sol").read_text() + "// pinned-settings test\n")
    fix.commit("settings+comment")
    status, output = fix.verify_audit("deploy/test")
    assert status == 0, output
    assert "bytecode-equivalent" in output


def test_shared_worktree_is_reused_across_multiple_revisions(fix):
    """One worktree serves every revision in a run, in chronological order, without cross-talk."""
    fix.write(
        "src/Alpha.sol",
        "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\n"
        "contract Alpha {\n"
        "    uint256 public constant K = 3;\n"
        "    function f(uint256 x) external pure returns (uint256) { return x + K; }\n"
        "}\n",
    )
    fix.tag("deploy/early")
    fix.write(
        "src/Beta.sol",
        "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\n"
        "contract Beta {\n"
        "    uint256 public constant K = 5;\n"
        "    function f(uint256 x) external pure returns (uint256) { return x * K; }\n"
        "}\n",
    )
    fix.tag("deploy/late")
    for name in ("Alpha", "Beta"):
        fix.git("mv", f"src/{name}.sol", f"src/{name}V2.sol")
        fix.edit(f"src/{name}V2.sol", f"contract {name} ", f"contract {name}V2 ")
    fix.commit("renames")
    status, output = fix.verify_audit("deploy/*")
    assert status == 0, output
    assert "src/AlphaV2.sol (cleared: bytecode-equivalent)" in output
    assert "src/BetaV2.sol (cleared: bytecode-equivalent)" in output


# ── the dependency-version check, which runs before any revision is looked at ──────────────────────


def _git(cwd, *args):
    """A git call permitted to use file:// submodule URLs, which the fixtures below are built from."""
    subprocess.run(["git", "-c", "protocol.file.allow=always", *args], cwd=cwd, check=True, capture_output=True)


def _build_conflicted(tmp_path):
    """A repo whose dependency stages a shared dependency at a different commit than it does.

    The owner is read positionally from the URL, so a directory name stands in for a GitHub
    organisation: everything lives under one `acme`, which is what makes the dependency count as
    ours. Taking a submodule named bao-base is what makes it share our toolchain. Returns the host
    repository's path.
    """
    org = tmp_path / "acme"
    org.mkdir()
    git = _git

    for name in ("shared", "bao-base"):
        (org / name).mkdir()
        git(org / name, "init", "-q")
        git(org / name, "config", "user.email", "t@t")
        git(org / name, "config", "user.name", "test")
        (org / name / "a.txt").write_text("one\n")
        git(org / name, "add", "-A")
        git(org / name, "commit", "-qm", "one")
    (org / "shared" / "a.txt").write_text("two\n")
    git(org / "shared", "add", "-A")
    git(org / "shared", "commit", "-qm", "two")

    (org / "dep").mkdir()
    git(org / "dep", "init", "-q")
    git(org / "dep", "config", "user.email", "t@t")
    git(org / "dep", "config", "user.name", "test")
    git(org / "dep", "submodule", "add", "-q", str(org / "bao-base"), "lib/bao-base")
    git(org / "dep", "submodule", "add", "-q", str(org / "shared"), "lib/shared")
    git(org / "dep/lib/shared", "checkout", "-q", "HEAD~1")  # the dependency stays on the older commit
    git(org / "dep", "add", "lib/shared")
    git(org / "dep", "commit", "-qm", "deps")

    host = org / "host"
    host.mkdir()
    git(host, "init", "-q")
    git(host, "config", "user.email", "t@t")
    git(host, "config", "user.name", "test")
    # never fetched from; it is where the owner is read
    git(host, "remote", "add", "origin", str(org / "host.git"))
    (host / "foundry.toml").write_text(FOUNDRY_TOML)
    (host / "src").mkdir()
    git(host, "add", "-A")
    git(host, "commit", "-qm", "init")
    git(host, "submodule", "add", "-q", str(org / "dep"), "lib/dep")
    git(host, "submodule", "add", "-q", str(org / "shared"), "lib/shared")
    git(host, "commit", "-qm", "deps")
    return host


@pytest.fixture
def conflicted(tmp_path):
    return _build_conflicted(tmp_path)


@pytest.fixture
def conflicted_tagged(tmp_path):
    """The conflicted repo with a source file and a real `deploy/test` tag on it.

    A revision that resolves is what makes the gate observable: without the tag, the run fails at
    revision resolution whether the gate stopped it or not, so the absence of the revision's section
    header proves nothing.
    """
    host = _build_conflicted(tmp_path)
    (host / "src" / "Foo.sol").write_text(FOO)
    _git(host, "add", "-A")
    _git(host, "commit", "-qm", "src")
    _git(host, "tag", "deploy/test")
    return host


def _make_dependencies_agree(host):
    """Move the host's shared dependency onto the commit its dependency stages, and stage that."""
    _git(host / "lib/shared", "checkout", "-q", "HEAD~1")
    _git(host, "add", "lib/shared")


def test_dependency_version_disagreement_stops_before_the_comparison(conflicted_tagged):
    """The comparison the caller asked for does not run: its section header never appears.

    The revision resolves here, so reaching the comparison is what the gate is preventing rather
    than something that was never going to happen.
    """
    status, output = run_verify_audit(conflicted_tagged, "deploy/test")
    assert status != 0, output
    assert "shared" in output  # the disagreement is named
    assert "=== deploy/test ===" not in output  # and the comparison it gates was not attempted


def test_dependency_agreement_lets_the_comparison_run(conflicted_tagged):
    """The gate opening is not the run ending: the comparison proceeds and reports on the revision."""
    _make_dependencies_agree(conflicted_tagged)
    status, output = run_verify_audit(conflicted_tagged, "deploy/test")
    assert "staged at the same commit" in output
    assert "=== deploy/test ===" in output
    assert "no changes under src" in output
    assert status == 0, output


def test_dependency_agreement_is_stated_and_the_comparison_runs(conflicted):
    """The check passing must not end the run early, and says so in one line rather than a block."""
    _make_dependencies_agree(conflicted)
    status, output = run_verify_audit(conflicted, "deploy/definitely-not-a-tag")
    assert "staged at the same commit" in output
    assert "deploy/definitely-not-a-tag" in output  # it reached the revision it could not resolve


# ── build isolation: what a run may touch, and what it may be influenced by ────────────────────────


def _a_run_that_builds(fix):
    """A revision plus a bytecode-neutral change at HEAD, so the comparison actually compiles."""
    fix.write("src/Foo.sol", FOO)
    fix.tag("deploy/test")
    fix.write("src/Foo.sol", "// a brand new explanatory comment\n" + FOO)
    fix.commit("comment")


def test_a_run_writes_no_build_artefacts_into_the_project(fix):
    """Compiling is done entirely in throwaway directories, so a run cannot disturb the project.

    Sharing the project's cache both damages it - the entries point at an out dir that is deleted
    when the run ends, so the next build recompiles - and makes the run's result depend on state any
    concurrent forge command may be rewriting.
    """
    _a_run_that_builds(fix)
    status, output = fix.verify_audit("deploy/test")
    assert status == 0, output
    assert "bytecode-equivalent" in output  # it really did compile something
    assert not (fix.work / "cache").exists(), "the run wrote forge's cache into the project"
    assert not (fix.work / "out").exists(), "the run wrote build artefacts into the project"


def test_a_caller_set_foundry_profile_is_an_error(fix):
    """A profile selects a whole foundry.toml section - src, out, optimizer, via_ir.

    Honouring it would audit under settings the deploy was never built with, and dropping it silently
    would ignore something the caller deliberately asked for. Neither is safe, so it is refused.
    """
    _a_run_that_builds(fix)
    status, output = fix.verify_audit("deploy/test", env={"FOUNDRY_PROFILE": "novyper"})
    assert status != 0, output
    assert "FOUNDRY_PROFILE" in output


def test_a_caller_set_foundry_cache_path_is_not_used(fix, tmp_path):
    """An ambient FOUNDRY_* variable cannot steer the build, shown where the effect is observable."""
    _a_run_that_builds(fix)
    ambient = tmp_path / "ambient-cache"
    ambient.mkdir()
    status, output = fix.verify_audit("deploy/test", env={"FOUNDRY_CACHE_PATH": str(ambient)})
    assert status == 0, output
    assert "bytecode-equivalent" in output
    assert list(ambient.iterdir()) == [], "the run honoured the caller's FOUNDRY_CACHE_PATH"


# ── the current tree as one snapshot, so both sides compile the same way ───────────────────────────

REMAPPED_TOML = (
    '[profile.default]\nsrc = "src"\nout = "out"\nauto_detect_remappings = false\nremappings = ["@x/={target}/"]\n'
)

DEP = (
    "// SPDX-License-Identifier: MIT\n"
    "pragma solidity ^0.8.20;\n"
    "library Dep { function v() internal pure returns (uint256) { return 5; } }\n"
)

USES_DEP = (
    "// SPDX-License-Identifier: MIT\n"
    "pragma solidity ^0.8.20;\n"
    'import {Dep} from "@x/Dep.sol";\n'
    "contract Foo { function f() external pure returns (uint256) { return Dep.v(); } }\n"
)


def _revision_needing_a_remapping(fix):
    """A revision whose source resolves only through a remapping, plus a neutral change at HEAD.

    The neutral change is what puts the file in the diff, so the comparison actually compiles both
    sides and the build environment each side used becomes observable.
    """
    fix.write("foundry.toml", REMAPPED_TOML.format(target="vendor"))
    fix.write("vendor/Dep.sol", DEP)
    fix.write("src/Foo.sol", USES_DEP)
    fix.tag("deploy/test")
    fix.write("src/Foo.sol", "// a neutral comment\n" + USES_DEP)


def test_an_uncommitted_config_fix_is_used_by_both_sides(fix):
    """The revision is compiled under the working tree's configuration, not the last commit's.

    Here the committed foundry.toml points at a directory that the same commit moved away, so it
    resolves only with the uncommitted fix - the state this tool was itself found in. Compiling the
    revision under a different configuration than the current tree is not only a build failure
    waiting to happen: a remapping that resolves a base contract elsewhere would silently manufacture
    or mask drift.
    """
    _revision_needing_a_remapping(fix)
    fix.git("mv", "vendor", "lib2")
    fix.commit("move the dependency, without the config change that follows it")
    fix.write("foundry.toml", REMAPPED_TOML.format(target="lib2"))  # the fix, left uncommitted

    status, output = fix.verify_audit("deploy/test")
    assert status == 0, output
    assert "bytecode-equivalent" in output


def test_untracked_files_reach_the_revision_build(fix):
    """Content git does not yet track is part of the current tree, so it must reach the comparison."""
    _revision_needing_a_remapping(fix)
    fix.git("rm", "-r", "-q", "vendor")
    fix.commit("remove the tracked dependency")
    fix.write("lib2/Dep.sol", DEP)  # its replacement, never staged
    fix.write("foundry.toml", REMAPPED_TOML.format(target="lib2"))

    status, output = fix.verify_audit("deploy/test")
    assert status == 0, output
    assert "bytecode-equivalent" in output


def test_a_staged_change_to_a_deployed_contract_is_reported_as_drift(fix):
    """Drift is reported from the working tree, so it does not wait for a commit to be seen."""
    fix.write("src/Foo.sol", FOO)
    fix.tag("deploy/test")
    fix.edit("src/Foo.sol", "return 1;", "return 2;")
    fix.git("add", "src/Foo.sol")  # staged, deliberately not committed

    status, output = fix.verify_audit("deploy/test")
    assert status != 0, output
    assert "CHANGED (not ignored)" in output
    assert "src/Foo.sol" in output


def test_a_snapshot_that_cannot_be_taken_is_a_loud_error(tmp_path):
    """A snapshot that fails must say so, never fall back to comparing against the last commit.

    An unborn HEAD is the reachable way to make it fail; what matters is that the failure is named
    rather than silently degrading the comparison to a different pair of trees.
    """
    repo = tmp_path / "unborn"
    repo.mkdir()
    subprocess.run(["git", "init", "-q"], cwd=repo, check=True, capture_output=True)
    (repo / "foundry.toml").write_text(FOUNDRY_TOML)
    (repo / "src").mkdir()

    status, output = run_verify_audit(repo, "deploy/test")
    assert status != 0, output
    assert "snapshot" in output


# ── the build primitives, reached directly ─────────────────────────────────────────────────────────

LOOP = (
    "// SPDX-License-Identifier: MIT\n"
    "pragma solidity ^0.8.20;\n"
    "contract Loop {\n"
    "    function sum(uint256 n) external pure returns (uint256 s) {\n"
    "        for (uint256 i = 0; i < n; ++i) {\n"
    "            s += i * 2 + 1;\n"
    "        }\n"
    "    }\n"
    "}\n"
)


def _forge_shim(directory, bytecode_hash, cbor_metadata, monkeypatch):
    """Put a `forge` on PATH that reports the given config, so the guard's reading can be driven."""
    directory.mkdir()
    shim = directory / "forge"
    shim.write_text(f"#!/bin/sh\necho 'bytecode_hash = \"{bytecode_hash}\"'\necho 'cbor_metadata = {cbor_metadata}'\n")
    shim.chmod(0o755)
    monkeypatch.setenv("PATH", f"{directory}:{os.environ['PATH']}")


def test_metadata_guard_trips_when_forge_does_not_report_the_switches_taking_effect(tmp_path, monkeypatch, capsys):
    """The guard exists so a future Foundry that renames or ignores the switches cannot pass silently."""
    _forge_shim(tmp_path / "shim", "ipfs", "true", monkeypatch)
    assert verify_audit._assert_metadata_disabled() is False
    assert "metadata not disabled" in capsys.readouterr().err


def test_metadata_guard_passes_when_forge_reports_the_switches_taking_effect(tmp_path, monkeypatch):
    """The mirror: the guard must not fail a toolchain that does disable metadata."""
    _forge_shim(tmp_path / "shim", "none", "false", monkeypatch)
    assert verify_audit._assert_metadata_disabled() is True


def test_the_snapshot_holds_the_current_tree_and_leaves_ignored_files_out(fix, monkeypatch):
    """The snapshot is the tree as it is: staged, unstaged and untracked content, minus what is
    ignored - which cannot be audited against, since git does not track it."""
    fix.write(".gitignore", "ignored/\n")
    fix.write("src/Committed.sol", FOO)
    fix.write("src/Staged.sol", FOO)
    fix.commit("base")

    fix.edit("src/Staged.sol", "return 1;", "return 2;")
    fix.git("add", "src/Staged.sol")  # staged
    fix.edit("src/Committed.sol", "return 1;", "return 3;")  # unstaged
    fix.write("src/Untracked.sol", FOO)  # never staged
    fix.write("ignored/Ignored.sol", FOO)

    monkeypatch.chdir(fix.work)
    base = verify_audit._snapshot_commit()
    assert base is not None

    listed = fix.git("ls-tree", "-r", "--name-only", base).splitlines()
    assert "src/Untracked.sol" in listed
    assert "ignored/Ignored.sol" not in listed
    assert "return 2;" in fix.git("show", f"{base}:src/Staged.sol")
    assert "return 3;" in fix.git("show", f"{base}:src/Committed.sol")


def test_the_snapshot_leaves_the_repository_index_untouched(fix, monkeypatch):
    """Taking it must not disturb a concurrent git command, nor be disturbed by one.

    `git stash create` would rewrite the index and take its lock; this builds the tree through a
    private index instead, so a held lock neither blocks it nor makes it fail.
    """
    fix.write("src/Foo.sol", FOO)
    fix.commit("base")
    fix.edit("src/Foo.sol", "return 1;", "return 2;")

    index = fix.work / ".git" / "index"
    before = (index.read_bytes(), index.stat().st_mtime_ns)

    monkeypatch.chdir(fix.work)
    lock = fix.work / ".git" / "index.lock"
    lock.touch()  # a concurrent git command holding the lock
    try:
        base = verify_audit._snapshot_commit()
    finally:
        lock.unlink()

    assert base is not None, "a held index.lock stopped the snapshot"
    assert (index.read_bytes(), index.stat().st_mtime_ns) == before


def test_file_signature_is_identical_across_a_pure_rename(fix, tmp_path, monkeypatch):
    """A signature is built from bytecode alone, so renaming a file cannot change it.

    This is the property the whole bytecode-equivalence clear rests on, pinned at the function rather
    than inferred from a run's verdict.
    """
    fix.write(
        "src/Old.sol",
        "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\n"
        "contract Old { function f() external pure returns (uint256) { return 7; } }\n",
    )
    fix.tag("deploy/test")
    fix.git("mv", "src/Old.sol", "src/New.sol")
    fix.edit("src/New.sol", "contract Old", "contract New")
    fix.commit("rename")

    monkeypatch.chdir(fix.work)
    head_out = tmp_path / "head-out"
    base = verify_audit._snapshot_commit()
    assert base is not None
    builds = verify_audit._Builds(base)
    try:
        assert verify_audit._forge_build(head_out, tmp_path / "head-cache", ["src/New.sol"])
        assert builds.ensure_worktree()
        assert builds.overlay_and_build_revision("deploy/test", ["src/Old.sol"], ["src/Old.sol"])
        signature_old = verify_audit._file_signature(builds.wt_out, "src/Old.sol")
        signature_new = verify_audit._file_signature(head_out, "src/New.sol")
        builds.restore_overlay(["src/Old.sol"])
    finally:
        builds.cleanup()

    assert verify_audit._signature_identifies(signature_old)
    assert signature_old == signature_new


def test_differing_compiler_settings_do_change_the_bytecode(fix, tmp_path, monkeypatch):
    """The control for the settings-pinning test: if via_ir stopped mattering here, that test would
    be passing vacuously.

    The setting is driven through foundry.toml, as the settings-pinning test drives it, because the
    build environment deliberately drops any FOUNDRY_* the caller had.
    """
    fix.write("src/Loop.sol", LOOP)
    monkeypatch.chdir(fix.work)

    fix.write("foundry.toml", FOUNDRY_TOML + "via_ir = false\noptimizer = true\n")
    assert verify_audit._forge_build(tmp_path / "no-ir", tmp_path / "no-ir-cache", ["src/Loop.sol"])
    fix.write("foundry.toml", FOUNDRY_TOML + "via_ir = true\noptimizer = true\n")
    assert verify_audit._forge_build(tmp_path / "via-ir", tmp_path / "via-ir-cache", ["src/Loop.sol"])

    without = verify_audit._file_signature(tmp_path / "no-ir", "src/Loop.sol")
    with_ir = verify_audit._file_signature(tmp_path / "via-ir", "src/Loop.sol")
    assert verify_audit._signature_identifies(without)
    assert without != with_ir
