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
        """Commit the current state, tag it, and push, so origin holds the tag as this clone does."""
        self.git("add", "-A")
        self.git("commit", "-qm", "snapshot")
        self.git("tag", name)
        self.git("push", "-q", "origin", "HEAD", "--tags", check=False)

    def add_submodule(self, name, files):
        """Create a repo holding `files` and add it as a submodule at lib/<name>; returns its origin.

        The origin is a directory beside the fixture rather than inside it, so a test can make it
        unreachable and prove a run does not need it.
        """
        origin = self.root / "deps" / name
        origin.mkdir(parents=True)
        for args in (("init", "-q"), ("config", "user.email", "t@t"), ("config", "user.name", "test")):
            self.git(*args, cwd=origin)
        for relpath, text in files.items():
            path = origin / relpath
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        self.git("add", "-A", cwd=origin)
        self.git("commit", "-qm", "dependency", cwd=origin)
        self.git("-c", "protocol.file.allow=always", "submodule", "add", "-q", str(origin), f"lib/{name}")
        return origin

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
    assert "failed to compile" in output  # named as the revision's sources, not the environment
    assert "Expected identifier" in output  # and forge's own account of what is wrong with them


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


# ── what the run reads, and what it leaves to its caller ───────────────────────────────────────────


def test_a_tag_only_origin_holds_fails_the_audit_until_pulled(fix):
    """A tag cut since the last pull fails the audit, which names it and the pull that takes it.

    A stale tag list cannot be detected locally - a tag never seen leaves no trace - so origin is asked.
    A run that passed would audit fewer revisions than exist and report that nothing was wrong. Pulled,
    the audit covers it.
    """
    fix.write("src/Foo.sol", FOO)
    fix.tag("deploy/local")
    # cut only on the remote, as a colleague's tag would be
    fix.git("tag", "deploy/cut-elsewhere", cwd=fix.bare)

    status, output = fix.verify_audit("deploy/*")
    assert status == 1, output
    assert "deploy/cut-elsewhere: not here" in output
    assert "verify-audit --pull" in output

    status, output = fix.verify_audit("--pull")
    assert status == 0, output
    status, output = fix.verify_audit("deploy/*")
    assert status == 0, output
    assert "deploy/local" in output
    assert "deploy/cut-elsewhere" in output


def test_the_older_audit_fails_for_a_tag_origin_holds_as_another_object(fix):
    """Origin's copy of a tag the patterns match is another object than this clone's, so the two audit
    different things. The run names it and the pull that takes origin's copy."""
    fix.write("src/Foo.sol", FOO)
    fix.tag("deploy/test")
    fix.git("tag", "-f", "-a", "deploy/test", "-m", "another copy", fix.git("rev-parse", "HEAD"), cwd=fix.bare)

    status, output = fix.verify_audit("deploy/*")
    assert status == 1, output
    assert "deploy/test: here as another object" in output
    assert "verify-audit --pull" in output

    status, output = fix.verify_audit("--pull")
    assert status == 0, output
    status, output = fix.verify_audit("deploy/*")
    assert status == 0, output


def test_the_older_audit_names_the_fetch_for_a_tag_pull_does_not_take(fix):
    """`--pull` takes origin's copy of a deployment tag only. For any other tag held as another object,
    replacing this clone's copy is the person's, so the run names the git command that does it."""
    fix.write("src/Foo.sol", FOO)
    fix.tag("audit-1")
    fix.git("tag", "-f", "-a", "audit-1", "-m", "another copy", fix.git("rev-parse", "HEAD"), cwd=fix.bare)

    status, output = fix.verify_audit("audit*")
    assert status == 1, output
    assert "audit-1: here as another object" in output
    assert "git fetch origin +refs/tags/audit-1:refs/tags/audit-1" in output


def test_the_older_audit_changes_no_ref_here(fix):
    """The audit reads origin's tags and fetches nothing: every ref here, and the FETCH_HEAD a fetch
    writes, is as it was."""
    fix.write("src/Foo.sol", FOO)
    fix.tag("deploy/test")
    refs = fix.git("for-each-ref", "--format=%(refname) %(objectname)")
    fetch_head = fix.work / ".git" / "FETCH_HEAD"

    status, output = fix.verify_audit("deploy/*")
    assert status == 0, output
    assert fix.git("for-each-ref", "--format=%(refname) %(objectname)") == refs
    assert not fetch_head.exists(), "nothing was fetched"


