> **Status.** Filed as https://github.com/alloy-rs/alloy/issues/4477 on 2026-11-04. Seen on forge 1.9.0, which
> carries alloy-json-rpc 2.5.0 and alloy-transport 2.5.0; the predicate is the same on main. Until alloy retries
> it, bao-base's test runner re-runs the suites such an answer failed, once, and says so
> (bin/forge_test_runs.py). The text below is the body as filed.

### Title
RetryBackoffLayer does not retry Infura's -32603 "precondition failure"

### Component

network, json-rpc; transports

### What version of Alloy are you on?

alloy-json-rpc 2.5.0 and alloy-transport 2.5.0, as carried by foundry's forge 1.9.0 (commit 6056c58).

### Operating System

Linux

### Describe the bug

Infura's Ethereum mainnet endpoint sometimes answers a request with the JSON-RPC error

```
{"code": -32603, "message": "precondition failure"}
```

and `ErrorPayload::is_retry_err` does not retry it, so the request fails at once however many retries the
`RetryBackoffLayer` was given. The same request succeeds moments later. This looks like the same kind of
answer as Infura's `"header not found"`, which `is_retry_err` retries with the comment "this is commonly thrown
by infura and is apparently a load balancer issue".

What was seen, 2026-11-03, from one machine running a forge test suite of 256 suites against Infura, each
suite creating a fork of mainnet at a pinned block:

| run, UTC | suites failed on this answer | where |
|---|---|---|
| 19:44 | 28 | fork creation (`could not instantiate forked environment with provider mainnet.infura.io; server returned an error response: error code -32603: precondition failure`) |
| 19:54 | 2 | fork creation, one of them at a different block |
| 20:01 | 0 | |
| 20:50 | 1 | fetching a block by hash with its transactions (`failed to get full block for 0x7d11…: could not fetch block 0x7d11…; server returned an error response: error code -32603: precondition failure`) |

Every occurrence was a block fetch. Between those runs, three further runs of the same suite from the same
machine saw none, and the suite run six times that afternoon on GitHub's runners against Alchemy saw none.
Infura's status page showed every mainnet component operational and no incident for the preceding two weeks.
A burst sent to the same endpoint through `cast` (60 block reads at 30 in parallel, 200 storage reads at 50,
100 chain-id reads at 100) drew only HTTP 429 with code -32005 "Too Many Requests", which `is_retry_err`
retries, and never this answer: it is not what the endpoint says under load. No documentation of Infura's
names the message; it is Google's wording for a failed precondition, and Infura does not say what the
precondition is.

The predicate, `crates/json-rpc/src/response/error.rs` at v2.5.0, decides it as follows: the code is none
of 429, -32005, -32016, -32012, -32007, 1008 or -32055; the message is neither `"header not found"` nor
`"daily request count exceeded, request rate limited"`; and it contains none of "rate limit", "rate
exceeded", "too many requests", "credits limited", "request limit" or "maximum number of concurrent
requests". So `is_retry_err` is false, `TransportError::is_retryable` is false, and `RetryBackoffService`
returns the error on the first attempt.

### Expected behaviour

A request Infura answers with `-32603 "precondition failure"` is retried like one it answers with `"header not
found"`: an answer the endpoint gives transiently, for which the retry layer exists.

### Actual behaviour

It fails on the first attempt. In forge, a fork's creation or a block fetch inside a test fails with the
answer above, with `retries = 100` on the endpoint entry.

### Proposed change

A message match beside `"header not found"`, so that it stays specific to the message and does not retry
every -32603, which is the generic internal error:

```diff
         match self.message.as_ref() {
             // this is commonly thrown by infura and is apparently a load balancer issue, see also <https://github.com/MetaMask/metamask-extension/issues/7234>
             "header not found" => true,
+            // also thrown by infura, with code -32603, transiently: the same block fetch succeeds moments later
+            "precondition failure" => true,
             // also thrown by infura if out of budget for the day and ratelimited
             "daily request count exceeded, request rate limited" => true,
```

with a test beside the others in that file:

```rust
#[test]
fn infura_precondition_failure_is_retried() {
    let payload: ErrorPayload = serde_json::from_str(r#"{"code":-32603,"message":"precondition failure"}"#).unwrap();
    assert!(payload.is_retry_err());
}
```
