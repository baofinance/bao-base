> **Status.** Filed as https://github.com/foundry-rs/foundry/issues/18071 on 2026-11-03, and closed as completed
> the same day by https://github.com/foundry-rs/foundry/pull/18074: the entry's retries override the command
> line's only where the entry sets them, a fork given an entry's URL keeps the entry's settings, and the entry's
> compute units reach the fork. In no release yet (stable 1.9.0 predates it). Found on forge
> 1.8.7 on 2026-11-02 and unchanged on 1.9.0 on 2026-11-03: the same attempts per run, and the same lookup
> and overwrite in the source at that tag. Until forge changes, every fork a test creates in bao-base and
> harbor names its endpoint by alias - `vm.createSelectFork("mainnet", block)`, never the URL `vm.rpcUrl`
> returns - and the alias's entry in foundry.toml carries the retries. The text below is the body as filed.

### Component

Forge

### Have you ensured that all of these are up to date?

- [x] Foundry
- [x] Foundryup

### What version of Foundry are you on?

forge Version: 1.9.0, Commit SHA: 6056c5845d34205a83cf7108042adb137325c9df

### What version of Foundryup are you on?

2.0.0

### What command(s) is the bug in?

forge test

### Operating System

Linux

### Describe the bug

A fork a test creates with `vm.createFork` or `vm.createSelectFork` retries a refused request 8 times at
800 ms, forge's defaults, whatever retry settings the run was given, in two of the three ways forge offers
to give them:

1. **`--fork-retries` and `--fork-retry-backoff` on the command line never reach such a fork.**
   `create_fork_request` (`crates/cheatcodes/src/evm/fork.rs`) replaces them with the endpoint entry's
   `retries` and `retry_backoff`, even when the entry has none. Introduced by #9547, which closed #9162.
2. **The entry's `retries` and `retry_backoff` reach the fork only when the fork names the entry by its
   alias.** Given a URL, `rpc_endpoint` (`crates/cheatcodes/src/config.rs`) makes a fresh entry with no
   settings. `vm.rpcUrl(alias)` returns the URL, so `vm.createSelectFork(vm.rpcUrl("mainnet"), block)` -
   the usual way to write it - gets the defaults.

Nothing warns in either case. The run looks protected and is not. A suite whose test contracts each create
a fork in `setUp`, run in parallel, exhausts 8 retries in a burst against a rate-limited provider and fails
in `setUp` with `vm.createSelectFork: could not instantiate forked environment with provider ...; failed to
retrieve chain ID from fork endpoint; Max retries exceeded HTTP error 429`, or with `sharedbackend: Failed
to send/recv 'basic' ... Max retries exceeded` on a state read after it.

While there: the entry's `compute_units_per_second` is parsed (`crates/config/src/endpoints.rs`), but
`create_fork_request` copies only `retries`, `retry_backoff` and `auth`, so it never reaches such a fork
either; the command line's `--compute-units-per-second` does. Read from the source, not measured.

## Minimal reproduction

A stub that answers HTTP 429 to every request and logs each request's method; a `foundry.toml` with an
entry carrying retries and one carrying none; a test for each way of naming the entry. No dependencies.
`anvil` serves the run-wide fork that `--rpc-url` creates in runs 3 and 4, since forge accepts the two
retry flags only with `--rpc-url`.

```bash
mkdir -p repro/src repro/test && cd repro

cat > foundry.toml <<'EOF'
[profile.default]
src = "src"
test = "test"

[rpc_endpoints]
stub = { endpoint = "http://127.0.0.1:18429", retries = 2, retry_backoff = 100 }
plain = "http://127.0.0.1:18429"
EOF

cat > test/Fork.t.sol <<'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface Vm {
    function createSelectFork(string calldata urlOrAlias) external returns (uint256);
    function rpcUrl(string calldata name) external returns (string memory);
}

Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

contract ByUrl   { function testFork() public { vm.createSelectFork(vm.rpcUrl("stub")); } }
contract ByAlias { function testFork() public { vm.createSelectFork("stub"); } }
contract Plain   { function testFork() public { vm.createSelectFork("plain"); } }
EOF

cat > stub429.py <<'EOF'
# An RPC endpoint that answers HTTP 429 to every request and appends each request's JSON-RPC method to a log.
# Usage: python3 stub429.py <log file>
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

class Refuse(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with open(sys.argv[1], "a") as log:
            for request in body if isinstance(body, list) else [body]:
                log.write(request["method"] + "\n")
        payload = b'{"jsonrpc":"2.0","id":1,"error":{"code":-32005,"message":"Too Many Requests"}}'
        self.send_response(429)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass

HTTPServer(("127.0.0.1", 18429), Refuse).serve_forever()
EOF

python3 stub429.py requests.log &
anvil --port 18545 --silent &

: > requests.log; forge test --mc ByUrl;   grep -c eth_chainId requests.log    # 9
: > requests.log; forge test --mc ByAlias; grep -c eth_chainId requests.log    # 3
: > requests.log; forge test --mc Plain --rpc-url http://127.0.0.1:18545 --fork-retries 2 --fork-retry-backoff 100 \
    --no-storage-caching; grep -c eth_chainId requests.log                      # 9
: > requests.log; forge test --mc ByUrl --rpc-url http://127.0.0.1:18545 --fork-retries 2 --fork-retry-backoff 100 \
    --no-storage-caching; grep -c eth_chainId requests.log                      # 9
```