def test_the_older_audit_fails_when_origin_cannot_be_asked(fix):
    """Whether this clone holds every tag the patterns match cannot be answered without origin, so a run
    that could not ask fails, in git's words: passing would say origin was looked at."""
    fix.write("src/Foo.sol", FOO)
    fix.tag("deploy/test")
    fix.git("remote", "set-url", "origin", str(fix.root / "not-a-repository"))

    status, output = fix.verify_audit("deploy/*")
    assert status == 1, output
    assert "could not ask origin for its tags" in output
    assert "not-a-repository" in output


def test_a_revision_missing_locally_names_the_pull_to_run(fix):
    """The audit fetches nothing, so a name it cannot resolve has to say how to go and get it."""
    fix.write("src/Foo.sol", FOO)
    fix.tag("deploy/test")

    status, output = fix.verify_audit("deploy/not-here-yet")
    assert status != 0, output
    assert "deploy/not-here-yet" in output
    assert "verify-audit --pull" in output


def test_a_patterns_match_count_is_reported(fix):
    """A pattern that quietly matched fewer tags than expected is how an audit checks less than it says.

    The count is stated so a stale local tag list shows up as a number the reader can disbelieve.
    """
    fix.write("src/Foo.sol", FOO)
    fix.tag("deploy/one")
    fix.write("src/Bar.sol", FOO.replace("Foo", "Bar"))
    fix.tag("deploy/two")

    status, output = fix.verify_audit("deploy/*")
    assert status == 0, output
    assert "matched 2 tags" in output


def test_imports_that_do_not_resolve_are_reported_as_an_environment_failure(fix):
    """ "The revision failed to build" reads as "that code is broken", which sends the reader to the
    wrong place when the truth is that the current configuration no longer covers what it imported.

    This is the failure that opened this whole piece of work, so the report has to separate the two
    and show what forge actually said.
    """
    fix.write("foundry.toml", REMAPPED_TOML.format(target="vendor"))
    fix.write("vendor/Dep.sol", DEP)
    fix.write("src/Foo.sol", USES_DEP)
    fix.tag("deploy/test")
    # the dependency is dropped: the current tree compiles without it, the revision cannot
    fix.write("foundry.toml", FOUNDRY_TOML)
    fix.git("rm", "-r", "-q", "vendor")
    fix.write("src/Foo.sol", FOO)
    fix.commit("drop the dependency")

    status, output = fix.verify_audit("deploy/test")
    assert status != 0, output
    assert "resolve" in output  # named as a resolution failure, not as broken revision sources
    assert "@x/Dep.sol" in output  # and forge's own account of what it could not find


# ── submodules: populated from what is already here, and only where the build reaches ──────────────

SUBMODULE_TOML = (
    "[profile.default]\n"
    'src = "src"\n'
    'out = "out"\n'
    "auto_detect_remappings = {auto_detect}\n"
    'remappings = ["@x/=lib/dep/src/"]\n'
)


@pytest.fixture
def submodule_fix(fix):
    """A revision whose source resolves through a submodule, beside one nothing remaps to."""
    fix.add_submodule("dep", {"src/Dep.sol": DEP})
    fix.add_submodule("unused", {"src/Other.sol": DEP})
    fix.write("foundry.toml", SUBMODULE_TOML.format(auto_detect="false"))
    fix.write("src/Foo.sol", USES_DEP)
    fix.tag("deploy/test")
    fix.write("src/Foo.sol", "// a neutral comment\n" + USES_DEP)
    fix.commit("comment")
    return fix


def test_a_run_does_not_need_the_submodule_remotes(submodule_fix):
    """Everything a submodule contributes is already in this clone, so no remote is consulted.

    Cloning each submodule per run is both slow - harbor has 29 of them and 363M of module stores -
    and a dependency on the network for a comparison whose inputs are all local.
    """
    (submodule_fix.root / "deps").rename(submodule_fix.root / "deps-gone")

    status, output = submodule_fix.verify_audit("deploy/test")
    assert status == 0, output
    assert "bytecode-equivalent" in output


def test_a_submodule_commit_no_remote_has_is_still_audited(submodule_fix):
    """A submodule at an unpushed commit is the normal state while developing one, not an error.

    The commit exists in this clone, which is where the audit reads it from; asking a remote for it
    would fail, and would make the tool unusable exactly when a dependency is being worked on.
    """
    submodule_fix.write("lib/dep/src/Extra.sol", DEP)
    submodule_fix.git("add", "-A", cwd=submodule_fix.work / "lib" / "dep")
    submodule_fix.git("commit", "-qm", "unpushed work", cwd=submodule_fix.work / "lib" / "dep")

    status, output = submodule_fix.verify_audit("deploy/test")
    assert status == 0, output
    assert "bytecode-equivalent" in output


