"""bin/test and bin/gas must still notice a change to a contract's body.

Forge's dynamic test linking, on by default since 1.8.0, rewrites `new Contract(...)` in a test into a
deploy performed at run time, so the test file no longer needs recompiling when only that contract's
body changes - and the build cache stops recompiling it. When the rewrite is not applied to a contract
the cache skips the recompile anyway, so the test keeps running the creation code compiled into it
earlier, and passes against source that cannot pass.

Forge 1.8.3 fixed this for contracts in the `src` directory
(https://github.com/foundry-rs/foundry/issues/16682); for contracts outside it
(https://github.com/foundry-rs/foundry/issues/16901) forge 1.8.4 still has it. Outside `src` is how
these repos reach each other - harbor's tests deploy bao-base's contracts from `lib/` - so the project
below puts its contract in `lib/`. Both bodies are in bug-reports/.

bin/test and bin/gas pass --no-dynamic-test-linking, which avoids the defect, so these tests fail if the
flag is removed while forge still has it.
"""

import subprocess
from pathlib import Path

import pytest

BAO_BASE = Path(__file__).resolve().parents[2]
ISSUE = "https://github.com/foundry-rs/foundry/issues/16901"

# A dependency's contract outside `src`, as harbor reaches bao-base.
DEPENDENCY = Path("lib") / "dep" / "src"

FOUNDRY_TOML = """\
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
remappings = ["@dep/=lib/dep/src/"]
"""

CONTRACT = """\
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract Impl {
    function v() external pure returns (uint256) {
        return %d;
    }
}
"""

TEST = """\
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Impl} from "@dep/Impl.sol";

contract Impl_Test {
    function test_v() public {
        require(new Impl().v() == 111, "v() must be 111");
    }
}
"""

EXPECTED_FAILURE = "v() must be 111"


@pytest.fixture
def project(tmp_path):
    """A foundry project whose test passes until `returns` writes a different dependency body."""
    (tmp_path / "src").mkdir()
    (tmp_path / "test").mkdir()
    (tmp_path / DEPENDENCY).mkdir(parents=True)
    (tmp_path / "foundry.toml").write_text(FOUNDRY_TOML)
    (tmp_path / DEPENDENCY / "Impl.sol").write_text(CONTRACT % 111)
    (tmp_path / "test" / "Impl.t.sol").write_text(TEST)
    return tmp_path


def returns(project, value):
    """Rewrite the contract body. Only the body changes, which is the case the cache gets wrong."""
    (project / DEPENDENCY / "Impl.sol").write_text(CONTRACT % value)


def run(project, *command):
    return subprocess.run(command, cwd=project, capture_output=True, text=True)


@pytest.mark.parametrize("runner", ["test", "gas"])
def test_runner_sees_a_body_change(project, runner):
    # bin/gas needs its own case rather than trusting bin/test's: it compiles to a separate cache
    # (cache/_gas) and so goes stale separately, and gas is the one number that pass exists to produce.
    script = str(BAO_BASE / "bin" / runner)
    assert run(project, script).returncode == 0, "the project must start green"

    returns(project, 222)
    after = run(project, script)
    version = run(BAO_BASE, "forge", "--version").stdout.strip().splitlines()[0]

    assert after.returncode != 0, (
        f"bin/{runner} did not notice a changed contract body, so it is running code compiled earlier "
        f"({version}, {ISSUE}); it must pass --no-dynamic-test-linking while forge has that defect.\n"
        f"{after.stdout}"
    )
    assert EXPECTED_FAILURE in after.stdout, (
        f"bin/{runner} failed for a reason other than the changed body, so it proves nothing about the "
        f"contract being recompiled.\n{after.stdout}\n{after.stderr}"
    )
