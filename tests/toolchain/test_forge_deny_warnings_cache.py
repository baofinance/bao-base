"""bin/test keeps a build cache, and bin/gas is the gate that fails a compile with warnings.

`deny = "warnings"` in foundry.toml (as in bao-base and harbor) makes forge fail a compile that has
warnings, and since forge 1.8.4 also makes it keep no build cache at all: cached artifacts do not carry
the compiler's warnings, so a warm build could not re-check them
(https://github.com/foundry-rs/foundry/pull/17202, the fix for issue 17174). Every `yarn test` would then
recompile the whole project. So bin/test passes `--deny never` and keeps its cache, and bin/gas passes
`--deny warnings` and fails on any warning in what it compiles.

The first test pins forge's behaviour: when it fails, forge caches under denied warnings again, and
bin/test's `--deny never` can be reconsidered.
"""

import subprocess
from pathlib import Path

BAO_BASE = Path(__file__).resolve().parents[2]
CACHE = Path("cache") / "solidity-files-cache.json"
UNUSED_LOCAL_VARIABLE = "2072"  # solc's warning code for an unused local variable

FOUNDRY_TOML = """\
[profile.default]
src = "src"
out = "out"
deny = "%s"
"""

CONTRACT = """\
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract Impl {
    function v() external pure returns (uint256) {
        %s
        return 111;
    }
}
"""

TEST = """\
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Impl} from "../src/Impl.sol";

contract Impl_Test {
    function test_v() public {
        require(new Impl().v() == 111, "v() must be 111");
    }
}
"""


def project(root: Path, deny: str, warning: bool) -> Path:
    """A foundry project with one passing test, whose contract has an unused local variable if `warning`."""
    (root / "src").mkdir(parents=True)
    (root / "test").mkdir()
    (root / "foundry.toml").write_text(FOUNDRY_TOML % deny)
    (root / "src" / "Impl.sol").write_text(CONTRACT % ("uint256 unused;" if warning else ""))
    (root / "test" / "Impl.t.sol").write_text(TEST)
    return root


def run(root: Path, *command: str) -> subprocess.CompletedProcess:
    return subprocess.run(command, cwd=root, capture_output=True, text=True)


def test_forge_keeps_no_cache_when_warnings_are_denied(tmp_path):
    root = project(tmp_path, deny="warnings", warning=False)
    built = run(root, "forge", "build")
    assert built.returncode == 0, built.stdout + built.stderr
    assert not (root / CACHE).exists(), (
        "forge kept a build cache with warnings denied, so it no longer behaves as foundry-rs/foundry#17202 "
        "made it: bin/test's --deny never may no longer be needed"
    )


def test_bin_test_keeps_a_cache_when_warnings_are_denied(tmp_path):
    root = project(tmp_path, deny="warnings", warning=False)
    first = run(root, str(BAO_BASE / "bin" / "test"))
    assert first.returncode == 0, first.stdout + first.stderr
    assert (root / CACHE).exists(), "bin/test kept no build cache, so every run recompiles the whole project"
    second = run(root, str(BAO_BASE / "bin" / "test"))
    assert second.returncode == 0, second.stdout + second.stderr
    assert "No files changed, compilation skipped" in second.stdout + second.stderr


def test_bin_test_passes_with_a_compiler_warning(tmp_path):
    # a warning is shown but does not fail a test run: bin/gas is the gate
    root = project(tmp_path, deny="warnings", warning=True)
    tested = run(root, str(BAO_BASE / "bin" / "test"))
    assert tested.returncode == 0, tested.stdout + tested.stderr
    assert UNUSED_LOCAL_VARIABLE in tested.stdout + tested.stderr


def test_bin_gas_fails_on_a_compiler_warning(tmp_path):
    # the gate holds even where a project's foundry.toml does not deny warnings itself
    root = project(tmp_path, deny="never", warning=True)
    gassed = run(root, str(BAO_BASE / "bin" / "gas"))
    assert gassed.returncode != 0, gassed.stdout + gassed.stderr
    assert UNUSED_LOCAL_VARIABLE in gassed.stdout + gassed.stderr
