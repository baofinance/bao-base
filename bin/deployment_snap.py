"""snap: the readings of a deployment's contracts at a block, written to a sorted file for a person to read.

`snap --network <net> [--local] [--block <n>] --prefix <p> --state <file>... [--known <address>...]` reads, at the
block (the network's latest by default), every proxy of the state files whose key starts with the prefix, and writes
the readings to `tmp/snap/<prefix>_<net>[_local]_<block>.tsv`, sorted, one `<contract key>\t<label>\t<value>` a line.
It is a tool for inspection and comparison, not a step of a deployment.

The work has two parts. The listing says what to read. It depends only on the state files and the build, never on a
block: each proxy and implementation the state files name, and for each implementation's type its views and storage
fields, from what `forge inspect` prints. forge lays out ERC-7201 namespaced fields there too, at their slots. bao-base's
DeploymentSnapLib then reads at the block, in the forge script test/snap/DumpSnap.s.sol: it says what each reading is.

The listing's lines are tab-separated:
- `proxy <key> <address>` and `implementation <address> <type>`, from every state file given;
- `absent <type>`: a type a state file names that the build has no contract of;
- `view <type> <signature> <selector> <none|address> <outputs>`: each view or pure function with no argument or one
  address argument. The outputs are kinds, comma-separated: `address`, `bool`, `uint`, `int`, `bytes<N>`, `string`,
  `bytes`. They are `raw` when one output is of another type, and `-` when there is none.
- `storage <type> <label> <mapping slot|-> <slot> <offset> <bytes> <kind>`: each value a storage field holds, by kind
  (`address`, `bool`, `uint`, `int`, `bytes<N>`, `raw`). A struct is listed by member, a static array by element, a
  dynamic array by its length, a string or bytes by its slot word. A mapping keyed by an address is listed at each
  known address: the label holds `{}` where the key goes, and the slot is counted from the entry's. A mapping keyed by
  anything else, and a mapping inside a mapping's entry, are not read, as two-argument views are not.

`view_lines`, `storage_lines` and `listing_lines` decide without running anything; `main` runs forge and cast.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Callable

BAO_BASE = Path(__file__).resolve().parent.parent

# The forge script that reads, and the signature of its entry point: the fork, the block, the listing's path, the
# prefix, the known addresses, the path it writes its readings to.
SCRIPT = BAO_BASE / "test" / "snap" / "DumpSnap.s.sol"
SIGNATURE = "run(string,uint256,string,string,address[],string)"

# The ABI types a value is read as, and the solc storage labels.
_UNSIGNED = re.compile(r"uint\d+")
_SIGNED = re.compile(r"int\d+")
_FIXED_BYTES = re.compile(r"bytes\d+")
_STATIC_ARRAY_LENGTH = re.compile(r"\[(\d+)\]$")

# What forge inspect has as a type's ABI, selectors and storage layout; None for a type the build has no contract of.
Inspected = tuple[list, dict, dict]


def _abi_kind(abi_type: str) -> str | None:
    """The kind a value of this ABI type is read as, or None when it is not elementary."""
    if abi_type in ("address", "bool", "string", "bytes"):
        return abi_type
    if _UNSIGNED.fullmatch(abi_type):
        return "uint"
    if _SIGNED.fullmatch(abi_type):
        return "int"
    if _FIXED_BYTES.fullmatch(abi_type):
        return abi_type
    return None


def _outputs(outputs: list[dict]) -> str:
    kinds = [_abi_kind(output["type"]) for output in outputs]
    if not kinds:
        return "-"
    if None in kinds:
        return "raw"
    return ",".join(kinds)


def view_lines(contract_type: str, abi: list[dict], method_identifiers: dict[str, str]) -> list[str]:
    """The `view` line of each view or pure function of `abi` with no argument or one address argument."""
    lines = []
    for entry in abi:
        if entry.get("type") != "function" or entry.get("stateMutability") not in ("view", "pure"):
            continue
        inputs = [argument["type"] for argument in entry["inputs"]]
        if inputs not in ([], ["address"]):
            continue
        signature = f"{entry['name']}({','.join(inputs)})"
        if signature not in method_identifiers:
            sys.exit(f"❌ forge inspect gives {contract_type} no selector for {signature}")
        argument = "address" if inputs else "none"
        selector = f"0x{method_identifiers[signature]}"
        lines.append("\t".join(["view", contract_type, signature, selector, argument, _outputs(entry["outputs"])]))
    return lines


def _storage_kind(type_id: str, type_def: dict) -> str:
    """The kind a value laid out as `type_def` is read as. A user-defined value type's label is only its name, so it is
    told by its type id."""
    label = type_def["label"]
    if "t_userDefinedValueType(" in type_id:
        return "raw"
    if label in ("address", "address payable") or label.startswith("contract "):
        return "address"
    if label == "bool":
        return "bool"
    if label.startswith("enum ") or _UNSIGNED.fullmatch(label):
        return "uint"
    if _SIGNED.fullmatch(label):
        return "int"
    if _FIXED_BYTES.fullmatch(label):
        return label
    return "raw"


def _values(types: dict, type_id: str, label: str, slot: int, offset: int, mapping_slot: int | None):
    """(label, mapping slot, slot, offset, bytes, kind) of each value a field of `type_id` at `slot` holds. Under a
    mapping, `mapping_slot` is the mapping's slot and `slot` is counted from the entry's."""
    type_def = types[type_id]
    encoding = type_def["encoding"]
    if encoding == "mapping":
        key = types[type_def["key"]]["label"]
        if mapping_slot is None and (key == "address" or key.startswith("contract ")):
            yield from _values(types, type_def["value"], f"{label}[{{}}]", 0, 0, slot)
        return
    if encoding == "dynamic_array":
        yield (f"{label}.length", mapping_slot, slot, 0, 32, "uint")
        return
    if encoding == "bytes":
        yield (label, mapping_slot, slot, 0, 32, "raw")
        return
    if "members" in type_def:
        for member in type_def["members"]:
            member_slot = slot + int(member["slot"])
            member_label = f"{label}.{member['label']}"
            yield from _values(types, member["type"], member_label, member_slot, member["offset"], mapping_slot)
        return
    if "base" in type_def:
        # a static array: each element starts a slot of its own when it fills one, else they pack
        length = int(_STATIC_ARRAY_LENGTH.search(type_def["label"]).group(1))
        size = int(types[type_def["base"]]["numberOfBytes"])
        for index in range(length):
            if size >= 32:
                element_slot, element_offset = slot + index * ((size + 31) // 32), 0
            else:
                per_slot = 32 // size
                element_slot, element_offset = slot + index // per_slot, (index % per_slot) * size
            element_label = f"{label}[{index}]"
            yield from _values(types, type_def["base"], element_label, element_slot, element_offset, mapping_slot)
        return
    yield (label, mapping_slot, slot, offset, int(type_def["numberOfBytes"]), _storage_kind(type_id, type_def))


def _word(value: int) -> str:
    return f"0x{value:064x}"


def storage_lines(contract_type: str, layout: dict) -> list[str]:
    """The `storage` line of each value the fields of a forge storage layout hold."""
    lines = []
    for field in layout["storage"]:
        values = _values(layout["types"], field["type"], field["label"], int(field["slot"]), field["offset"], None)
        for label, mapping_slot, slot, offset, size, kind in values:
            mapping = "-" if mapping_slot is None else _word(mapping_slot)
            lines.append(
                "\t".join(["storage", contract_type, label, mapping, _word(slot), str(offset), str(size), kind])
            )
    return lines


def listing_lines(states: list[dict], inspect: Callable[[str], Inspected | None]) -> list[str]:
    """The listing of every proxy and implementation of the state files, and of each implementation's type: its views
    and storage, or `absent` when `inspect` finds no contract of it. Each type once, in the order of its name."""
    proxies: dict[str, str] = {}
    implementations: dict[str, tuple[str, str]] = {}
    for state in states:
        for key, proxy in state.get("proxies", {}).items():
            if key in proxies:
                sys.exit(f"❌ the proxy {key} is in more than one state file")
            proxies[key] = proxy["address"]
        for address, implementation in state.get("implementations", {}).items():
            contract_type = implementation["contractType"]
            _named_address, named = implementations.setdefault(address.lower(), (address, contract_type))
            if named != contract_type:
                sys.exit(
                    f"❌ the implementation {address} is a {named} in one state file and a {contract_type} in another"
                )
    lines = [f"proxy\t{key}\t{address}" for key, address in proxies.items()]
    lines += [f"implementation\t{address}\t{contract_type}" for address, contract_type in implementations.values()]
    absent, read = [], []
    for contract_type in sorted({contract_type for _address, contract_type in implementations.values()}):
        inspected = inspect(contract_type)
        if inspected is None:
            absent.append(f"absent\t{contract_type}")
            continue
        abi, method_identifiers, layout = inspected
        read += view_lines(contract_type, abi, method_identifiers) + storage_lines(contract_type, layout)
    return lines + absent + read


def _forge_inspect(contract_type: str) -> Inspected | None:
    """What forge inspect prints for the type: its ABI, selectors and storage layout. None when forge finds no contract
    of that name in the build; any other failure stops the snap with forge's error."""
    printed = []
    for field in ("abi", "methodIdentifiers", "storageLayout"):
        command = ["forge", "inspect", contract_type, field, "--json"]
        done = subprocess.run(command, capture_output=True, text=True, check=False)
        if done.returncode != 0 and f"No contract found with the name `{contract_type}`" in done.stderr:
            return None
        if done.returncode != 0:
            failure = done.stderr.strip() or f"forge exited {done.returncode}"
            sys.exit(f"❌ forge inspect {contract_type} {field} failed: {failure}")
        printed.append(json.loads(done.stdout))
    abi, method_identifiers, layout = printed
    return abi, method_identifiers, layout