def test_nested_submodule_worktree_registrations_are_cleaned_up(submodule_fix):
    """A run leaves no registration behind in any submodule it populated."""
    status, output = submodule_fix.verify_audit("deploy/test")
    assert status == 0, output
    listed = submodule_fix.git("worktree", "list", cwd=submodule_fix.work / "lib" / "dep")
    assert len(listed.splitlines()) == 1, listed


def test_the_main_submodule_checkout_and_its_edits_survive_a_run(submodule_fix):
    """A run must not disturb the submodule checkout being worked in - the hazard with real cost."""
    dep = submodule_fix.work / "lib" / "dep"
    before = submodule_fix.git("rev-parse", "HEAD", cwd=dep)
    (dep / "src" / "Dep.sol").write_text(DEP + "// work in progress\n")

    status, output = submodule_fix.verify_audit("deploy/test")
    assert status == 0, output
    assert submodule_fix.git("rev-parse", "HEAD", cwd=dep) == before
    assert "work in progress" in (dep / "src" / "Dep.sol").read_text()


def test_only_the_submodules_the_remappings_reach_are_needed(submodule_fix, monkeypatch):
    """A submodule no remapping target points into is never read, so it is never populated."""
    monkeypatch.chdir(submodule_fix.work)
    base = verify_audit._snapshot_commit()
    assert base is not None
    submodules = verify_audit._submodules(base)
    assert set(submodules) == {"lib/dep", "lib/unused"}

    needed = verify_audit._needed_submodules(submodule_fix.work, submodules)
    assert set(needed) == {"lib/dep"}


def test_auto_detected_remappings_need_every_submodule(submodule_fix, monkeypatch):
    """With auto-detection on, forge may resolve through any of them, so none can be left out."""
    submodule_fix.write("foundry.toml", SUBMODULE_TOML.format(auto_detect="true"))
    monkeypatch.chdir(submodule_fix.work)
    base = verify_audit._snapshot_commit()
    assert base is not None

    needed = verify_audit._needed_submodules(submodule_fix.work, verify_audit._submodules(base))
    assert set(needed) == {"lib/dep", "lib/unused"}


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
        built, report = verify_audit._forge_build(head_out, tmp_path / "head-cache", ["src/New.sol"])
        assert built, report
        assert builds.ensure_tree()
        built, report = builds.overlay_and_build_revision("deploy/test", ["src/Old.sol"], ["src/Old.sol"])
        assert built, report
        signature_old = verify_audit._file_signature(builds.tree_out, "src/Old.sol")
        signature_new = verify_audit._file_signature(head_out, "src/New.sol")
        builds.restore_overlay(["src/Old.sol"])
    finally:
        builds.cleanup()

    assert verify_audit._signature_identifies(signature_old)
    assert signature_old == signature_new


def test_the_tree_a_revision_is_built_in_holds_no_repository(fix, monkeypatch):
    """A `.git` in the build tree is what lets `forge build` reach back into this repository.

    Its submodules would share this repository's `.git/modules`, and forge - settling a dependency
    it judges missing, which it does unbidden - re-points every shared gitdir at a directory the run
    then deletes. What that does to the repository is pinned in
    tests/toolchain/test_forge_build_dependency_install.py; what is checked here is that this build
    tree never gives it the opening.
    """
    fix.write("src/Thing.sol", "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\ncontract Thing {}\n")
    fix.commit("a thing")

    monkeypatch.chdir(fix.work)
    base = verify_audit._snapshot_commit()
    assert base is not None
    builds = verify_audit._Builds(base)
    try:
        assert builds.ensure_tree()
        assert builds.tree is not None
        assert (builds.tree / "src" / "Thing.sol").is_file(), "the snapshot's source is there to build"
        assert list(builds.tree.rglob(".git")) == [], "and no repository came with it"
    finally:
        builds.cleanup()


def test_cleanup_leaves_no_trace_of_the_build_tree(fix, monkeypatch):
    """Deleting the directory is the whole of cleanup, so it has to actually be gone."""
    fix.write("src/Thing.sol", "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\ncontract Thing {}\n")
    fix.commit("a thing")

    monkeypatch.chdir(fix.work)
    base = verify_audit._snapshot_commit()
    assert base is not None
    builds = verify_audit._Builds(base)
    assert builds.ensure_tree()
    root = builds.root

    builds.cleanup()

    assert root is not None and not root.exists()
    # Idempotent: it runs from a `finally` that a failure earlier in the run may reach twice.
    builds.cleanup()


