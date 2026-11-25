"""forge gives a fork a test creates the retries of the endpoint entry the fork names, by its alias or by the URL
`vm.rpcUrl(alias)` returns, and the command line's --fork-retries and --fork-retry-backoff where the entry sets
none. Where the entry sets them, the entry's win. forge 1.10.0 is the first release that does: foundry PR 18074
closed issue 18071, whose body is in bug-reports/foundry-1-9-0-cheatcode-fork-retry-settings.md. So a project's
mainnet entry carries its tests' retries, whatever a runner passes. BaoTest's `createSelectFork` passes the
alias it is given to the cheatcode: forge gives a URL an entry's settings only when every entry resolving to
that URL agrees.

Each test counts the attempts one fork's creation makes against an endpoint that refuses every request with
HTTP 429: one `eth_chainId` per attempt, so the count is the retries plus one. The entry and the command line
set different retries, so each count names the setting it came from.
"""

import contextlib
import json
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ENTRYS_RETRIES = 2
COMMAND_LINES_RETRIES = 4
COMMAND_LINE = ("--fork-retries", str(COMMAND_LINES_RETRIES), "--fork-retry-backoff", "100")

FOUNDRY_TOML = """\
[profile.default]
src = "src"
test = "test"

[rpc_endpoints]
stub = { endpoint = "http://127.0.0.1:%(port)d", retries = %(retries)d, retry_backoff = 100 }
# its own path on the stub, which ignores paths: forge gives a URL an entry's settings only when every entry
# resolving to that URL agrees, so `plain` at the stub's URL would cancel `stub` and the URL form would get none
plain = "http://127.0.0.1:%(port)d/plain"
"""

# the cheatcodes at their address, so the project needs no forge-std
FORK_TEST = """\
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface Vm {
    function createSelectFork(string calldata urlOrAlias) external returns (uint256);
    function rpcUrl(string calldata name) external returns (string memory);
}

Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

contract ByAlias { function testFork() public { vm.createSelectFork("stub"); } }
contract ByUrl { function testFork() public { vm.createSelectFork(vm.rpcUrl("stub")); } }
contract Plain { function testFork() public { vm.createSelectFork("plain"); } }
"""


class Refusing(HTTPServer):
    """An endpoint answering HTTP 429 to every request, counting the `eth_chainId` requests it refuses."""

    chain_id_requests = 0

    @property
    def port(self) -> int:
        return self.server_address[1]


class Refuse(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        requests = body if isinstance(body, list) else [body]
        self.server.chain_id_requests += sum(request["method"] == "eth_chainId" for request in requests)
        payload = b'{"jsonrpc":"2.0","id":1,"error":{"code":-32005,"message":"Too Many Requests"}}'
        self.send_response(429)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


@contextlib.contextmanager
def refusing_endpoint():
    server = Refusing(("127.0.0.1", 0), Refuse)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()


def project(root: Path, port: int) -> Path:
    (root / "src").mkdir(parents=True)
    (root / "test").mkdir()
    (root / "foundry.toml").write_text(FOUNDRY_TOML % {"port": port, "retries": ENTRYS_RETRIES})
    (root / "test" / "Fork.t.sol").write_text(FORK_TEST)
    return root


def forge_version() -> str:
    """The first line forge --version prints: its version and commit."""
    return subprocess.run(["forge", "--version"], capture_output=True, text=True, check=True).stdout.splitlines()[0]


# the release a pin on the fixed behavior needs, for the message of one that fails
_FIRST_WITH_THE_FIX = "foundry PR 18074 gives this fork these retries, and forge 1.10.0 is the first release with it"


def forge_test(root: Path, contract: str, *arguments: str) -> str:
    """forge's output running `contract`, which must have failed at its fork's creation for want of retries."""
    run = subprocess.run(
        ["forge", "test", "--match-contract", f"^{contract}$", *arguments], cwd=root, capture_output=True, text=True
    )
    assert run.returncode != 0 and "Max retries exceeded" in run.stdout, run.stdout + run.stderr
    return run.stdout


def test_a_fork_named_by_alias_takes_the_entrys_retries(tmp_path):
    with refusing_endpoint() as stub:
        forge_test(project(tmp_path, stub.port), "ByAlias")
        assert stub.chain_id_requests == ENTRYS_RETRIES + 1


def test_a_fork_named_by_the_entrys_url_takes_the_entrys_retries(tmp_path):
    with refusing_endpoint() as stub:
        forge_test(project(tmp_path, stub.port), "ByUrl")
        assert stub.chain_id_requests == ENTRYS_RETRIES + 1, f"{forge_version()}: {_FIRST_WITH_THE_FIX}"


def test_the_command_lines_retries_reach_a_fork_whose_entry_sets_none(tmp_path):
    with refusing_endpoint() as stub:
        forge_test(project(tmp_path, stub.port), "Plain", *COMMAND_LINE)
        assert stub.chain_id_requests == COMMAND_LINES_RETRIES + 1, f"{forge_version()}: {_FIRST_WITH_THE_FIX}"


def test_the_entrys_retries_win_over_the_command_lines(tmp_path):
    # why a runner's --fork-retries leaves the retries a project's mainnet entry gives its tests' forks
    with refusing_endpoint() as stub:
        forge_test(project(tmp_path, stub.port), "ByAlias", *COMMAND_LINE)
        assert stub.chain_id_requests == ENTRYS_RETRIES + 1
