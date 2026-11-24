"""Tests for bin/snap: the readings of a deployment's contracts at a block, written to a sorted file.

The listing is pure: it is built from state files and from what `forge inspect` prints for each contract type, so the
tests hand it ABIs and storage layouts in the shape forge prints them and assert the lines. The entry runs with every
process it starts replaced: a test asserts the commands, and reads the file the snap leaves.
"""

import json
import sys
from pathlib import Path

import pytest

import deployment_snap

TYPE = "Pool_v1"
NAMESPACE_SLOT = 0x52C63247E1F47DB19D5CE0460030C497F067CA4CEBF71BA98EEADABE20BACE00


def word(slot: int) -> str:
    return f"0x{slot:064x}"


def function(name, inputs=(), outputs=(), mutability="view"):
    """An ABI entry for a function, in the shape `forge inspect <type> abi --json` prints."""
    return {
        "type": "function",
        "name": name,
        "inputs": [{"name": f"in{i}", "type": t, "internalType": t} for i, t in enumerate(inputs)],
        "outputs": [{"name": "", "type": t, "internalType": t} for t in outputs],
        "stateMutability": mutability,
    }


def views(abi, methods):
    return [line.split("\t") for line in deployment_snap.view_lines(TYPE, abi, methods)]


# ── views ──────────────────────────────────────────────────────────────────────────────────────────


def test_a_view_with_no_argument_or_one_address_is_listed_with_its_selector():
    abi = [
        function("totalSupply", outputs=["uint256"]),
        function("balanceOf", inputs=["address"], outputs=["uint256"]),
        function("VERSION", outputs=["string"], mutability="pure"),
    ]
    methods = {"totalSupply()": "18160ddd", "balanceOf(address)": "70a08231", "VERSION()": "ffa1ad74"}

    assert views(abi, methods) == [
        ["view", TYPE, "totalSupply()", "0x18160ddd", "none", "uint"],
        ["view", TYPE, "balanceOf(address)", "0x70a08231", "address", "uint"],
        ["view", TYPE, "VERSION()", "0xffa1ad74", "none", "string"],
    ]


def test_a_function_of_another_shape_or_that_writes_is_not_listed():
    abi = [
        {"type": "constructor", "inputs": [], "stateMutability": "nonpayable"},
        {"type": "event", "name": "Transfer", "inputs": [], "anonymous": False},
        {"type": "error", "name": "Paused", "inputs": []},
        {"type": "fallback", "stateMutability": "payable"},
        function("allowance", inputs=["address", "address"], outputs=["uint256"]),
        function("claimable", inputs=["uint256"], outputs=["uint256"]),
        function("mint", inputs=["address"], mutability="nonpayable"),
        function("sync", mutability="payable"),
    ]
    methods = {
        "allowance(address,address)": "dd62ed3e",
        "claimable(uint256)": "11111111",
        "mint(address)": "6a627842",
        "sync()": "fff6cae9",
    }

    assert views(abi, methods) == []


def test_outputs_are_listed_by_kind_or_raw_when_one_is_not_elementary():
    abi = [
        function("reserves", outputs=["uint112", "int24", "bytes4", "bool", "address", "bytes", "string", "bytes32"]),
        function("holders", outputs=["address[]"]),
        function("config", outputs=["tuple"]),
        function("pair", outputs=["uint256", "uint256[2]"]),
        function("ping"),
    ]
    methods = {"reserves()": "0902f1ac", "holders()": "a0b1c2d3", "config()": "79502c55", "pair()": "a8aa1b31"}
    methods["ping()"] = "5c36b186"

    assert [line[5] for line in views(abi, methods)] == [
        "uint,int,bytes4,bool,address,bytes,string,bytes32",
        "raw",
        "raw",
        "raw",
        "-",
    ]


def test_a_view_forge_gives_no_selector_for_stops_the_listing():
    with pytest.raises(SystemExit) as raised:
        deployment_snap.view_lines(TYPE, [function("totalSupply", outputs=["uint256"])], {})

    assert str(raised.value) == f"❌ forge inspect gives {TYPE} no selector for totalSupply()"


