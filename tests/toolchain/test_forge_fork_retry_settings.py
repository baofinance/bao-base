"""forge gives a fork a test creates the retries of the endpoint entry the fork names by its alias, and nothing
else: not the command line's --fork-retries and --fork-retry-backoff, and not the entry's when the fork is given
the entry's URL - what `vm.rpcUrl(alias)` returns - in place of the alias (foundry issue 18071, its body in
bug-reports/foundry-1-9-0-cheatcode-fork-retry-settings.md). So BaoTest's `createSelectFork` passes the alias
it is given to the cheatcode, a project's mainnet entry carries the retries, and a runner's flags protect only
the fork the command line creates.

Each test counts the attempts one fork's creation makes against an endpoint that refuses every request with
HTTP 429: one `eth_chainId` per attempt, so the count is the retries plus one. The first pins what the alias form
relies on. The other two pin the defect: when one fails, forge has changed, and the alias form or a runner's flags
can be reconsidered. forge's default of 8 retries at 800 ms makes each of those two take about 13 seconds.
"""

import contextlib
import json
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

FORGES_DEFAULT_ATTEMPTS = 9  # the first attempt and forge's default of 8 retries
ENTRYS_ATTEMPTS = 3  # the first attempt and the entry's 2 retries

FOUNDRY_TOML = """\
[profile.default]
src = "src"
test = "test"

[rpc_endpoints]
stub = { endpoint = "http://127.0.0.1:%d", retries = 2, retry_backoff = 100 }
plain = "http://127.0.0.1:%d"
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


@contextlib.contextmanager
def anvil():
    """A local chain for the fork `--rpc-url` creates, since forge takes the retry flags only with one; its URL."""
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    url = f"http://127.0.0.1:{port}"
    process = subprocess.Popen(["anvil", "--port", str(port), "--silent"])
    try:
        request = urllib.request.Request(
            url, data=b'{"jsonrpc":"2.0","id":1,"method":"eth_chainId"}', headers={"Content-Type": "application/json"}
        )
        deadline = time.monotonic() + 30
        while True:
            try:
                with urllib.request.urlopen(request, timeout=1):
                    break
            except (urllib.error.URLError, OSError):
                assert time.monotonic() < deadline, "anvil did not answer within 30 seconds"
                time.sleep(0.2)
        yield url
    finally:
        process.terminate()
        process.wait()


def project(root: Path, port: int) -> Path:
    (root / "src").mkdir(parents=True)
    (root / "test").mkdir()
    (root / "foundry.toml").write_text(FOUNDRY_TOML % (port, port))
    (root / "test" / "Fork.t.sol").write_text(FORK_TEST)
    return root


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
        assert stub.chain_id_requests == ENTRYS_ATTEMPTS


def test_a_fork_named_by_the_entrys_url_gets_forges_defaults(tmp_path):
    # why a fork names its alias: vm.rpcUrl(alias) returns the URL, and a fork given a URL takes nothing from the entry
    with refusing_endpoint() as stub:
        forge_test(project(tmp_path, stub.port), "ByUrl")
        assert stub.chain_id_requests == FORGES_DEFAULT_ATTEMPTS, (
            "forge now gives a fork named by the entry's URL the entry's retries: a fork may name either"
        )


def test_the_command_lines_retries_do_not_reach_a_fork_a_test_creates(tmp_path):
    # why a runner's --fork-retries protects only the fork --rpc-url creates, and the entry carries the tests' retries
    with refusing_endpoint() as stub, anvil() as url:
        root = project(tmp_path, stub.port)
        forge_test(
            root,
            "Plain",
            "--rpc-url",
            url,
            "--fork-retries",
            "2",
            "--fork-retry-backoff",
            "100",
            "--no-storage-caching",
        )
        assert stub.chain_id_requests == FORGES_DEFAULT_ATTEMPTS, (
            "forge now passes the command line's retries to a fork a test creates: a runner's flags reach the tests' "
            "forks, and the entry need not carry them"
        )