def test_differing_compiler_settings_do_change_the_bytecode(fix, tmp_path, monkeypatch):
    """The control for the settings-pinning test: if via_ir stopped mattering here, that test would
    be passing vacuously.

    The setting is driven through foundry.toml, as the settings-pinning test drives it, because the
    build environment deliberately drops any FOUNDRY_* the caller had.
    """
    fix.write("src/Loop.sol", LOOP)
    monkeypatch.chdir(fix.work)

    fix.write("foundry.toml", FOUNDRY_TOML + "via_ir = false\noptimizer = true\n")
    built, report = verify_audit._forge_build(tmp_path / "no-ir", tmp_path / "no-ir-cache", ["src/Loop.sol"])
    assert built, report
    fix.write("foundry.toml", FOUNDRY_TOML + "via_ir = true\noptimizer = true\n")
    built, report = verify_audit._forge_build(tmp_path / "via-ir", tmp_path / "via-ir-cache", ["src/Loop.sol"])
    assert built, report

    without = verify_audit._file_signature(tmp_path / "no-ir", "src/Loop.sol")
    with_ir = verify_audit._file_signature(tmp_path / "via-ir", "src/Loop.sol")
    assert verify_audit._signature_identifies(without)
    assert without != with_ir


def test_the_recovery_is_imported_not_spawned(fix):
    # `verify-audit` is the only command there is, and it reaches the recovery by IMPORT, running it in
    # this process - rather than spawning a second script and forwarding a child's exit code back.
    assert callable(verify_audit.run), "the work is imported by name"

    status, output = fix.verify_audit("--write")

    assert status == 0, output
    assert "nothing to recover" in output, "a fixture describing no deployment has nothing to record"


ADDRESS_AA, ADDRESS_BB = "0x" + "aa" * 20, "0x" + "bb" * 20
# When the fixture's record says its contracts were deployed, and so the name of the one tag it derives.
_DEPLOYED = "2026-01-01T00:00:00Z"
_DEPLOYMENT_TAG = f"deploy/mainnet/state@{_DEPLOYED.replace(':', '-')}"


def _record_of(head, addresses, contract="Foo"):
    """A record holding a baseline at `head` for each address, as `deployed.json`'s text."""
    import json

    return json.dumps(
        {
            "schemaVersion": 1,
            "baselines": {
                f"1/{address}": {
                    "chainId": 1,
                    "chain": "mainnet",
                    "address": address,
                    "contractType": contract,
                    "source": "src/Foo.sol",
                    "stateFiles": ["deployments/mainnet/state.json"],
                    "commit": head,
                    "commitTimestamp": "2026-01-01T00:00:00Z",
                    "deployBlock": 1,
                    "deployTimestamp": _DEPLOYED,
                    "creationBytecodeKeccak256": "a" * 64,
                    "compiler": "0.8.20+commit.a1b79de6",
                    "settings": {},
                    "sources": {},
                    "submodules": {},
                    "libraries": {},
                    "constructorArguments": "",
                }
                for address in addresses
            },
        }
    )


def _recorded(fix, contract="Foo", addresses=(ADDRESS_AA,)):
    """A repository holding deployed contracts and a baseline for each, at one commit, with nothing else
    wrong.

    Written out rather than taken from a helper because every OTHER check has to stay quiet for a test
    about one of them: each address is claimed by a manifest (so not orphaned), the source at that commit
    declares the contract (so not misnamed), and it records no source blobs (so none can be missing)."""
    import json

    # A remapping covering src/, written here rather than into the shared FOUNDRY_TOML so no other
    # test's build changes. A manifest path is normalised THROUGH foundry.toml's remappings, and an
    # entry whose path none of them covers cannot be identified at all - which makes its baseline look
    # orphaned, and a test about one check would then be failing on another.
    fix.write("foundry.toml", FOUNDRY_TOML.rstrip("\n") + '\nremappings = ["@fixture/=src/"]\n')
    fix.write("src/Foo.sol", FOO)
    head = fix.commit("the source")
    fix.write(
        "deployments/mainnet/state.json",
        json.dumps(
            {
                "network": "mainnet",
                "chainId": 1,
                "implementations": {
                    address: {
                        "contractSource": "src/Foo.sol",
                        "contractType": contract,
                        "deploymentTime": "2026-01-01T00:00:00Z",
                    }
                    for address in addresses
                },
            }
        ),
    )
    fix.write("deployed.json", _record_of(head, addresses, contract))
    # The label for the one tag the record derives: a tag is never made without one.
    fix.write("deployed-labels.toml", f'"{_DEPLOYMENT_TAG}" = "{contract}, as deployed"\n')
    return head