# ── storage ────────────────────────────────────────────────────────────────────────────────────────


def elementary(label, size, encoding="inplace"):
    return {"encoding": encoding, "label": label, "numberOfBytes": str(size)}


def entry(label, slot, type_id, offset=0):
    return {
        "astId": 1,
        "contract": f"src/Pool_v1.sol:{TYPE}",
        "label": label,
        "offset": offset,
        "slot": str(slot),
        "type": type_id,
    }


def storage(entries, types):
    """Each line's kind and the fields after the type."""
    lines = deployment_snap.storage_lines(TYPE, {"storage": entries, "types": types})
    return [[parts[0], *parts[2:]] for parts in (line.split("\t") for line in lines)]


def mapping(key, value, key_label, value_label):
    return {
        "encoding": "mapping",
        "key": key,
        "label": f"mapping({key_label} => {value_label})",
        "numberOfBytes": "32",
        "value": value,
    }


def dynamic_array(base, label):
    return {"base": base, "encoding": "dynamic_array", "label": f"{label}[]", "numberOfBytes": "32"}


DEPOSIT = {
    "encoding": "inplace",
    "label": "struct Pool_v1.Deposit",
    "numberOfBytes": "64",
    "members": [entry("amount", 0, "t_uint256"), entry("since", 1, "t_uint64"), entry("open", 1, "t_bool", offset=8)],
}


def test_a_field_is_listed_at_its_slot_offset_and_size_by_kind():
    types = {
        "t_uint64": elementary("uint64", 8),
        "t_bool": elementary("bool", 1),
        "t_contract(IERC20)12": elementary("contract IERC20", 20),
        "t_address_payable": elementary("address payable", 20),
        "t_int128": elementary("int128", 16),
        "t_bytes4": elementary("bytes4", 4),
        "t_enum(Mode)7": elementary("enum Pool_v1.Mode", 1),
        "t_userDefinedValueType(Price)9": elementary("Price", 32),
        "erc7201(bao.storage.Pool)::t_uint256": elementary("uint256", 32),
    }
    entries = [
        entry("count", 0, "t_uint64"),
        entry("open", 0, "t_bool", offset=8),
        entry("token", 0, "t_contract(IERC20)12", offset=9),
        entry("treasury", 1, "t_address_payable"),
        entry("drift", 2, "t_int128"),
        entry("tag", 2, "t_bytes4", offset=16),
        entry("mode", 2, "t_enum(Mode)7", offset=20),
        entry("price", 3, "t_userDefinedValueType(Price)9"),
        entry("bao.storage.Pool.total", NAMESPACE_SLOT + 1, "erc7201(bao.storage.Pool)::t_uint256"),
    ]

    assert storage(entries, types) == [
        ["storage", "count", word(0), "0", "8", "uint"],
        ["storage", "open", word(0), "8", "1", "bool"],
        ["storage", "token", word(0), "9", "20", "address"],
        ["storage", "treasury", word(1), "0", "20", "address"],
        ["storage", "drift", word(2), "0", "16", "int"],
        ["storage", "tag", word(2), "16", "4", "bytes4"],
        ["storage", "mode", word(2), "20", "1", "uint"],
        ["storage", "price", word(3), "0", "32", "raw"],
        ["storage", "bao.storage.Pool.total", word(NAMESPACE_SLOT + 1), "0", "32", "uint"],
    ]