| run | the fork names | retries given | attempts | suite time |
|---|---|---|---|---|
| 1 | the URL `vm.rpcUrl("stub")` returns | the entry: `retries = 2, retry_backoff = 100` | 9 | 12.85 s |
| 2 | the alias `"stub"` | the same entry | 3 | 0.42 s |
| 3 | the alias `"plain"`, an entry with no settings | the command line: `--fork-retries 2 --fork-retry-backoff 100` | 9 | 12.85 s |
| 4 | the URL `vm.rpcUrl("stub")` returns | both | 9 | 12.85 s |

Each attempt is one `eth_chainId`, with one `anvil_nodeInfo` probe retried beside it. Run 2 is the only one
where a setting took effect. Every run fails the test, as it should against this stub; the defect is how
many attempts it takes, and that the settings that should decide that are ignored.

## Cause

`crates/cheatcodes/src/config.rs` at v1.9.0, the lookup both cheatcodes go through. The alias branch keeps
the entry's settings; a URL gets an entry with none:

```rust
pub fn rpc_endpoint(&self, url_or_alias: &str) -> Result<ResolvedRpcEndpoint> {
    // Every cheatcode that opens a connection to a URL or alias resolves it here.
    if self.evm_opts.no_network {
        return Err(fmt_err!("network access is disabled"));
    }
    if let Some(endpoint) = self.rpc_endpoints.get(url_or_alias) {
        Ok(endpoint.clone().try_resolve())
    } else if let Some(builtin_url) = foundry_config::builtin_rpc_url(url_or_alias) {
        let url = RpcEndpointUrl::Url(builtin_url.to_string());
        Ok(RpcEndpoint::new(url).resolve())
    } else {
        // check if it's a URL or a path to an existing file to an ipc socket
        if url_or_alias.starts_with("http") ||
            url_or_alias.starts_with("ws") ||
            // check for existing ipc file
            Path::new(url_or_alias).exists()
        {
            let url = RpcEndpointUrl::Env(url_or_alias.to_string());
            Ok(RpcEndpoint::new(url).resolve())
        } else {
            Err(fmt_err!("invalid rpc url: {url_or_alias}"))
        }
    }
}
```

`crates/cheatcodes/src/evm/fork.rs` at v1.9.0. The command line's values arrive in `evm_opts` and are
overwritten with the entry's, `None` included; `compute_units_per_second` is not copied at all:

```rust
let rpc_endpoint = ccx.state.core.config.rpc_endpoint(url_or_alias)?;
let url = rpc_endpoint.url()?;
let mut evm_opts = ccx.state.core.config.evm_opts.clone();
evm_opts.fork_block_number = block;
evm_opts.fork_block_number_is_inferred = false;
evm_opts.fork_retries = rpc_endpoint.config.retries;
evm_opts.fork_retry_backoff = rpc_endpoint.config.retry_backoff;
```

`EvmOpts::fork_rpc_client` (`crates/evm/core/src/opts.rs`) then builds the fork's provider from
`evm_opts`, with `maybe_max_retry(fork_retries)` and `maybe_initial_backoff(fork_retry_backoff)` falling
back to 8 and 800 ms when `None`, and `compute_units_per_second` from the command line's value, or 330
when there is none.

### Expected behaviour

- The command line's `--fork-retries` and `--fork-retry-backoff` reach every fork, and the entry's values
  override them only where the entry sets them. The two flags then mean something without `--rpc-url`, and
  the `requires = "rpc_url"` on them (`crates/cli/src/opts/evm.rs`) can go - which is what #9162 asked for.
- A fork created from a URL that a configured entry resolves to takes that entry's settings, so
  `vm.rpcUrl(alias)` and the alias behave the same. Failing that, the docs for the entry's keys say they
  apply only when the fork is created from the alias.
- The entry's `compute_units_per_second` is copied to the fork as its `retries` is, or is dropped from the
  entry's keys.

### Actual behaviour

The settings parse, `forge config` shows them, and the fork retries 8 times at 800 ms regardless. The
suite fails after about 13 seconds of refusals per fork, with no indication that a setting was ignored.

## Impact

A suite whose tests create their own forks - a pinned block per test, or several chains - cannot raise
those forks' retries except by knowing to pass the alias, and the two settings that appear to do it fail
silently. In ours, 174 of 204 test contracts fork mainnet in `setUp`; a full run creates them in a burst,
and the free tiers of Infura and Alchemy refuse enough of them to fail tests at random. Forge 1.9.0's fork
reuse does not change that: a suite creating a fork another suite has created shares its cache and client
once its own creation completes, and the creation sends its own requests first - three suites creating
one pinned fork sent three times one suite's `eth_chainId` and `eth_getBlockByNumber` - so it is still
the creation that fails in `setUp`.
