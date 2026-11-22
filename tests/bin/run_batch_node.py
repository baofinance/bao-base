"""A stand-in for `cast` talking to a local node, for run-batch's tests: copied onto PATH as `cast`.

It keeps the node in the JSON file STUB_NODE names and appends each command it is handed, as a JSON list, to the file
STUB_LOG names. The node is what run-batch reads and changes, with anvil's behavior as measured on anvil 1.9.0:
- `block`, the head's number; `blocks`, each mined block's transaction hashes; `transactions`, each sent transaction's
  sender, target, data, value and nonce; `receipts`, each mined transaction's status; `nonces`, each account's count
  of mined transactions; `pending`, the hashes sent and not mined, in the order sent.
- `automine`: a transaction sent is mined into a block of its own at once. `interval`: the seconds between blocks a
  node mining on a timer reports, else null.
- A transaction is sent at the nonce the sender's count of mined and pending transactions gives, and refused at any
  other. A call to a target in `refused` is refused at its gas estimate, with a revert reason. One to a target in
  `failing` is mined with status failure. One to a target in `ownerless` does not answer owner().
- `evm_mine` mines up to `block_capacity` pending transactions into one block, in the order sent, after `foreign` when
  it is set: a transaction someone else sent. The rest stay pending.
- `evm_snapshot` keeps the chain (blocks, receipts, nonces); `evm_revert` restores it and forgets that snapshot and
  every later one. Neither touches the mining mode or what is pending.
"""

import copy
import hashlib
import json
import os
import sys

REVERT_REASON = "execution reverted: NotEnoughBalance"
CHAIN = ("block", "blocks", "receipts", "nonces")


def _option(arguments: list[str], name: str) -> str:
    return arguments[arguments.index(name) + 1]


def _mine(node: dict) -> None:
    taken = ([node["foreign"]] if node["foreign"] else []) + node["pending"]
    taken, node["pending"] = taken[: node["block_capacity"]], taken[node["block_capacity"] :]
    node["foreign"] = None
    node["block"] += 1
    node["blocks"][str(node["block"])] = taken
    for transaction_hash in taken:
        transaction = node["transactions"].get(transaction_hash)
        if transaction is None:
            node["receipts"][transaction_hash] = "0x1"
            continue
        node["receipts"][transaction_hash] = "0x0" if transaction["to"] in node["failing"] else "0x1"
        node["nonces"][transaction["from"]] = node["nonces"].get(transaction["from"], 0) + 1


def _rpc(node: dict, method: str, parameters: list[str]) -> object:
    if method == "anvil_getIntervalMining":
        return node["interval"]
    if method == "anvil_getAutomine":
        return node["automine"]
    if method == "evm_setAutomine":
        node["automine"] = json.loads(parameters[0])
        return None
    if method == "evm_snapshot":
        identifier = hex(node["next_snapshot"])
        node["next_snapshot"] += 1
        node["snapshots"][identifier] = copy.deepcopy({key: node[key] for key in CHAIN})
        return identifier
    if method == "evm_revert":
        if parameters[0] not in node["snapshots"]:
            return False
        node.update(node["snapshots"][parameters[0]])
        node["snapshots"] = {
            key: value for key, value in node["snapshots"].items() if int(key, 16) < int(parameters[0], 16)
        }
        return True
    if method == "evm_mine":
        _mine(node)
        return "0x0"
    if method == "anvil_dropAllTransactions":
        node["pending"] = []
        return None
    if method == "eth_getBlockByNumber":
        return {"number": parameters[0], "transactions": node["blocks"].get(str(int(parameters[0], 16)), [])}
    if method == "eth_getTransactionReceipt":
        return {"transactionHash": parameters[0], "status": node["receipts"][parameters[0]]}
    raise SystemExit(f"stub cast: no rpc {method}")


def _send(node: dict, arguments: list[str]) -> str:
    target, data = arguments[0], arguments[1]
    sender = _option(arguments, "--from").lower()
    nonce = int(_option(arguments, "--nonce"))
    expected = node["nonces"].get(sender, 0) + sum(
        1 for transaction_hash in node["pending"] if node["transactions"][transaction_hash]["from"] == sender
    )
    if nonce < expected:
        print(
            "Error: server returned an error response: error code -32003: replacement transaction underpriced",
            file=sys.stderr,
        )
        sys.exit(1)
    if nonce > expected:
        print("Error: server returned an error response: error code -32003: nonce too high", file=sys.stderr)
        sys.exit(1)
    if target in node["refused"]:
        print(
            f"Error: Failed to estimate gas: server returned an error response: error code 3: {REVERT_REASON}",
            file=sys.stderr,
        )
        sys.exit(1)
    transaction_hash = "0x" + hashlib.sha256(f"{sender}{target}{data}{nonce}{node['block']}".encode()).hexdigest()
    node["transactions"][transaction_hash] = {
        "from": sender,
        "to": target,
        "data": data,
        "value": _option(arguments, "--value"),
        "nonce": nonce,
    }
    node["pending"].append(transaction_hash)
    if node["automine"]:
        _mine(node)
    return transaction_hash


def main(arguments: list[str]) -> None:
    with open(os.environ["STUB_LOG"], "a") as log:
        log.write(json.dumps(arguments) + "\n")
    with open(os.environ["STUB_NODE"]) as file:
        node = json.load(file)
    arguments = arguments[: arguments.index("--rpc-url")] + arguments[arguments.index("--rpc-url") + 2 :]
    command, rest = arguments[0], arguments[1:]
    if command == "rpc":
        answer = json.dumps(_rpc(node, rest[0], rest[1:]))
    elif command == "block-number":
        answer = str(node["block"])
    elif command == "nonce":
        answer = str(node["nonces"].get(rest[0].lower(), 0))
    elif command == "call" and rest[1] == "owner()(address)":
        if rest[0] in node["ownerless"]:
            print(
                "Error: could not decode output; did you specify the wrong function return data type?", file=sys.stderr
            )
            sys.exit(1)
        answer = node["owner"]
    elif command == "send":
        answer = _send(node, rest)
    else:
        raise SystemExit(f"stub cast: no command {arguments}")
    with open(os.environ["STUB_NODE"], "w") as file:
        json.dump(node, file)
    print(answer)


if __name__ == "__main__":
    main(sys.argv[1:])