def test_a_struct_is_listed_by_member_and_a_static_array_by_element():
    types = {
        "t_uint256": elementary("uint256", 32),
        "t_uint128": elementary("uint128", 16),
        "t_struct(Incentive)5_storage": {
            "encoding": "inplace",
            "label": "struct Pool_v1.Incentive",
            "numberOfBytes": "64",
            "members": [
                entry("rate", 0, "t_uint128"),
                entry("cap", 0, "t_uint128", offset=16),
                entry("paid", 1, "t_uint256"),
            ],
        },
        "t_array(t_struct(Incentive)5_storage)2_storage": {
            "base": "t_struct(Incentive)5_storage",
            "encoding": "inplace",
            "label": "struct Pool_v1.Incentive[2]",
            "numberOfBytes": "128",
        },
        "t_array(t_uint128)3_storage": {
            "base": "t_uint128",
            "encoding": "inplace",
            "label": "uint128[3]",
            "numberOfBytes": "64",
        },
    }
    entries = [
        entry("incentives", 10, "t_array(t_struct(Incentive)5_storage)2_storage"),
        entry("caps", 14, "t_array(t_uint128)3_storage"),
    ]

    assert storage(entries, types) == [
        ["storage", "incentives[0].rate", word(10), "0", "16", "uint"],
        ["storage", "incentives[0].cap", word(10), "16", "16", "uint"],
        ["storage", "incentives[0].paid", word(11), "0", "32", "uint"],
        ["storage", "incentives[1].rate", word(12), "0", "16", "uint"],
        ["storage", "incentives[1].cap", word(12), "16", "16", "uint"],
        ["storage", "incentives[1].paid", word(13), "0", "32", "uint"],
        ["storage", "caps[0]", word(14), "0", "16", "uint"],
        ["storage", "caps[1]", word(14), "16", "16", "uint"],
        ["storage", "caps[2]", word(15), "0", "16", "uint"],
    ]


def test_a_mapping_by_any_key_is_listed_as_an_entry_with_its_key_kind():
    types = {
        "t_address": elementary("address", 20),
        "t_contract(IERC20)12": elementary("contract IERC20", 20),
        "t_uint256": elementary("uint256", 32),
        "t_int24": elementary("int24", 3),
        "t_bytes32": elementary("bytes32", 32),
        "t_bool": elementary("bool", 1),
        "t_enum(Mode)7": elementary("enum Pool_v1.Mode", 1),
        "t_string_memory_ptr": elementary("string", 32, encoding="bytes"),
        "t_mapping(t_address,t_uint256)": mapping("t_address", "t_uint256", "address", "uint256"),
        "t_mapping(t_contract(IERC20)12,t_uint256)": mapping(
            "t_contract(IERC20)12", "t_uint256", "contract IERC20", "uint256"
        ),
        "t_mapping(t_uint256,t_uint256)": mapping("t_uint256", "t_uint256", "uint256", "uint256"),
        "t_mapping(t_int24,t_uint256)": mapping("t_int24", "t_uint256", "int24", "uint256"),
        "t_mapping(t_bytes32,t_bool)": mapping("t_bytes32", "t_bool", "bytes32", "bool"),
        "t_mapping(t_enum(Mode)7,t_uint256)": mapping("t_enum(Mode)7", "t_uint256", "enum Pool_v1.Mode", "uint256"),
        "t_mapping(t_string_memory_ptr,t_uint256)": mapping("t_string_memory_ptr", "t_uint256", "string", "uint256"),
    }
    entries = [
        entry("bao.storage.Pool.balances", NAMESPACE_SLOT, "t_mapping(t_address,t_uint256)"),
        entry("held", 1, "t_mapping(t_contract(IERC20)12,t_uint256)"),
        entry("history", 2, "t_mapping(t_uint256,t_uint256)"),
        entry("ticks", 3, "t_mapping(t_int24,t_uint256)"),
        entry("roles", 4, "t_mapping(t_bytes32,t_bool)"),
        entry("byMode", 5, "t_mapping(t_enum(Mode)7,t_uint256)"),
        entry("byName", 6, "t_mapping(t_string_memory_ptr,t_uint256)"),
    ]

    # the key's kind is how it is shown; a string key is hashed whole, so it is raw
    assert storage(entries, types) == [
        ["entry", "bao.storage.Pool.balances[{}]", word(NAMESPACE_SLOT), "address", "0", "0", "32", "uint"],
        ["entry", "held[{}]", word(1), "address", "0", "0", "32", "uint"],
        ["entry", "history[{}]", word(2), "uint", "0", "0", "32", "uint"],
        ["entry", "ticks[{}]", word(3), "int", "0", "0", "32", "uint"],
        ["entry", "roles[{}]", word(4), "bytes32", "0", "0", "1", "bool"],
        ["entry", "byMode[{}]", word(5), "uint", "0", "0", "32", "uint"],
        ["entry", "byName[{}]", word(6), "raw", "0", "0", "32", "uint"],
    ]