def _cast(arguments: list[str], failure: str) -> str:
    """What `cast <arguments>` printed. A cast that fails stops the snap, with `failure` and cast's own error."""
    done = subprocess.run(["cast", *arguments], capture_output=True, text=True, check=False)
    if done.returncode != 0:
        sys.exit(f"❌ {failure}: {done.stderr.strip() or f'cast exited {done.returncode}'}")
    return done.stdout.strip()


def _parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="snap",
        description="Read a deployment's contracts at a block, and write the readings to a sorted file.",
    )
    parser.add_argument("--network", required=True, help="the network the state files are of: an rpc_endpoints alias")
    parser.add_argument("--local", action="store_true", help="read the local node, a fork of the network")
    parser.add_argument("--block", type=int, help="the block to read at (default: the latest)")
    parser.add_argument("--prefix", required=True, help="read the proxies whose key starts with this, such as GOLD::")
    parser.add_argument("--state", action="append", required=True, help="a state file (repeatable)")
    parser.add_argument(
        "--known", action="append", default=[], help="an address to read address views and mappings at (repeatable)"
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    if not Path("foundry.toml").is_file():
        sys.exit("❌ Run from project root")
    arguments = _parse_arguments(argv)
    rpc = "local" if arguments.local else arguments.network
    block = arguments.block
    if block is None:
        block = int(_cast(["block-number", "--rpc-url", rpc], f"the block number of {rpc} was not read"))

    states = [json.loads(Path(file).read_text()) for file in arguments.state]
    listing = listing_lines(states, _forge_inspect)

    prefix = re.sub(r"[^A-Za-z0-9]+", "_", arguments.prefix).strip("_") or "all"
    name = f"{prefix}_{arguments.network}{'_local' if arguments.local else ''}_{block}"
    folder = Path("tmp") / "snap"
    folder.mkdir(parents=True, exist_ok=True)
    listing_file = folder / f"{name}.listing.tsv"
    listing_file.write_text("\n".join(listing) + "\n")
    # removed first, so the readings read back are the ones this run wrote
    unsorted = folder / f"{name}.unsorted.tsv"
    unsorted.unlink(missing_ok=True)

    command = ["forge", "script", f"{os.path.relpath(SCRIPT)}:DumpSnap", "--sig", SIGNATURE, rpc, str(block)]
    command += [str(listing_file), arguments.prefix, f"[{','.join(arguments.known)}]", str(unsorted)]
    done = subprocess.run(command, check=False)
    if done.returncode != 0:
        sys.exit(f"❌ the read at block {block} failed: forge script exited {done.returncode}")
    if not unsorted.is_file():
        sys.exit(f"❌ the read at block {block} wrote no readings to {unsorted}")

    snap = folder / f"{name}.tsv"
    snap.write_text("\n".join(sorted(line for line in unsorted.read_text().splitlines() if line)) + "\n")
    print(snap)
    return 0