def test_a_missing_deployment_tag_fails_and_names_its_repair(fix):
    # The complaint that started this: it printed the finding and exited 0. A tag is what keeps a
    # recorded commit reachable once the branch holding it moves, and `--write` creates them - so it is
    # an error now, because an error is a finding with a repair.
    _recorded(fix)

    status, output = fix.verify_audit()

    assert status == 1, output
    assert any(_DEPLOYMENT_TAG in line and "not here" in line for line in output.splitlines()), (
        "it names the tag, and says what is wrong"
    )
    assert "verify-audit --pull --write" in output and "verify-audit --push" in output, (
        "and how to repair it, which is never a git tag by hand"
    )

    # THE REPAIR ITSELF, rather than a tag made by hand here. Making one proves only that the check CAN
    # be satisfied; running what the message tells you to run proves that it satisfies it. The first
    # version of this test made the tag itself, and so passed while `--write` did nothing at all.
    repaired, repairing = fix.verify_audit("--write")
    assert repaired == 0, repairing

    status, output = fix.verify_audit()

    assert status == 0, output
    assert "covers every deployed contract" in output

    # And from where CI stands: a fresh clone of origin holds only what was pushed. The clone that made
    # the tags passes whether or not they were pushed; a fresh clone passes only if they were. The tags
    # go before the branch, so the branch reaches a CI that already holds them.
    fix.git("add", "-A")
    fix.git("commit", "-qm", "the record")
    pushed, pushing = fix.verify_audit("--push")
    assert pushed == 0, pushing
    fix.git("push", "-q", "origin", "HEAD")
    fresh = fix.root / "fresh"
    fix.git("clone", "-q", str(fix.bare), str(fresh))
    status, output = fix.verify_audit(cwd=fresh)
    assert status == 0, output


def test_the_missing_tag_error_lists_each_tag_with_the_contracts_it_covers(fix):
    # Each missing tag is one to make, so the error counts tags and lists each once, with the contracts it
    # covers under it.
    _recorded(fix, addresses=(ADDRESS_AA, ADDRESS_BB))

    status, output = fix.verify_audit()

    assert status == 1, output
    assert "1 deployment tag(s)" in output and "2 deployed contract(s)" in output, output
    missing = [line for line in output.splitlines() if _DEPLOYMENT_TAG in line and "not here" in line]
    assert len(missing) == 1, "the tag is listed once, with its contracts under it"
    assert ADDRESS_AA in output.lower() and ADDRESS_BB in output.lower()


# ── the check compares the tags with what the record derives ────────────────────────────────────────
#
# A tag on each recorded commit is not enough: a deployment tag that differs from what the record derives
# is dated otherwise than its deploy, or says the wrong thing. The comparison needs nothing but the clone,
# so in CI it reads the tags GitHub holds.


def test_the_check_fails_on_a_lightweight_deployment_tag(fix):
    # The commit is preserved, but the tag carries no message: `git tag -n` shows the commit's subject.
    head = _recorded(fix)
    tag = _DEPLOYMENT_TAG
    fix.git("tag", tag, head)

    status, output = fix.verify_audit()

    assert status == 1, output
    assert tag in output and "lightweight" in output, output
    assert "verify-audit --pull --write" in output, "with the repair"


def test_the_check_fails_on_a_tag_dated_otherwise(fix):
    # The right commit and message, dated the day it was made: it no longer says when the deploy ran.
    head = _recorded(fix)
    tag = _DEPLOYMENT_TAG
    made, making = fix.verify_audit("--write")
    assert made == 0, making
    message = fix.git("for-each-ref", "--format=%(contents)", f"refs/tags/{tag}")
    fix.git("tag", "-a", "-f", tag, "-m", message, head)

    status, output = fix.verify_audit()

    assert status == 1, output
    assert tag in output and "date" in output, output


def test_the_check_fails_on_a_missing_label(fix):
    # A tag the record wants has no line in deployed-labels.toml, so `--write` could not make it.
    _recorded(fix)
    (fix.work / "deployed-labels.toml").unlink()

    status, output = fix.verify_audit()

    assert status == 1, output
    assert _DEPLOYMENT_TAG in output and "no label" in output, output
    assert "deployed-labels.toml" in output, "and says where the label goes"