def test_a_mapping_inside_an_entry_is_listed_by_each_key():
    types = {
        "t_address": elementary("address", 20),
        "t_uint256": elementary("uint256", 32),
        "t_uint64": elementary("uint64", 8),
        "t_mapping(t_uint256,t_uint64)": mapping("t_uint256", "t_uint64", "uint256", "uint64"),
        "t_mapping(t_address,t_mapping(t_uint256,t_uint64))": mapping(
            "t_address", "t_mapping(t_uint256,t_uint64)", "address", "mapping(uint256 => uint64)"
        ),
        "t_struct(Book)4_storage": {
            "encoding": "inplace",
            "label": "struct Pool_v1.Book",
            "numberOfBytes": "64",
            "members": [entry("total", 0, "t_uint256"), entry("pages", 1, "t_mapping(t_uint256,t_uint64)")],
        },
        "t_mapping(t_address,t_struct(Book)4_storage)": mapping(
            "t_address", "t_struct(Book)4_storage", "address", "struct Pool_v1.Book"
        ),
    }
    entries = [
        entry("marks", 7, "t_mapping(t_address,t_mapping(t_uint256,t_uint64))"),
        entry("books", 8, "t_mapping(t_address,t_struct(Book)4_storage)"),
    ]

    # one slot for each mapping: the next mapping's, counted from this one's entry, then the value's
    assert storage(entries, types) == [
        ["entry", "marks[{}][{}]", word(7), "address,uint", "0,0", "0", "8", "uint"],
        ["entry", "books[{}].total", word(8), "address", "0", "0", "32", "uint"],
        ["entry", "books[{}].pages[{}]", word(8), "address,uint", "1,0", "0", "8", "uint"],
    ]


def test_a_struct_in_an_entry_is_listed_by_member():
    types = {
        "t_address": elementary("address", 20),
        "t_uint256": elementary("uint256", 32),
        "t_uint64": elementary("uint64", 8),
        "t_bool": elementary("bool", 1),
        "t_struct(Deposit)3_storage": DEPOSIT,
        "t_mapping(t_address,t_struct(Deposit)3_storage)": mapping(
            "t_address", "t_struct(Deposit)3_storage", "address", "struct Pool_v1.Deposit"
        ),
    }
    entries = [entry("deposits", 4, "t_mapping(t_address,t_struct(Deposit)3_storage)")]

    assert storage(entries, types) == [
        ["entry", "deposits[{}].amount", word(4), "address", "0", "0", "32", "uint"],
        ["entry", "deposits[{}].since", word(4), "address", "1", "0", "8", "uint"],
        ["entry", "deposits[{}].open", word(4), "address", "1", "8", "1", "bool"],
    ]


def test_a_dynamic_array_is_listed_by_its_length_and_its_elements():
    types = {
        "t_address": elementary("address", 20),
        "t_uint64": elementary("uint64", 8),
        "t_uint256": elementary("uint256", 32),
        "t_bool": elementary("bool", 1),
        "t_struct(Deposit)3_storage": DEPOSIT,
        "t_array(t_address)dyn_storage": dynamic_array("t_address", "address"),
        "t_array(t_uint64)dyn_storage": dynamic_array("t_uint64", "uint64"),
        "t_array(t_struct(Deposit)3_storage)dyn_storage": dynamic_array(
            "t_struct(Deposit)3_storage", "struct Pool_v1.Deposit"
        ),
    }
    entries = [
        entry("holders", 5, "t_array(t_address)dyn_storage"),
        entry("stamps", 6, "t_array(t_uint64)dyn_storage"),
        entry("bao.storage.Pool.queue", NAMESPACE_SLOT + 2, "t_array(t_struct(Deposit)3_storage)dyn_storage"),
    ]

    # an element is counted from its first slot; elements under 32 bytes pack, so their size says where each is
    assert storage(entries, types) == [
        ["storage", "holders.length", word(5), "0", "32", "uint"],
        ["element", "holders[{}]", word(5), "20", "0", "0", "20", "address"],
        ["storage", "stamps.length", word(6), "0", "32", "uint"],
        ["element", "stamps[{}]", word(6), "8", "0", "0", "8", "uint"],
        ["storage", "bao.storage.Pool.queue.length", word(NAMESPACE_SLOT + 2), "0", "32", "uint"],
        ["element", "bao.storage.Pool.queue[{}].amount", word(NAMESPACE_SLOT + 2), "64", "0", "0", "32", "uint"],
        ["element", "bao.storage.Pool.queue[{}].since", word(NAMESPACE_SLOT + 2), "64", "1", "0", "8", "uint"],
        ["element", "bao.storage.Pool.queue[{}].open", word(NAMESPACE_SLOT + 2), "64", "1", "8", "1", "bool"],
    ]


