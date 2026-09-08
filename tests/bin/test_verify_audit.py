"""End-to-end tests for bin/verify-audit: what it reports, and with what exit status.

Each test builds a throwaway foundry git repo, drives it into one state, and runs verify-audit over
it, asserting on the combined output and the exit status. Entered through `run`, as every script
under bin/ is: `run` exports the environment the script reaches other tools by (BAO_BASE_BIN_DIR,
the logging functions), so executing the file directly leaves that unset and the failure lands on
whichever line reaches for it first.

The four tests that reach a single function of the script rather than running it live in
verify-audit.bats, because Python cannot source bash functions. They move here as direct imports
when the script itself is Python, and that file then goes away.
"""

import os
import subprocess
from pathlib import Path

import pytest

BAO_BASE = Path(__file__).resolve().parents[2]
RUN = BAO_BASE / "run"

FOUNDRY_TOML = '[profile.default]\nsrc = "src"\nout = "out"\n'


def run_verify_audit(cwd, *args):
    """Run verify-audit in `cwd`; returns (exit status, stdout+stderr).

    The verbosity is pinned because `run` takes a `-q` anywhere in its argument list as its own
    quiet flag and exports the resulting level, so `run pytest -q` would otherwise suppress the INFO
    lines some of these tests assert on - and the suite's result would depend on how it was invoked.
    """
    done = subprocess.run(
        [str(RUN), "verify-audit", *args],
        cwd=cwd,
        capture_output=True,
        text=True,
        env={**os.environ, "BAO_BASE_VERBOSITY": "0"},
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

    def verify_audit(self, *args, cwd=None):
        """Run verify-audit over the fixture; returns (exit status, stdout+stderr)."""
        return run_verify_audit(cwd or self.work, *args)


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


def test_two_head_files_sharing_a_signature_is_an_ambiguity(fix):
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


def test_dependency_version_disagreement_stops_the_run(conflicted):
    """A disagreement is named and nothing past it is attempted, so no verdict is printed under it.

    Reporting both would spend minutes compiling to produce a verdict nobody may act on, under a
    qualification a screen further up: "no changes under src/" reads as a pass however qualified.
    """
    status, output = run_verify_audit(conflicted, "deploy/test")
    assert status != 0, output
    assert "shared" in output  # the disagreement is named
    assert "=== deploy/test ===" not in output  # and nothing past it was attempted


def test_dependency_agreement_is_stated_and_the_comparison_runs(conflicted):
    """The check passing must not end the run early, and says so in one line rather than a block."""
    _make_dependencies_agree(conflicted)
    status, output = run_verify_audit(conflicted, "deploy/definitely-not-a-tag")
    assert "staged at the same commit" in output
    assert "deploy/definitely-not-a-tag" in output  # it reached the revision it could not resolve