def test_the_check_says_to_correct_a_label_in_error(fix):
    # A label too wide for GitHub to show whole is the person's to rewrite: `--write` adding entries does
    # nothing for it, so the repair says to correct the entry.
    _recorded(fix)
    (fix.work / "deployed-labels.toml").write_text(f'"{_DEPLOYMENT_TAG}" = "{"t" * 73}"\n')

    status, output = fix.verify_audit()

    assert status == 1, output
    assert any(_DEPLOYMENT_TAG in line and "line 1 is 73 characters, over 72" in line for line in output.splitlines())
    assert "correct each entry named above in deployed-labels.toml" in output, output


def test_the_check_wants_a_deployment_tag_beside_another_tag(fix):
    # A release tag keeps the commit reachable, but it is not the deploy's tag: it is not dated as the
    # deploy and does not say what was deployed. So the deployment tag, and its label, are still wanted.
    head = _recorded(fix)
    (fix.work / "deployed-labels.toml").unlink()
    fix.git("tag", "-a", "v1.0.0", "-m", "a release", head)

    status, output = fix.verify_audit()

    assert status == 1, output
    lines = output.splitlines()
    assert any(_DEPLOYMENT_TAG in line and "not here" in line for line in lines), output
    assert any(_DEPLOYMENT_TAG in line and "no label" in line for line in lines), output


def test_the_check_reports_a_stale_deployment_tag(fix):
    # A tag of the earlier naming, by commit, on a recorded commit: the record no longer derives it, so it
    # is reported for the person to delete.
    head = _recorded(fix)
    made, making = fix.verify_audit("--write")
    assert made == 0, making
    stale = f"deploy/mainnet/state@{head[:10]}"
    fix.git("tag", stale, head)

    status, output = fix.verify_audit()

    assert status == 1, output
    assert stale in output and "no longer derives" in output, output


def test_the_check_says_to_delete_a_stale_tag_on_origin_first(fix):
    # A stale tag on a commit no derived tag is on, so not one the tool replaces. The check reads only this
    # clone, so it cannot know whether origin holds it. Where origin does, the next fetch brings it back, so
    # the repair gives origin's deletion first, and says why.
    _recorded(fix)
    made, making = fix.verify_audit("--write")
    assert made == 0, making
    fix.git("commit", "-q", "--allow-empty", "-m", "another commit")
    stale = "deploy/mainnet/state@1999-01-01T00-00-00Z"
    fix.git("tag", stale, "HEAD")

    status, output = fix.verify_audit()

    assert status == 1, output
    lines = output.splitlines()
    there = [i for i, line in enumerate(lines) if f"git push origin --delete refs/tags/{stale}" in line]
    here = [i for i, line in enumerate(lines) if f"git tag -d {stale}" in line]
    assert there and here and there[0] < here[0], output
    assert "the next fetch brings it back" in output, output


def test_the_check_says_write_deletes_the_tags_it_replaces(fix):
    # A lightweight tag of the earlier naming, on the derived tag's commit: one the tool replaces, so the
    # repair is the tool's, not a deletion by hand.
    head = _recorded(fix)
    made, making = fix.verify_audit("--write")
    assert made == 0, making
    stale = f"deploy/mainnet/state@{head[:10]}"
    fix.git("tag", stale, head)

    status, output = fix.verify_audit()

    assert status == 1, output
    assert stale in output and "verify-audit --write" in output and "verify-audit --push" in output, output
    assert f"git tag -d {stale}" not in output, "not a deletion by hand"


def test_write_refuses_on_a_detached_head(fix):
    # The tags would land correctly - they go on the commits the record names, not on HEAD - but the
    # record could not be committed, so the repair would only ever be half done. A detached HEAD is
    # nearly always a throwaway checkout too, where leaving refs behind is a surprise.
    head = _recorded(fix)
    fix.git("checkout", "--detach", "--quiet")

    status, output = fix.verify_audit("--write")

    assert status == 1, output
    assert "detached" in output.lower(), "it says what is wrong"
    assert fix.git("tag", "--points-at", head) == "", "and wrote nothing while refusing"


def test_push_refuses_on_a_detached_head(fix):
    # One rule for both commands that write tags: they run on a branch, and a detached HEAD is nearly
    # always a throwaway checkout, where publishing refs is a surprise.
    _recorded(fix)
    fix.git("add", "-A")
    fix.git("commit", "-qm", "the record")
    fix.git("checkout", "--detach", "--quiet")

    status, output = fix.verify_audit("--push")

    assert status == 1, output
    assert "detached" in output.lower(), "it says what is wrong"
    assert fix.git("ls-remote", "--tags", "origin") == "", "and pushed nothing"