def test_an_array_inside_an_entry_and_a_mapping_inside_an_element_are_listed_by_what_has_a_fixed_place():
    types = {
        "t_address": elementary("address", 20),
        "t_uint256": elementary("uint256", 32),
        "t_array(t_uint256)dyn_storage": dynamic_array("t_uint256", "uint256"),
        "t_mapping(t_address,t_array(t_uint256)dyn_storage)": mapping(
            "t_address", "t_array(t_uint256)dyn_storage", "address", "uint256[]"
        ),
        "t_mapping(t_address,t_uint256)": mapping("t_address", "t_uint256", "address", "uint256"),
        "t_struct(Ledger)6_storage": {
            "encoding": "inplace",
            "label": "struct Pool_v1.Ledger",
            "numberOfBytes": "64",
            "members": [entry("total", 0, "t_uint256"), entry("owed", 1, "t_mapping(t_address,t_uint256)")],
        },
        "t_array(t_struct(Ledger)6_storage)dyn_storage": dynamic_array(
            "t_struct(Ledger)6_storage", "struct Pool_v1.Ledger"
        ),
    }
    entries = [
        entry("claims", 9, "t_mapping(t_address,t_array(t_uint256)dyn_storage)"),
        entry("ledgers", 10, "t_array(t_struct(Ledger)6_storage)dyn_storage"),
    ]

    # the array's elements in an entry, and the mapping's entries in an element, have no listed place
    assert storage(entries, types) == [
        ["entry", "claims[{}].length", word(9), "address", "0", "0", "32", "uint"],
        ["storage", "ledgers.length", word(10), "0", "32", "uint"],
        ["element", "ledgers[{}].total", word(10), "64", "0", "0", "32", "uint"],
    ]


def test_a_string_or_bytes_is_listed_by_its_slot_word():
    types = {
        "t_string_storage": elementary("string", 32, encoding="bytes"),
        "t_bytes_storage": elementary("bytes", 32, encoding="bytes"),
    }
    entries = [entry("name", 6, "t_string_storage"), entry("blob", 7, "t_bytes_storage")]

    assert storage(entries, types) == [
        ["storage", "name", word(6), "0", "32", "raw"],
        ["storage", "blob", word(7), "0", "32", "raw"],
    ]


# ── the listing ────────────────────────────────────────────────────────────────────────────────────

POOL = "0x00000000000000000000000000000000000000A1"
TOKEN = "0x00000000000000000000000000000000000000A2"
POOL_IMPLEMENTATION = "0x00000000000000000000000000000000000000B1"
TOKEN_IMPLEMENTATION = "0x00000000000000000000000000000000000000B2"
PAUSER = "0x00000000000000000000000000000000000000C1"
OLD = "0x00000000000000000000000000000000000000B0"

HARBOR_STATE = {
    "proxies": {
        "GOLD::pool": {"address": POOL, "implementation": POOL_IMPLEMENTATION},
        "GOLD::token": {"address": TOKEN, "implementation": TOKEN_IMPLEMENTATION},
    },
    "implementations": {
        POOL_IMPLEMENTATION: {"contractSource": "@harbor/Pool_v1.sol", "contractType": "Pool_v1"},
        TOKEN_IMPLEMENTATION: {"contractSource": "@bao/Token_v1.sol", "contractType": "Token_v1"},
        OLD: {"contractSource": "@harbor/Pool_v0.sol", "contractType": "Pool_v0"},
    },
}
BAO_BASE_STATE = {"implementations": {PAUSER: {"contractSource": "src/Pauser_v1.sol", "contractType": "Pauser_v1"}}}

BUILD = {
    "Pool_v1": (
        [function("total", outputs=["uint256"])],
        {"total()": "2ddbd13a"},
        {"storage": [entry("total", 0, "t_uint256")], "types": {"t_uint256": elementary("uint256", 32)}},
    ),
    "Token_v1": ([function("decimals", outputs=["uint8"])], {"decimals()": "313ce567"}, {"storage": [], "types": {}}),
    "Pauser_v1": ([function("owner", outputs=["address"])], {"owner()": "8da5cb5b"}, {"storage": [], "types": {}}),
}


def inspected(contract_type):
    """What forge inspect gives a type in BUILD, and None for one it finds no contract of."""
    return BUILD.get(contract_type)


def test_the_listing_names_every_proxy_and_implementation_of_every_state_file():
    lines = deployment_snap.listing_lines([HARBOR_STATE, BAO_BASE_STATE], inspected)

    assert [line for line in lines if not line.startswith(("view\t", "storage\t"))] == [
        f"proxy\tGOLD::pool\t{POOL}",
        f"proxy\tGOLD::token\t{TOKEN}",
        f"implementation\t{POOL_IMPLEMENTATION}\tPool_v1",
        f"implementation\t{TOKEN_IMPLEMENTATION}\tToken_v1",
        f"implementation\t{OLD}\tPool_v0",
        f"implementation\t{PAUSER}\tPauser_v1",
        "absent\tPool_v0",
    ]
    # each type the build has, once, in the order of its name
    assert [line for line in lines if line.startswith(("view\t", "storage\t"))] == [
        "view\tPauser_v1\towner()\t0x8da5cb5b\tnone\taddress",
        "view\tPool_v1\ttotal()\t0x2ddbd13a\tnone\tuint",
        f"storage\tPool_v1\ttotal\t{word(0)}\t0\t32\tuint",
        "view\tToken_v1\tdecimals()\t0x313ce567\tnone\tuint",
    ]


def test_a_type_the_build_lacks_is_listed_as_absent():
    lines = deployment_snap.listing_lines([HARBOR_STATE], inspected)

    assert "absent\tPool_v0" in lines
    assert not [line for line in lines if line.split("\t")[:2] in (["view", "Pool_v0"], ["storage", "Pool_v0"])]


def test_a_type_named_by_the_caller_is_listed_with_no_proxy():
    lines = deployment_snap.listing_lines([HARBOR_STATE], inspected, ["Pauser_v1", "Pool_v1"])

    # listed once, among the state files' types in the order of its name, and no implementation of it is invented
    assert [line for line in lines if line.startswith("view\t")] == [
        "view\tPauser_v1\towner()\t0x8da5cb5b\tnone\taddress",
        "view\tPool_v1\ttotal()\t0x2ddbd13a\tnone\tuint",
        "view\tToken_v1\tdecimals()\t0x313ce567\tnone\tuint",
    ]
    assert not [line for line in lines if line.startswith("implementation\t") and line.endswith("\tPauser_v1")]


def test_a_type_named_by_the_caller_the_build_lacks_stops_the_listing():
    with pytest.raises(SystemExit) as raised:
        deployment_snap.listing_lines([HARBOR_STATE], inspected, ["Missing_v1"])

    assert str(raised.value) == "❌ --type Missing_v1: the build has no contract of that name"