def test_pull_refuses_on_a_detached_head(fix):
    # One rule for every switch that changes refs: they run on a branch, and a detached HEAD is nearly
    # always a throwaway checkout, where replacing tags is a surprise.
    fix.write("src/Foo.sol", FOO)
    fix.tag("deploy/test")
    fix.git("tag", "-f", "-a", "deploy/test", "-m", "another copy", fix.git("rev-parse", "HEAD"), cwd=fix.bare)
    here = fix.git("rev-parse", "refs/tags/deploy/test")
    fix.git("checkout", "--detach", "--quiet")

    status, output = fix.verify_audit("--pull")

    assert status == 1, output
    assert "detached" in output.lower(), "it says what is wrong"
    assert fix.git("rev-parse", "refs/tags/deploy/test") == here, "and took nothing while refusing"


def test_pull_write_and_push_together_run_in_that_order(fix):
    # One run can do all three, in the order the work flows: origin's tags here, the record's tags here,
    # then here to origin. Origin holds the tag another clone made, which is what the record derives.
    # Pulled first, it is the tag here and the push has nothing to send. Written first, this clone would
    # make its own, and the push would fail on origin's.
    _recorded(fix)
    fix.commit("the record")
    other = fix.root / "other"
    fix.git("clone", "-q", str(fix.bare), str(other))
    status, output = run_verify_audit(other, "--write", "--push", env={"GIT_COMMITTER_NAME": "another clone"})
    assert status == 0, output
    published = fix.git("ls-remote", "origin", f"refs/tags/{_DEPLOYMENT_TAG}").split()[0]

    status, output = fix.verify_audit("--pull", "--write", "--push")

    assert status == 0, output
    assert fix.git("rev-parse", f"refs/tags/{_DEPLOYMENT_TAG}") == published


def test_write_refuses_an_argument_it_does_not_take(fix):
    # `--pull`, `--write` and `--push` take no other argument. One they ignored would read as obeyed, so it
    # is refused by name.
    _recorded(fix)

    for flag in ("--pull", "--write", "--push"):
        status, output = fix.verify_audit(flag, "--retag")

        assert status == 1, output
        assert "takes no other argument" in output and "--retag" in output, "it names what it will not take"
        assert fix.git("tag", "-l") == "", "and does nothing while refusing"


def test_write_and_push_together_refuse_the_push_when_the_record_changed(fix):
    # One run can do both, but the tags are published only from a record that is committed - the one
    # that was checked. Here the record is not committed, so the tags stay on this computer.
    head = _recorded(fix)

    status, output = fix.verify_audit("--write", "--push")

    assert status == 1, output
    assert "not committed" in output and "verify-audit --push" in output, output
    assert fix.git("tag", "--points-at", head) != "", "the tag is made here"
    assert fix.git("ls-remote", "--tags", "origin") == "", "and not pushed"


def test_write_and_push_together_push_when_the_record_is_committed(fix):
    # Nothing to recover and the record committed: one run makes, corrects and publishes the tags.
    _recorded(fix)
    fix.git("add", "-A")
    fix.git("commit", "-qm", "the record")

    status, output = fix.verify_audit("--write", "--push")

    assert status == 0, output
    assert _DEPLOYMENT_TAG in fix.git("ls-remote", "--tags", "origin")


def test_write_and_push_together_push_even_when_the_write_fails(fix):
    # Both in one run are `--write; --push`: the push is attempted whatever the write's outcome, and
    # either one failing fails the run. Here the write fails on a deployment it cannot identify, and the
    # committed record's tags still go.
    import json

    _recorded(fix)
    state = json.loads((fix.work / "deployments/mainnet/state.json").read_text())
    state["implementations"]["0x" + "cc" * 20] = {
        "contractSource": "elsewhere/Bar.sol",
        "contractType": "Bar",
        "deploymentTime": "2026-01-01T00:00:00Z",
    }
    fix.write("deployments/mainnet/state.json", json.dumps(state))
    fix.git("add", "-A")
    fix.git("commit", "-qm", "the record, and a deployment nothing can identify")

    status, output = fix.verify_audit("--write", "--push")

    assert status == 1, output
    assert "have no baseline" in output, "the write failed"
    assert _DEPLOYMENT_TAG in fix.git("ls-remote", "--tags", "origin"), "and the push still ran"