def test_a_proxy_key_in_two_state_files_stops_the_listing():
    with pytest.raises(SystemExit) as raised:
        deployment_snap.listing_lines([HARBOR_STATE, HARBOR_STATE], inspected)

    assert str(raised.value) == "❌ the proxy GOLD::pool is in more than one state file"


def test_an_implementation_two_state_files_name_differently_stops_the_listing():
    renamed = {"implementations": {OLD: {"contractSource": "@harbor/Other.sol", "contractType": "Other_v1"}}}
    with pytest.raises(SystemExit) as raised:
        deployment_snap.listing_lines([HARBOR_STATE, renamed], inspected)

    assert str(raised.value) == f"❌ the implementation {OLD} is a Pool_v0 in one state file and a Other_v1 in another"


# ── main ───────────────────────────────────────────────────────────────────────────────────────────

BLOCK = 26476880
READINGS = ["GOLD::token\tdecimals()\t18", "GOLD::pool\ttotal()\t5", "GOLD::pool\taccount nonce\t1"]


class _Processes:
    """Stands in for every process the snap starts. `cast block-number` answers BLOCK; `forge inspect` answers from
    BUILD, and for any other type as forge does for a contract it does not find; the forge script writes READINGS, in
    the order given, to the path it is handed last, unless it is made to fail."""

    def __init__(self):
        self.calls = []
        self.script_fails = False

    def run(self, command, **kwargs):
        self.calls.append(command)
        if command[:2] == ["cast", "block-number"]:
            return _Completed(f"{BLOCK}\n")
        if command[:2] == ["forge", "inspect"]:
            contract_type, field = command[2], command[3]
            if contract_type not in BUILD:
                return _Completed(returncode=1, stderr=f"Error: No contract found with the name `{contract_type}`\n")
            abi, methods, layout = BUILD[contract_type]
            return _Completed(json.dumps({"abi": abi, "methodIdentifiers": methods, "storageLayout": layout}[field]))
        if command[:2] == ["forge", "script"]:
            if self.script_fails:
                return _Completed(returncode=1)
            with open(command[-1], "w") as out:
                out.write("\n".join(READINGS) + "\n")
            return _Completed()
        raise AssertionError(f"unexpected process {command}")


class _Completed:
    def __init__(self, stdout="", returncode=0, stderr=""):
        self.stdout = stdout
        self.returncode = returncode
        self.stderr = stderr


@pytest.fixture
def project(tmp_path, monkeypatch):
    """A project root with harbor's and bao-base's state files, every process the snap starts replaced."""
    (tmp_path / "foundry.toml").write_text('[profile.default]\nsrc = "src"\n')
    (tmp_path / "harbor.state.json").write_text(json.dumps(HARBOR_STATE))
    (tmp_path / "bao-base.state.json").write_text(json.dumps(BAO_BASE_STATE))
    monkeypatch.chdir(tmp_path)
    processes = _Processes()
    monkeypatch.setattr(deployment_snap.subprocess, "run", processes.run)
    return processes


def _snap(monkeypatch, *arguments):
    monkeypatch.setattr(sys, "argv", ["snap", *arguments])
    return deployment_snap.main(sys.argv[1:])


STATES = ["--state", "harbor.state.json", "--state", "bao-base.state.json"]


def _script(calls):
    scripts = [command for command in calls if command[:2] == ["forge", "script"]]
    assert len(scripts) == 1, calls
    return scripts[0]


def test_the_snap_reads_at_the_block_and_writes_its_readings_sorted(project, tmp_path, monkeypatch, capsys):
    known = "0x000000000000000000000000000000000000dEaD"
    _snap(monkeypatch, "--network", "mainnet", "--prefix", "GOLD::", *STATES, "--known", known, "--known", POOL)

    script = _script(project.calls)
    signature = script[script.index("--sig") + 1]
    assert signature == "run(string,uint256,string,string,address[],string)", script
    arguments = script[script.index("--sig") + 2 :]
    listing = "tmp/snap/GOLD_mainnet_26476880.listing.tsv"
    unsorted = "tmp/snap/GOLD_mainnet_26476880.unsorted.tsv"
    assert arguments == ["mainnet", str(BLOCK), listing, "GOLD::", f"[{known},{POOL}]", unsorted], script
    # the listing the script read is the one the state files and the build give
    expected = deployment_snap.listing_lines([HARBOR_STATE, BAO_BASE_STATE], inspected)
    assert (tmp_path / listing).read_text() == "\n".join(expected) + "\n"
    # the block was asked of the network, before anything was read at it
    assert project.calls[0] == ["cast", "block-number", "--rpc-url", "mainnet"], project.calls
    written = tmp_path / "tmp/snap/GOLD_mainnet_26476880.tsv"
    assert written.read_text() == "\n".join(sorted(READINGS)) + "\n"
    assert capsys.readouterr().out.strip() == "tmp/snap/GOLD_mainnet_26476880.tsv"


def test_a_snap_at_a_given_block_asks_for_no_block(project, monkeypatch):
    _snap(monkeypatch, "--network", "mainnet", "--block", "123", "--prefix", "GOLD::", *STATES)

    assert not [command for command in project.calls if command[:2] == ["cast", "block-number"]], project.calls
    script = _script(project.calls)
    assert script[script.index("--sig") + 2 : script.index("--sig") + 4] == ["mainnet", "123"], script
    assert script[script.index("--sig") + 6] == "[]", script


def test_the_snap_lists_each_type_it_is_given(project, tmp_path, monkeypatch):
    _snap(monkeypatch, "--network", "mainnet", "--prefix", "GOLD::", "--state", "harbor.state.json", "--type", "Pauser_v1")

    listing = (tmp_path / "tmp/snap/GOLD_mainnet_26476880.listing.tsv").read_text().splitlines()
    assert listing == deployment_snap.listing_lines([HARBOR_STATE], inspected, ["Pauser_v1"])
    assert "view\tPauser_v1\towner()\t0x8da5cb5b\tnone\taddress" in listing


def test_a_local_snap_reads_the_local_node(project, tmp_path, monkeypatch):
    _snap(monkeypatch, "--network", "mainnet", "--local", "--prefix", "GOLD::", *STATES)

    assert project.calls[0] == ["cast", "block-number", "--rpc-url", "local"], project.calls
    script = _script(project.calls)
    assert script[script.index("--sig") + 2] == "local", script
    assert (tmp_path / "tmp/snap/GOLD_mainnet_local_26476880.tsv").is_file()


def test_a_failed_read_stops_the_snap_before_the_file_is_written(project, tmp_path, monkeypatch):
    project.script_fails = True
    with pytest.raises(SystemExit) as raised:
        _snap(monkeypatch, "--network", "mainnet", "--prefix", "GOLD::", *STATES)

    assert str(raised.value) == "❌ the read at block 26476880 failed: forge script exited 1"
    assert not (tmp_path / "tmp/snap/GOLD_mainnet_26476880.tsv").exists()


def test_a_failed_inspect_stops_the_snap_with_forge_s_error(project, monkeypatch):
    def failing(command, **kwargs):
        if command[:2] == ["forge", "inspect"]:
            return _Completed(returncode=1, stderr="Error: Compiler run failed\n")
        return project.run(command, **kwargs)

    monkeypatch.setattr(deployment_snap.subprocess, "run", failing)
    with pytest.raises(SystemExit) as raised:
        _snap(monkeypatch, "--network", "mainnet", "--prefix", "GOLD::", *STATES)

    assert str(raised.value) == "❌ forge inspect Pauser_v1 abi failed: Error: Compiler run failed"


def test_the_script_the_snap_runs_is_bao_base_s(project, monkeypatch):
    _snap(monkeypatch, "--network", "mainnet", "--prefix", "GOLD::", *STATES)

    path, contract = _script(project.calls)[2].rsplit(":", 1)
    # a script, so under script/: test code forks only at the blocks test/fork-blocks.toml lists, and a snap reads at
    # any block it is asked for
    assert (Path.cwd() / path).resolve() == (deployment_snap.BAO_BASE / "script/snap/DumpSnap.s.sol").resolve(), path
    assert contract == "DumpSnap"