def test_a_conflicted_record_is_reported_with_its_repair(fix):
    # Two clones recorded different contracts, and merging their records conflicts. The record is
    # generated, so the repair is never an edit: keep one side whole, then let `--write` record what
    # that side lacks. The check says so, rather than stopping on a Python traceback.
    head = _recorded(fix, addresses=(ADDRESS_AA, ADDRESS_BB))
    fix.git("add", "deployments")
    fix.git("commit", "-qm", "the deployments")
    fix.git("push", "-q", "origin", "HEAD")
    other = fix.root / "other"
    fix.git("clone", "-q", str(fix.bare), str(other))
    for setting, value in (("user.email", "other@t"), ("user.name", "other")):
        fix.git("config", setting, value, cwd=other)
    (other / "deployed.json").write_text(_record_of(head, (ADDRESS_AA, ADDRESS_BB)))
    fix.git("add", "deployed.json", cwd=other)
    fix.git("commit", "-qm", "both recorded", cwd=other)
    fix.write("deployed.json", _record_of(head, (ADDRESS_AA,)))
    fix.commit("one recorded")
    pulled = subprocess.run(["git", "pull", "--no-rebase", "-q", "origin", "HEAD"], cwd=other, capture_output=True)
    assert pulled.returncode != 0, "the two records conflict"

    status, output = fix.verify_audit(cwd=other)

    assert status == 1, output
    assert "deployed.json" in output and "conflict" in output, output
    assert "git checkout --ours deployed.json" in output and "verify-audit --write" in output, output
    assert "Traceback" not in output
    status, output = fix.verify_audit("--write", cwd=other)
    assert status == 1 and "conflict" in output, "--write reads the record first, and stops the same way"

    # The repair, as the message gives it. This side holds both contracts, so `--write` has none to recover.
    fix.git("checkout", "--ours", "deployed.json", cwd=other)
    repaired, repairing = fix.verify_audit("--write", cwd=other)
    assert repaired == 0, repairing
    fix.git("add", "deployed.json", cwd=other)
    fix.git("commit", "-qm", "the records merged", cwd=other)
    pushed, pushing = fix.verify_audit("--push", cwd=other)
    assert pushed == 0, pushing
    fix.git("push", "-q", "origin", "HEAD", cwd=other)
    fresh = fix.root / "fresh"
    fix.git("clone", "-q", str(fix.bare), str(fresh))
    status, output = fix.verify_audit(cwd=fresh)
    assert status == 0, output


def test_the_record_switches_off_the_tag_comparison(fix):
    # How this converts one repository at a time. A repository WITHOUT deployed.json keeps the tag
    # comparison; one WITH it is audited by the record instead, which names the commit that built each
    # deployed contract rather than relying on a tag somebody remembered to create. Nothing is left
    # unchecked in between, and a repository converts simply by gaining the file.
    fix.write("src/Foo.sol", FOO)
    fix.tag("deploy/test")

    status, before = fix.verify_audit("deploy/test")

    assert status == 0, before
    assert "=== deploy/test ===" in before, "with no record, the tags are still what is compared"

    fix.write("deployed.json", '{"schemaVersion": 1, "baselines": {}}\n')
    fix.commit("the record arrives")

    status, after = fix.verify_audit("deploy/test")

    assert status == 0, after
    assert "=== deploy/test ===" not in after, "the record REPLACES the tag comparison rather than joining it"
    assert "covers every deployed contract" in after, "and says so in its own terms"


def test_a_signature_is_the_requested_files_own_bytecode(fix, tmp_path, monkeypatch):
    """forge writes artifacts to out/<basename>.sol/, and when two sources share a basename it NESTS
    the second under enough of its parent path to disambiguate - it does not overwrite. So both
    artifacts exist, and a lookup that only ever tries the top-level path silently returns whichever
    file happens to own it. Each file must get its own bytecode, wherever forge put it.
    """
    head = "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\n"
    body = "contract Dup {{ function f() external pure returns (uint256) {{ return {}; }} }}\n"
    fix.write("src/a/Dup.sol", head + body.format(111))
    fix.write("src/b/Dup.sol", head + body.format(222))
    fix.commit("two files, one basename")

    monkeypatch.chdir(fix.work)
    out = tmp_path / "out"
    built, report = verify_audit._forge_build(out, tmp_path / "cache", ["src/a/Dup.sol", "src/b/Dup.sol"])
    assert built, report

    signature_a = verify_audit._file_signature(out, "src/a/Dup.sol")
    signature_b = verify_audit._file_signature(out, "src/b/Dup.sol")

    assert verify_audit._signature_identifies(signature_a), signature_a
    assert verify_audit._signature_identifies(signature_b), signature_b
    assert signature_a != signature_b, "each file must get its OWN bytecode, not the other's"
    # 111 = 0x6f and 222 = 0xde, each pushed by its own contract
    assert "606f" in signature_a and "60de" not in signature_a
    assert "60de" in signature_b and "606f" not in signature_b
