"""Unit tests for the successor RULE in bin/storage-successor.py (successor_errors).

These pin the rule's branches with synthetic storageLayout dicts — the cheap, exhaustive way to cover every
kind of change and every container nesting. The rule accepts a change only where it leaves every byte the
predecessor wrote where it was AND its owning struct documents it: an integer field widened in place
(`@custom:bao-retyped-from <field> <oldType>`, oldType matching the predecessor), a field added in unused bytes
(`@custom:bao-added`), a field renamed (`@custom:bao-renamed-from`) and an unsigned mapping key widened
(`@custom:bao-rekeyed-from <field> <oldKeyType>`); everything else is rejected. The end-to-end pipeline (extract
-> inject -> build -> this rule on REAL solc output) is covered separately by the .sol-fixture integration test,
which also keeps these synthetic layouts honest — if their shape ever diverged from solc's, that test's verdict
would break.

The golden case is the StabilityPool widening: TokenBalance.amount uint104 -> uint128, exercised directly and
through a mapping, a dynamic array, a static array, and a mapping-of-mappings. For a widened key the golden case
is a pool's reward integrals: the inner key of `mapping(address => mapping(uint8 => uint256))`, uint8 -> uint256.
"""

import copy
import importlib.util
import json
import os
import pathlib

import pytest


def load_module():
    module_path = pathlib.Path(__file__).resolve().parents[2] / "bin" / "storage-successor.py"
    spec = importlib.util.spec_from_file_location("storage_successor", module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


mod = load_module()


def _int(bits, signed=False):
    return {"encoding": "inplace", "label": ("int" if signed else "uint") + str(bits), "numberOfBytes": str(bits // 8)}


BASE_TYPES = {
    "t_uint256": _int(256),
    "t_uint192": _int(192),
    "t_uint136": _int(136),
    "t_uint128": _int(128),
    "t_uint104": _int(104),
    "t_uint64": _int(64),
    "t_uint40": _int(40),
    "t_uint16": _int(16),
    "t_uint8": _int(8),
    "t_int256": _int(256, signed=True),
    "t_int128": _int(128, signed=True),
    "t_int104": _int(104, signed=True),
    "t_address": {"encoding": "inplace", "label": "address", "numberOfBytes": "20"},
    "t_bytes32": {"encoding": "inplace", "label": "bytes32", "numberOfBytes": "32"},
}

DOC = {"TokenBalance": {"amount": "uint104"}}  # documents the amount widen on its owning struct


def _user_defined(name, nbytes, ast_id):
    """What solc lays out for a user-defined value type: its own kind of type id, and the type's name as the label.
    The name is free, so it can read as an integer type that Solidity does not have, such as `uint7`."""
    return f"t_userDefinedValueType({name}){ast_id}", {"encoding": "inplace", "label": name, "numberOfBytes": nbytes}


def token_balance(amount="t_uint104", moved=False):
    """The TokenBalance struct type. When `moved`, amount has overflowed slot 0 (as solc relocates an
    over-wide widen), pushing amount to slot 1 and updatedAt to slot 2."""
    if moved:
        members = [
            {"label": "product", "slot": "0", "offset": 0, "type": "t_uint128"},
            {"label": "amount", "slot": "1", "offset": 0, "type": amount},
            {"label": "updatedAt", "slot": "2", "offset": 0, "type": "t_uint40"},
        ]
        nbytes = "96"
    else:
        members = [
            {"label": "product", "slot": "0", "offset": 0, "type": "t_uint128"},
            {"label": "amount", "slot": "0", "offset": 16, "type": amount},
            {"label": "updatedAt", "slot": "1", "offset": 0, "type": "t_uint40"},
        ]
        nbytes = "64"
    return {"encoding": "inplace", "label": "struct TokenBalance", "numberOfBytes": nbytes, "members": members}


def flat(amount="t_uint104", moved=False, tb=None):
    """A top-level var of the TokenBalance struct."""
    types = dict(BASE_TYPES)
    types["t_tb"] = tb if tb is not None else token_balance(amount, moved)
    return {"storage": [{"label": "pool", "slot": "0", "offset": 0, "type": "t_tb"}], "types": types}


def single(x_type):
    """A top-level var of an arbitrary type — for kind/elementary changes that need no struct."""
    return {"storage": [{"label": "v", "slot": "0", "offset": 0, "type": x_type}], "types": dict(BASE_TYPES)}


def contained(kind, amount="t_uint104"):
    """A root struct whose single member reaches a TokenBalance through a container: 'direct', 'mapping',
    'dynarray', 'staticarray', or 'mapmap'."""
    types = dict(BASE_TYPES)
    types["t_tb"] = token_balance(amount)
    if kind == "direct":
        member = "t_tb"
    elif kind == "mapping":
        types["t_map"] = {
            "encoding": "mapping",
            "label": "mapping(address => TokenBalance)",
            "numberOfBytes": "32",
            "key": "t_address",
            "value": "t_tb",
        }
        member = "t_map"
    elif kind == "dynarray":
        types["t_arr"] = {"encoding": "dynamic_array", "label": "TokenBalance[]", "numberOfBytes": "32", "base": "t_tb"}
        member = "t_arr"
    elif kind == "staticarray":
        types["t_sarr"] = {"encoding": "inplace", "label": "TokenBalance[3]", "numberOfBytes": "192", "base": "t_tb"}
        member = "t_sarr"
    elif kind == "mapmap":
        types["t_inner"] = {
            "encoding": "mapping",
            "label": "mapping(uint256 => TokenBalance)",
            "numberOfBytes": "32",
            "key": "t_uint256",
            "value": "t_tb",
        }
        types["t_outer"] = {
            "encoding": "mapping",
            "label": "mapping(address => mapping(uint256 => TokenBalance))",
            "numberOfBytes": "32",
            "key": "t_address",
            "value": "t_inner",
        }
        member = "t_outer"
    types["t_root"] = {
        "encoding": "inplace",
        "label": "struct Root",
        "numberOfBytes": "32",
        "members": [{"label": "field", "slot": "0", "offset": 0, "type": member}],
    }
    return {"storage": [{"label": "root", "slot": "0", "offset": 0, "type": "t_root"}], "types": types}


V2 = flat("t_uint104")  # deployed: uint104 amount


def _own_declarations(layout):
    """The layout with every struct given a type id of its own. solc gives each struct declaration its own type id,
    and one type id in both layouts means one declaration on both sides, which the rule does not compare. A
    successor declares its own structs, so its made-up layout must not share a struct's id with the predecessor's."""
    own = {type_id: f"{type_id}_successor" for type_id, type_def in layout["types"].items() if "members" in type_def}
    types = {}
    for type_id, type_def in layout["types"].items():
        type_def = copy.deepcopy(type_def)
        for member in type_def.get("members", []):
            member["type"] = own.get(member["type"], member["type"])
        for holds in ("value", "base"):
            if holds in type_def:
                type_def[holds] = own.get(type_def[holds], type_def[holds])
        types[own.get(type_id, type_id)] = type_def
    storage = [{**entry, "type": own.get(entry["type"], entry["type"])} for entry in layout["storage"]]
    return {"storage": storage, "types": types}


def errors(a, b, retyped=None, added=None, renamed=None, rekeyed=None):
    """What stops `b` being a successor of `a`, where `b` declares its own structs: the usual case. A test of one
    declaration on both sides calls `mod.successor_errors` itself, with the struct's type id in both layouts."""
    b = _own_declarations(b)
    if rekeyed is not None:
        return mod.successor_errors(a, b, retyped, added, renamed, rekeyed)
    if renamed is None:
        return mod.successor_errors(a, b, retyped, added)
    return mod.successor_errors(a, b, retyped, added, renamed)


REKEYED = {"Root": {"field": "uint8"}}  # documents the key widen on its owning struct


def root_of(members):
    """A root struct of mappings to uint256, one slot each: `members` lists (label, keyTypeId), or with a third
    item the key type of a mapping the first one holds - (label, outerKeyTypeId, innerKeyTypeId)."""
    types = dict(BASE_TYPES)
    struct_members = []
    for slot, (label, key, *inner) in enumerate(members):
        value = "t_uint256"
        if inner:
            value = f"t_inner_{label}"
            types[value] = {
                "encoding": "mapping",
                "label": f"mapping({types[inner[0]]['label']} => uint256)",
                "numberOfBytes": "32",
                "key": inner[0],
                "value": "t_uint256",
            }
        type_id = f"t_map_{label}"
        types[type_id] = {
            "encoding": "mapping",
            "label": f"mapping({types[key]['label']} => ...)",
            "numberOfBytes": "32",
            "key": key,
            "value": value,
        }
        struct_members.append({"label": label, "slot": str(slot), "offset": 0, "type": type_id})
    types["t_root"] = {
        "encoding": "inplace",
        "label": "struct Root",
        "numberOfBytes": str(32 * len(members)),
        "members": struct_members,
    }
    return {"storage": [{"label": "root", "slot": "0", "offset": 0, "type": "t_root"}], "types": types}


def keyed(kind, key="t_uint8", amount=None):
    """A root struct whose single member `field` holds a mapping keyed by `key`: 'direct' (the mapping itself),
    'mapmap' (under an address-keyed mapping, the shape of reward integrals kept by token and by exponent),
    'staticarray' (three of them) or 'instruct' (as member `byKey` of a struct that an address-keyed mapping
    holds). The mapping's value is a uint256, or with `amount` a TokenBalance whose amount has that type."""
    types = dict(BASE_TYPES)
    value = "t_uint256"
    if amount is not None:
        types["t_tb"] = token_balance(amount)
        value = "t_tb"
    key_label = types[key]["label"]
    value_label = "TokenBalance" if amount is not None else "uint256"
    types["t_keyed"] = {
        "encoding": "mapping",
        "label": f"mapping({key_label} => {value_label})",
        "numberOfBytes": "32",
        "key": key,
        "value": value,
    }
    nbytes = "32"
    if kind == "direct":
        member = "t_keyed"
    elif kind == "mapmap":
        types["t_outer"] = {
            "encoding": "mapping",
            "label": f"mapping(address => mapping({key_label} => {value_label}))",
            "numberOfBytes": "32",
            "key": "t_address",
            "value": "t_keyed",
        }
        member = "t_outer"
    elif kind == "staticarray":
        types["t_sarr"] = {
            "encoding": "inplace",
            "label": f"mapping({key_label} => {value_label})[3]",
            "numberOfBytes": "96",
            "base": "t_keyed",
        }
        member = "t_sarr"
        nbytes = "96"
    elif kind == "instruct":
        types["t_inner"] = {
            "encoding": "inplace",
            "label": "struct Inner",
            "numberOfBytes": "32",
            "members": [{"label": "byKey", "slot": "0", "offset": 0, "type": "t_keyed"}],
        }
        types["t_outer"] = {
            "encoding": "mapping",
            "label": "mapping(address => Inner)",
            "numberOfBytes": "32",
            "key": "t_address",
            "value": "t_inner",
        }
        member = "t_outer"
    types["t_root"] = {
        "encoding": "inplace",
        "label": "struct Root",
        "numberOfBytes": nbytes,
        "members": [{"label": "field", "slot": "0", "offset": 0, "type": member}],
    }
    return {"storage": [{"label": "root", "slot": "0", "offset": 0, "type": "t_root"}], "types": types}


def nested(depth, tb=None):
    """A top-level var reaching a TokenBalance nested `depth` struct-layers deep (depth 0 = TokenBalance is the
    top-level var itself). Each wrapping layer holds the previous type as its single member, so nesting alone
    changes no struct's size."""
    types = dict(BASE_TYPES)
    types["t_tb"] = tb if tb is not None else token_balance()
    inner = "t_tb"
    for d in range(depth):
        name = f"t_L{d}"
        types[name] = {
            "encoding": "inplace",
            "label": f"struct L{d}",
            "numberOfBytes": types[inner]["numberOfBytes"],
            "members": [{"label": "inner", "slot": "0", "offset": 0, "type": inner}],
        }
        inner = name
    return {"storage": [{"label": "v", "slot": "0", "offset": 0, "type": inner}], "types": types}


def _tb_padding_append():
    """TokenBalance with a size-preserving `extra` packed into slot-1 trailing padding (numberOfBytes stays 64)."""
    tb = token_balance()
    tb["members"] = tb["members"] + [{"label": "extra", "slot": "1", "offset": 5, "type": "t_uint40"}]
    return tb


def _tb_growing_append():
    """TokenBalance with `extra` in a fresh slot 2 (numberOfBytes 64 -> 96)."""
    tb = token_balance()
    tb["members"] = tb["members"] + [{"label": "extra", "slot": "2", "offset": 0, "type": "t_uint256"}]
    tb["numberOfBytes"] = "96"
    return tb


ADDED = {"TokenBalance": {"extra"}}  # documents the `extra` append on its owning struct


def has(errs, *needles):
    return any(all(n in e for n in needles) for e in errs)


# ── accepted: a documented integer widen, direct and through every container ──────────────────────────────


def test_documented_widen_is_a_successor():
    assert errors(V2, flat("t_uint128"), DOC) == []


def test_identical_layout_is_a_successor():
    assert errors(V2, V2) == []


def test_documented_widen_through_mapping():
    assert errors(contained("mapping"), contained("mapping", "t_uint128"), DOC) == []


def test_documented_widen_through_dynamic_array():
    assert errors(contained("dynarray"), contained("dynarray", "t_uint128"), DOC) == []


def test_documented_widen_through_static_array():
    assert errors(contained("staticarray"), contained("staticarray", "t_uint128"), DOC) == []


def test_documented_widen_through_mapping_of_mappings():
    assert errors(contained("mapmap"), contained("mapmap", "t_uint128"), DOC) == []


# ── rejected: the documentation gate ──────────────────────────────────────────────────────────────────────


def test_undocumented_widen_is_rejected():
    assert has(errors(V2, flat("t_uint128")), "amount", "undocumented widen")


def test_undocumented_widen_through_mapping_is_rejected():
    assert has(errors(contained("mapping"), contained("mapping", "t_uint128")), "amount", "undocumented widen")


def test_undocumented_widen_through_static_array_is_rejected():
    # discriminates the static-array fix: without treating a static array as a container, the inner change
    # is compared by label ("TokenBalance[3]") and silently missed.
    assert has(errors(contained("staticarray"), contained("staticarray", "t_uint128")), "amount", "undocumented widen")


def test_stale_declaration_is_rejected():
    assert has(errors(V2, flat("t_uint104"), DOC), "amount", "stale")


def test_declaration_naming_unknown_field_is_rejected():
    assert has(errors(V2, flat("t_uint128"), {"TokenBalance": {"typo": "uint104"}}), "typo", "was not compared")


def test_retyped_declaration_names_the_field_as_the_successor_does():
    # renamed and widened in one step: the declaration sits on the successor's struct and uses its name
    widened = token_balance("t_uint128")
    widened["members"][1]["label"] = "balance"
    renamed = {"TokenBalance": {"balance": "amount"}}
    assert errors(V2, flat(tb=widened), {"TokenBalance": {"balance": "uint104"}}, None, renamed) == []
    errs = errors(V2, flat(tb=widened), DOC, None, renamed)
    assert has(errs, "undocumented widen"), errs
    assert has(errs, "TokenBalance.amount", "was not compared"), errs


def test_wrong_declared_old_type_is_rejected():
    # declared uint96 but the predecessor is really uint104
    assert has(
        errors(V2, flat("t_uint128"), {"TokenBalance": {"amount": "uint96"}}), "amount", "predecessor is uint104"
    )


def test_declaration_on_non_integer_field_is_rejected():
    # declaring a retype on a mapping member (Root.field) — a widen only ever applies to an integer leaf
    a = contained("mapping")
    assert has(errors(a, a, {"Root": {"field": "uint104"}}), "field", "non-integer")


# ── rejected: every non-widen change (even when documented, a widen that doesn't fit / flips sign / narrows) ─


def test_overflow_widen_that_relocates_is_rejected_even_when_documented():
    # uint192 can't fit amount's slot; solc relocates it. Documented or not, a moved field is rejected —
    # and because the field exists (it just moved), the declaration must NOT be misreported as "not found".
    errs = errors(V2, flat("t_uint192", moved=True), DOC)
    assert has(errs, "amount", "moved")
    assert not has(errs, "was not compared"), errs


def test_narrowed_amount_is_rejected():
    assert has(errors(V2, flat("t_uint64")), "amount", "narrowed")


def test_signed_widen_is_rejected_even_when_documented():
    # a stored -1 fills the old width with ones, and the bytes the wider type adds are zero in storage: read at
    # the wider type it is 2**104 - 1
    for retyped in (None, {"TokenBalance": {"amount": "int104"}}):
        errs = errors(flat("t_int104"), flat("t_int128"), retyped)
        assert has(errs, "amount", "signed integer widened", "int104 -> int128"), errs
        assert len(errs) == 1, errs


def test_signedness_change_is_rejected_even_when_documented():
    assert has(errors(V2, flat("t_int128"), DOC), "amount", "signedness")


def test_kind_change_is_rejected():
    assert has(errors(single("t_uint256"), single("t_bytes32")), "kind changed")


def test_elementary_change_is_rejected():
    assert has(errors(single("t_bytes32"), single("t_address")), "type changed")


def test_removed_member_is_rejected():
    without = token_balance()
    without["members"] = without["members"][:2]  # drop updatedAt
    assert has(errors(V2, flat(tb=without)), "updatedAt", "removed")


# ── documented appends: the top-level namespace struct may grow; an embedded struct may only take a
#    size-preserving append (packs into its own padding, never over its slot count). Tested at 0/1/N embedding. ──


def test_documented_top_level_grow_is_accepted():
    # depth 0 (the namespace struct itself): a new trailing slot is fresh storage, so a grow is safe.
    assert errors(nested(0), nested(0, tb=_tb_growing_append()), None, ADDED) == []


def test_documented_size_preserving_append_is_accepted_at_every_depth():
    # a size-preserving append packs into the struct's own padding — safe at any embedding depth.
    for depth in (0, 1, 2, 3):
        assert errors(nested(depth), nested(depth, tb=_tb_padding_append()), None, ADDED) == [], f"depth {depth}"


def test_growing_append_to_embedded_struct_is_rejected_at_every_depth():
    # depth >= 1: growing an embedded struct relocates the storage after it — rejected even when documented.
    for depth in (1, 2, 3):
        errs = errors(nested(depth), nested(depth, tb=_tb_growing_append()), None, ADDED)
        assert has(errs, "extra", "grows"), f"depth {depth}: {errs}"


def test_undocumented_append_is_rejected():
    assert has(errors(nested(0), nested(0, tb=_tb_padding_append())), "extra", "undocumented")


def test_inserted_member_is_rejected():
    tb = token_balance()
    tb["members"] = tb["members"] + [
        {"label": "extra", "slot": "0", "offset": 0, "type": "t_uint40"}
    ]  # overlaps product
    assert has(errors(nested(0), nested(0, tb=tb), None, ADDED), "extra", "overlapping")


def test_each_tag_marks_its_own_use():
    # a field's `bao-added` does not stand for a `bao-retyped-from` of the same field, which documents nothing
    a, b = nested(0), nested(0, tb=_tb_padding_append())
    errs = errors(a, b, {"TokenBalance": {"extra": "uint8"}}, ADDED)
    assert has(errs, "TokenBalance.extra", "bao-retyped-from", "not compared"), errs
    assert len(errs) == 1, errs
    # nor a field's `bao-renamed-from` for a `bao-added` of the same field: it was renamed, not added
    errs = errors(V2, flat(tb=_tb_renamed()), None, {"TokenBalance": {"amountRenamed"}}, RENAMED)
    assert has(errs, "TokenBalance.amountRenamed", "bao-added", "not added"), errs
    assert len(errs) == 1, errs
    # nor a field's `bao-retyped-from` for a `bao-renamed-from` of the same field: it kept its name
    errs = errors(V2, flat("t_uint128"), DOC, None, {"TokenBalance": {"amount": "balance"}})
    assert has(errs, "TokenBalance.amount", "bao-renamed-from", "not renamed"), errs
    assert len(errs) == 1, errs


def test_stale_added_declaration_is_rejected():
    # names a field that is not actually a new member
    assert has(errors(nested(0), nested(0), None, {"TokenBalance": {"ghost"}}), "ghost", "not added")


def test_reordered_members_is_rejected():
    swapped = {
        "encoding": "inplace",
        "label": "struct TokenBalance",
        "numberOfBytes": "64",
        "members": [
            {"label": "product", "slot": "0", "offset": 13, "type": "t_uint128"},
            {"label": "amount", "slot": "0", "offset": 0, "type": "t_uint104"},
            {"label": "updatedAt", "slot": "1", "offset": 0, "type": "t_uint40"},
        ],
    }
    assert has(errors(V2, flat(tb=swapped)), "moved")


def test_mapping_key_change_is_rejected():
    a = contained("mapping")
    b = contained("mapping", "t_uint128")
    b["types"]["t_map"]["key"] = "t_bytes32"  # address -> bytes32 key
    assert has(errors(a, b, DOC), "mapping key changed")


# ── what solc's type id tells where the label does not: whether a type is a built-in integer, and whether a
#    user-defined value type or an enum is one declaration on both sides. A user-defined value type's label is only
#    its name: it can read as an integer, and two declarations of one name can stand over different types. ──────


def _struct_of(member_type_id, extra_types=None):
    """A top-level struct `S` of one member `f` of this type."""
    types = dict(BASE_TYPES)
    types.update(extra_types or {})
    types["t_s"] = {
        "encoding": "inplace",
        "label": "struct S",
        "numberOfBytes": "32",
        "members": [{"label": "f", "slot": "0", "offset": 0, "type": member_type_id}],
    }
    return {"storage": [{"label": "s", "slot": "0", "offset": 0, "type": "t_s"}], "types": types}


def test_field_of_a_user_defined_type_named_like_an_integer_is_not_an_integer():
    # `type uint9 is int8;` compiles. Widened to uint16 as if it were an unsigned integer, a stored -1 would read 255.
    fake_id, fake = _user_defined("uint9", "1", 5)
    errs = errors(_struct_of(fake_id, {fake_id: fake}), _struct_of("t_uint16"), {"S": {"f": "uint9"}})
    assert has(errs, "f", "kind changed"), errs


def test_field_of_a_user_defined_type_of_another_declaration_is_rejected():
    # `type Id is bytes4;` in one file and `type Id is uint32;` in another: one label, four bytes each, other bytes
    a_id, a_type = _user_defined("Id", "4", 3)
    b_id, b_type = _user_defined("Id", "4", 9)
    errs = errors(_struct_of(a_id, {a_id: a_type}), _struct_of(b_id, {b_id: b_type}))
    assert has(errs, "f", "Id", "not the same declaration"), errs


def test_key_of_a_user_defined_type_of_another_declaration_is_rejected():
    a_id, a_type = _user_defined("Id", "4", 3)
    b_id, b_type = _user_defined("Id", "4", 9)
    a, b = keyed("direct"), keyed("direct")
    a["types"][a_id], b["types"][b_id] = a_type, b_type
    a["types"]["t_keyed"]["key"], b["types"]["t_keyed"]["key"] = a_id, b_id
    errs = errors(a, b)
    assert has(errs, "field", "Id", "not the same declaration"), errs
    assert len(errs) == 1, errs
    # a key declaration does not make it one, and is not also reported as documenting nothing
    errs = errors(a, b, rekeyed={"Root": {"field": "uint8"}})
    assert has(errs, "field", "Id", "not the same declaration"), errs
    assert len(errs) == 1, errs


def test_user_defined_type_of_the_same_declaration_is_a_successor():
    type_id, type_def = _user_defined("Id", "4", 3)
    assert errors(_struct_of(type_id, {type_id: type_def}), _struct_of(type_id, {type_id: type_def})) == []
    a, b = keyed("direct"), keyed("direct")
    for layout in (a, b):
        layout["types"][type_id] = type_def
        layout["types"]["t_keyed"]["key"] = type_id
    assert errors(a, b) == []


def _named(kind, label, nbytes, ast_id):
    """What solc lays out for a contract type or an enum: a type id that carries the id of its declaration."""
    return f"t_{kind}({label.split()[-1]}){ast_id}", {"encoding": "inplace", "label": label, "numberOfBytes": nbytes}


def test_contract_type_is_compared_by_label():
    # a contract is stored as an address whatever it declares
    a_id, a_type = _named("contract", "contract IThing", "20", 11)
    b_id, b_type = _named("contract", "contract IThing", "20", 22)
    assert errors(_struct_of(a_id, {a_id: a_type}), _struct_of(b_id, {b_id: b_type})) == []


def test_enum_of_another_declaration_is_rejected():
    # `enum Mode {Idle, Active, Closed}` in one file and `enum Mode {Closed, Idle}` in another: one label, one byte
    # each, and a stored Idle would read Closed
    a_id, a_type = _named("enum", "enum Types.Mode", "1", 11)
    b_id, b_type = _named("enum", "enum Types.Mode", "1", 22)
    errs = errors(_struct_of(a_id, {a_id: a_type}), _struct_of(b_id, {b_id: b_type}))
    assert has(errs, "f", "enum Types.Mode", "not the same declaration"), errs
    assert len(errs) == 1, errs
    # as a mapping key too
    a, b = keyed("direct"), keyed("direct")
    a["types"][a_id], b["types"][b_id] = a_type, b_type
    a["types"]["t_keyed"]["key"], b["types"]["t_keyed"]["key"] = a_id, b_id
    errs = errors(a, b)
    assert has(errs, "field", "enum Types.Mode", "not the same declaration"), errs
    assert len(errs) == 1, errs


def test_enum_of_the_same_declaration_is_a_successor():
    type_id, type_def = _named("enum", "enum Types.Mode", "1", 11)
    assert errors(_struct_of(type_id, {type_id: type_def}), _struct_of(type_id, {type_id: type_def})) == []


# ── a struct that holds itself, through a mapping or an array: legal, and the walk must end ─────────────────


def _self_holding(through, value="t_uint104"):
    """A top-level struct `Node` holding itself beside a `value`: as `mapping(uint256 => Node) children`, or as
    `Node[] children`."""
    types = dict(BASE_TYPES)
    if through == "mapping":
        types["t_children"] = {
            "encoding": "mapping",
            "label": "mapping(uint256 => struct Node)",
            "numberOfBytes": "32",
            "key": "t_uint256",
            "value": "t_node",
        }
    else:
        types["t_children"] = {
            "encoding": "dynamic_array",
            "label": "struct Node[]",
            "numberOfBytes": "32",
            "base": "t_node",
        }
    types["t_node"] = {
        "encoding": "inplace",
        "label": "struct Node",
        "numberOfBytes": "64",
        "members": [
            {"label": "children", "slot": "0", "offset": 0, "type": "t_children"},
            {"label": "value", "slot": "1", "offset": 0, "type": value},
        ],
    }
    return {"storage": [{"label": "root", "slot": "0", "offset": 0, "type": "t_node"}], "types": types}


@pytest.mark.parametrize("through", ["mapping", "dynarray"])
def test_struct_that_holds_itself_ends_the_walk(through):
    a, b = _self_holding(through), _self_holding(through, "t_uint128")
    assert errors(a, a) == []
    assert errors(a, b, {"Node": {"value": "uint104"}}) == []
    # the top-level struct is compared once at the top level and once where it is nested: the two positions differ
    # in what they allow, and a change inside is a change at each
    errs = errors(a, b)
    assert has(errs, "root.value", "undocumented widen"), errs
    assert has(errs, "root.children", "].value", "undocumented widen"), errs
    assert len(errs) == 2, errs


def _grown(layout, struct_id):
    """The layout with a member `extra` appended to this struct in a slot of its own, so the struct takes one more."""
    struct = layout["types"][struct_id]
    slots = int(struct["numberOfBytes"]) // 32
    struct["members"].append({"label": "extra", "slot": str(slots), "offset": 0, "type": "t_uint256"})
    struct["numberOfBytes"] = str(32 * (slots + 1))
    return layout


@pytest.mark.parametrize("through", ["mapping", "dynarray"])
def test_namespace_struct_that_holds_itself_may_not_grow(through):
    # at the top level the new member takes fresh storage. Nested in itself the struct takes a slot more, as any
    # nested struct that grows: in an array every element after the first moves
    errs = errors(_self_holding(through), _grown(_self_holding(through), "t_node"), None, {"Node": {"extra"}})
    assert has(errs, "root.children", "].extra", "grows a nested struct"), errs
    assert len(errs) == 1, errs


def _holding_each_other():
    """A top-level struct `S` holding `mapping(uint256 => T) ts` beside a `value`, where `T` holds `S[] parents`."""
    types = dict(BASE_TYPES)
    types["t_ts"] = {
        "encoding": "mapping",
        "label": "mapping(uint256 => struct T)",
        "numberOfBytes": "32",
        "key": "t_uint256",
        "value": "t_t",
    }
    types["t_parents"] = {"encoding": "dynamic_array", "label": "struct S[]", "numberOfBytes": "32", "base": "t_s"}
    types["t_t"] = {
        "encoding": "inplace",
        "label": "struct T",
        "numberOfBytes": "32",
        "members": [{"label": "parents", "slot": "0", "offset": 0, "type": "t_parents"}],
    }
    types["t_s"] = {
        "encoding": "inplace",
        "label": "struct S",
        "numberOfBytes": "64",
        "members": [
            {"label": "ts", "slot": "0", "offset": 0, "type": "t_ts"},
            {"label": "value", "slot": "1", "offset": 0, "type": "t_uint256"},
        ],
    }
    return {"storage": [{"label": "root", "slot": "0", "offset": 0, "type": "t_s"}], "types": types}


def test_structs_that_hold_each_other_may_not_grow():
    assert errors(_holding_each_other(), _holding_each_other()) == []
    errs = errors(_holding_each_other(), _grown(_holding_each_other(), "t_s"), None, {"S": {"extra"}})
    assert has(errs, "root.ts[k].parents[i].extra", "grows a nested struct"), errs
    assert len(errs) == 1, errs


def test_struct_under_two_members_of_one_struct_is_reported_at_each():
    # a struct is passed over only inside its own comparison: the first member's is over when the second is met
    def two(amount):
        types = dict(BASE_TYPES)
        types["t_tb"] = token_balance(amount)
        types["t_root"] = {
            "encoding": "inplace",
            "label": "struct Root",
            "numberOfBytes": "128",
            "members": [
                {"label": "first", "slot": "0", "offset": 0, "type": "t_tb"},
                {"label": "second", "slot": "2", "offset": 0, "type": "t_tb"},
            ],
        }
        return {"storage": [{"label": "root", "slot": "0", "offset": 0, "type": "t_root"}], "types": types}

    errs = errors(two("t_uint104"), two("t_uint128"))
    assert has(errs, "root.first.amount", "undocumented widen"), errs
    assert has(errs, "root.second.amount", "undocumented widen"), errs


# ── one declaration on both sides: a struct with one type id in both layouts. It cannot differ, so it is not
#    compared, and what it declares is of an earlier step, so it is not judged here. ─────────────────────────────


def test_one_declaration_on_both_sides_is_not_compared_and_its_tags_are_not_judged():
    # a version that inherits an unchanged base holds the base's struct on both sides, tags and all
    layout = flat(tb=_tb_padding_append())
    assert mod.successor_errors(layout, layout, DOC) == []
    assert mod.successor_errors(layout, layout, None, ADDED) == []
    assert mod.successor_errors(layout, layout, None, None, {"TokenBalance": {"amount": "balance"}}) == []
    both = keyed("direct", "t_uint256")
    assert mod.successor_errors(both, both, None, None, None, REKEYED) == []
    # the same tags on a successor's own struct that changed nothing are reported, each one
    assert has(errors(layout, layout, DOC), "amount", "stale")
    assert has(errors(layout, layout, None, ADDED), "extra", "not added")


def test_tags_of_one_declaration_are_used_where_it_replaces_another():
    # `second` holds TokenBalance on both sides. `first` held another struct, which TokenBalance replaces with its
    # amount widened: its tag documents that, and is not judged where the struct stands on both sides
    def layout(first):
        types = dict(BASE_TYPES)
        types["t_old"] = {**token_balance("t_uint104"), "label": "struct OldBalance"}
        types["t_tb"] = token_balance("t_uint128")
        types["t_root"] = {
            "encoding": "inplace",
            "label": "struct Root",
            "numberOfBytes": "128",
            "members": [
                {"label": "first", "slot": "0", "offset": 0, "type": first},
                {"label": "second", "slot": "2", "offset": 0, "type": "t_tb"},
            ],
        }
        return {"storage": [{"label": "root", "slot": "0", "offset": 0, "type": "t_root"}], "types": types}

    a, b = layout("t_old"), layout("t_tb")
    b["types"]["t_root_successor"] = b["types"].pop("t_root")  # the successor's own Root, holding the shared struct
    b["storage"][0]["type"] = "t_root_successor"
    assert mod.successor_errors(a, b, DOC) == []
    errs = mod.successor_errors(a, b)
    assert has(errs, "root.first.amount", "undocumented widen"), errs
    assert len(errs) == 1, errs
    # compared with another declaration at `first`, the struct is judged: a tag of its that documents nothing there
    # is reported
    errs = mod.successor_errors(a, b, DOC, {"TokenBalance": {"ghost"}})
    assert has(errs, "TokenBalance.ghost", "not added"), errs
    assert len(errs) == 1, errs


def test_declarations_of_a_struct_only_the_predecessor_has_are_ignored():
    # a version keeps the tags of what it changed from the version before it. They are not its successor's
    a = flat("t_uint104")
    a["types"]["t_tb"]["label"] = "struct OldBalance"
    old = "OldBalance"
    assert errors(a, flat("t_uint104"), {old: {"amount": "uint96"}}) == []
    assert errors(a, flat("t_uint104"), None, {old: {"extra"}}) == []
    assert errors(a, flat("t_uint104"), None, None, {old: {"unusedInV3": "updatedAt"}}) == []
    assert errors(a, flat("t_uint104"), None, None, None, {old: {"integrals": "uint8"}}) == []


# ── a mapping key: a built-in unsigned integer key widened in place AND documented is accepted; every other key
#    change, documented or not, is rejected. An entry's slot is the hash of its key followed by the mapping's own
#    slot, and the key goes in as 32 bytes, left-padded for an unsigned integer: the same number is the same 32
#    bytes under a wider unsigned type. ────────────────────────────────────────────────────────────────────────


def test_documented_key_widen_is_a_successor():
    assert errors(keyed("direct"), keyed("direct", "t_uint256"), rekeyed=REKEYED) == []


def test_documented_key_widen_through_mapping_of_mappings():
    # the inner key, under an address-keyed mapping: the declaration on the field reaches it
    assert errors(keyed("mapmap"), keyed("mapmap", "t_uint256"), rekeyed=REKEYED) == []


def test_documented_key_widen_through_a_static_array():
    assert errors(keyed("staticarray"), keyed("staticarray", "t_uint256"), rekeyed=REKEYED) == []


def test_undocumented_key_widen_is_rejected():
    assert has(errors(keyed("direct"), keyed("direct", "t_uint256")), "field", "undocumented key widen")
    assert has(errors(keyed("mapmap"), keyed("mapmap", "t_uint256"), rekeyed={}), "field", "undocumented key widen")


def test_wrong_declared_old_key_type_is_rejected():
    # declared uint64 but the predecessor's key is really uint8, and the contradiction is reported once
    errs = errors(keyed("direct"), keyed("direct", "t_uint256"), rekeyed={"Root": {"field": "uint64"}})
    assert has(errs, "field", "predecessor's key is uint8")
    assert len(errs) == 1, errs


def test_key_declaration_with_no_key_changed_is_rejected():
    assert has(errors(keyed("mapmap"), keyed("mapmap"), rekeyed=REKEYED), "field", "none of its mapping keys changed")


def test_key_declaration_naming_unknown_field_is_rejected():
    errs = errors(keyed("direct"), keyed("direct", "t_uint256"), rekeyed={"Root": {"typo": "uint8"}})
    assert has(errs, "typo", "was not compared")


def test_key_declaration_on_a_field_with_no_mapping_is_rejected():
    # TokenBalance.amount is an integer: it has no key to widen
    errs = errors(V2, V2, rekeyed={"TokenBalance": {"amount": "uint8"}})
    assert has(errs, "amount", "none of its mapping keys changed")


def test_narrowed_key_is_rejected_even_when_documented():
    errs = errors(keyed("direct", "t_uint256"), keyed("direct"), rekeyed={"Root": {"field": "uint256"}})
    assert has(errs, "field", "mapping key changed")
    assert len(errs) == 1, errs  # the refused change is reported once, not also as a declaration that met no change


def test_signed_key_widen_is_rejected_even_when_documented():
    errs = errors(keyed("direct", "t_int128"), keyed("direct", "t_int256"), rekeyed={"Root": {"field": "int128"}})
    assert has(errs, "field", "mapping key changed")
    assert len(errs) == 1, errs


def test_key_changed_to_another_kind_is_rejected_even_when_documented():
    errs = errors(keyed("direct"), keyed("direct", "t_bytes32"), rekeyed=REKEYED)
    assert has(errs, "field", "mapping key changed")
    assert len(errs) == 1, errs


def test_key_of_a_user_defined_type_named_like_an_integer_is_rejected_even_when_documented():
    # `type uint7 is bytes1;` compiles, and its label reads `uint7`. A bytes1 is padded on the other side when
    # hashed, so its entries are not where a uint256 key of the same number looks. Told apart by the type id.
    fake_id, fake = _user_defined("uint7", "1", 5)
    a = keyed("direct")
    a["types"][fake_id] = fake
    a["types"]["t_keyed"]["key"] = fake_id
    errs = errors(a, keyed("direct", "t_uint256"), rekeyed={"Root": {"field": "uint7"}})
    assert has(errs, "field", "mapping key changed"), errs

    # and as the type widened to: `type uint512 is bytes1;`
    wide_id, wide = _user_defined("uint512", "1", 7)
    b = keyed("direct")
    b["types"][wide_id] = wide
    b["types"]["t_keyed"]["key"] = wide_id
    errs = errors(keyed("direct"), b, rekeyed=REKEYED)
    assert has(errs, "field", "mapping key changed"), errs


def test_key_changing_sign_is_rejected_even_when_documented():
    errs = errors(keyed("direct"), keyed("direct", "t_int256"), rekeyed=REKEYED)
    assert has(errs, "field", "mapping key changed"), errs
    errs = errors(keyed("direct", "t_int128"), keyed("direct", "t_uint256"), rekeyed={"Root": {"field": "int128"}})
    assert has(errs, "field", "mapping key changed"), errs


def test_key_declaration_names_the_field_as_the_successor_does():
    # the field is renamed in the same step: the declaration sits on the successor's struct and uses its name
    a, b = root_of([("field", "t_uint8")]), root_of([("newField", "t_uint256")])
    renamed = {"Root": {"newField": "field"}}
    assert errors(a, b, renamed=renamed, rekeyed={"Root": {"newField": "uint8"}}) == []
    errs = errors(a, b, renamed=renamed, rekeyed={"Root": {"field": "uint8"}})
    assert has(errs, "undocumented key widen"), errs
    assert has(errs, "Root.field", "was not compared"), errs


def test_key_declaration_on_a_freed_name_is_the_successors_field_of_that_name():
    # `foo` becomes `fooOld` with its key widened, and `bar` takes the name `foo` with its key as it was: a
    # declaration for `foo` is for the field the successor calls `foo`, whose key did not change
    a = root_of([("foo", "t_uint8"), ("bar", "t_uint16")])
    b = root_of([("fooOld", "t_uint256"), ("foo", "t_uint16")])
    renamed = {"Root": {"fooOld": "foo", "foo": "bar"}}
    assert errors(a, b, renamed=renamed, rekeyed={"Root": {"fooOld": "uint8"}}) == []
    errs = errors(a, b, renamed=renamed, rekeyed={"Root": {"foo": "uint8"}})
    assert has(errs, "undocumented key widen"), errs
    assert has(errs, "foo", "none of its mapping keys changed"), errs


def test_key_declaration_on_an_added_field_is_rejected():
    # the field is new in the successor, so it has no key that was widened - and the documented add does not
    # stand in for the key declaration having been compared
    a, b = root_of([("field", "t_uint8")]), root_of([("field", "t_uint8"), ("extra", "t_uint256")])
    errs = errors(a, b, added={"Root": {"extra"}}, rekeyed={"Root": {"extra": "uint8"}})
    assert has(errs, "Root.extra", "was not compared"), errs
    assert errors(a, b, added={"Root": {"extra"}}) == []


def test_each_field_takes_its_own_key_declaration():
    a = root_of([("one", "t_uint8"), ("two", "t_uint16"), ("three", "t_uint8")])
    b = root_of([("one", "t_uint256"), ("two", "t_uint64"), ("three", "t_uint8")])
    assert errors(a, b, rekeyed={"Root": {"one": "uint8", "two": "uint16"}}) == []
    # one field's declaration does not document another's
    errs = errors(a, b, rekeyed={"Root": {"one": "uint8"}})
    assert has(errs, "two", "undocumented key widen"), errs
    assert len(errs) == 1, errs


def test_one_declaration_covers_two_keys_widened_from_the_same_type():
    a, b = root_of([("field", "t_uint8", "t_uint8")]), root_of([("field", "t_uint256", "t_uint64")])
    assert errors(a, b, rekeyed=REKEYED) == []


def test_two_keys_widened_from_different_types_are_rejected():
    # a field takes one declaration, so one old type: the key widened from the other type is refused
    a, b = root_of([("field", "t_uint8", "t_uint16")]), root_of([("field", "t_uint256", "t_uint256")])
    errs = errors(a, b, rekeyed=REKEYED)
    assert has(errs, "field", "predecessor's key is uint16"), errs
    assert len(errs) == 1, errs


def test_documented_key_widen_through_a_dynamic_array():
    def in_dynamic_array(key):
        layout = keyed("direct", key)
        layout["types"]["t_arr"] = {
            "encoding": "dynamic_array",
            "label": "mapping(...)[]",
            "numberOfBytes": "32",
            "base": "t_keyed",
        }
        layout["types"]["t_root"]["members"][0]["type"] = "t_arr"
        return layout

    assert errors(in_dynamic_array("t_uint8"), in_dynamic_array("t_uint256"), rekeyed=REKEYED) == []
    assert has(errors(in_dynamic_array("t_uint8"), in_dynamic_array("t_uint256")), "field", "undocumented key widen")


def test_documented_key_widen_does_not_document_the_value():
    # the value's amount is widened in the same step: each change needs its own declaration
    a, b = keyed("direct", amount="t_uint104"), keyed("direct", "t_uint256", amount="t_uint128")
    assert has(errors(a, b, rekeyed=REKEYED), "amount", "undocumented widen")
    assert errors(a, b, retyped=DOC, rekeyed=REKEYED) == []


def test_key_declaration_does_not_reach_into_a_struct():
    # the widened key is a member of Inner, which the field's mapping holds: Inner carries its own declaration
    a, b = keyed("instruct"), keyed("instruct", "t_uint256")
    errs = errors(a, b, rekeyed=REKEYED)
    assert has(errs, "byKey", "undocumented key widen")
    assert has(errs, "field", "none of its mapping keys changed")
    assert errors(a, b, rekeyed={"Inner": {"byKey": "uint8"}}) == []


def test_static_array_resized_is_rejected():
    a = contained("staticarray")
    b = contained("staticarray")
    b["types"]["t_sarr"] = {"encoding": "inplace", "label": "TokenBalance[4]", "numberOfBytes": "256", "base": "t_tb"}
    assert has(errors(a, b), "array resized")


# ── documented renames: `@custom:oz-renamed-from` cannot reach a namespaced struct member (solc #12295, the
#    same limitation that forces `@custom:bao-retyped-from` for widens), so a rename inside a namespaced struct is
#    documented struct-level with `@custom:bao-renamed-from <newField> <oldField>`. A pure rename (same
#    slot/offset/type, only the name differs) is a byte-compatible successor; an undocumented one is rejected. ──


def _tb_renamed(new="amountRenamed"):
    """TokenBalance with `amount` renamed to `new` — same slot/offset/type, a pure rename."""
    tb = token_balance()
    tb["members"] = [dict(m) for m in tb["members"]]
    tb["members"][1]["label"] = new
    return tb


RENAMED = {"TokenBalance": {"amountRenamed": "amount"}}  # {newName: oldName}


def test_documented_rename_is_a_successor():
    assert errors(V2, flat(tb=_tb_renamed()), renamed=RENAMED) == []


def test_undocumented_rename_is_rejected():
    # without the annotation, a rename reads as the old field removed (and a new one added)
    assert has(errors(V2, flat(tb=_tb_renamed())), "amount", "removed")


def test_stale_rename_declaration_is_rejected():
    # names a successor field that was not actually renamed from a predecessor field
    assert has(errors(V2, V2, renamed={"TokenBalance": {"ghost": "amount"}}), "ghost", "not renamed")


def test_documented_rename_that_also_moves_is_rejected():
    # a rename does not excuse a slot move — the field's storage must not relocate
    tb = _tb_renamed()
    tb["members"][1]["slot"] = "1"
    tb["members"][1]["offset"] = 0
    tb["members"][2]["slot"] = "2"
    tb["numberOfBytes"] = "96"
    assert has(errors(V2, flat(tb=tb), renamed=RENAMED), "amount", "moved")


def test_documented_rename_through_mapping_is_a_successor():
    a = contained("mapping")
    b = contained("mapping")
    b["types"]["t_tb"] = _tb_renamed()
    assert errors(a, b, renamed=RENAMED) == []


# ── documented name REUSE: an upgrade may free a name and immediately reuse it for a DIFFERENT field in the
#    same struct. The reward structs do exactly this — the accumulator frees `userRewardSnapshot`
#    (-> userRewardSnapshotNOTUSED) then reuses it (userRewardSnapshotV2 -> userRewardSnapshot); the distributor
#    frees `rewardData` (-> rewardDataUNUSED) then reuses it for a new widened field. Each field keeps its slot,
#    so it is byte-compatible — but only if the matcher follows the rename declarations rather than pairing the
#    reused name to itself (`foo`(predecessor) and `foo`(successor) are different fields here). ──


def _two_member_struct(first, second, second_type="t_uint128", second_slot="0", second_offset=16, nbytes="32"):
    types = dict(BASE_TYPES)
    types["t_s"] = {
        "encoding": "inplace",
        "label": "struct S",
        "numberOfBytes": nbytes,
        "members": [
            {"label": first, "slot": "0", "offset": 0, "type": "t_uint128"},
            {"label": second, "slot": second_slot, "offset": second_offset, "type": second_type},
        ],
    }
    return {"storage": [{"label": "s", "slot": "0", "offset": 0, "type": "t_s"}], "types": types}


def test_rename_reusing_a_freed_name_for_another_renamed_field_is_a_successor():
    # foo -> fooOld frees `foo`; bar -> foo reuses it. Both keep their packed slot-0 positions (accumulator shape).
    pred = _two_member_struct("foo", "bar")
    succ = _two_member_struct("fooOld", "foo")
    assert errors(pred, succ, renamed={"S": {"fooOld": "foo", "foo": "bar"}}) == []


def test_rename_reusing_a_freed_name_for_an_added_field_is_a_successor():
    # foo -> fooOld frees `foo`; a NEW `foo` in a fresh slot reuses it — a documented append to the top-level
    # namespace struct (distributor shape). The reused name must not be skipped as "already present" merely
    # because a field of that name existed in the predecessor; the @custom:bao-added must be credited.
    types_pred = dict(BASE_TYPES)
    types_pred["t_s"] = {
        "encoding": "inplace",
        "label": "struct S",
        "numberOfBytes": "32",
        "members": [{"label": "foo", "slot": "0", "offset": 0, "type": "t_uint128"}],
    }
    pred = {"storage": [{"label": "s", "slot": "0", "offset": 0, "type": "t_s"}], "types": types_pred}
    succ = _two_member_struct("fooOld", "foo", second_type="t_uint256", second_slot="1", second_offset=0, nbytes="64")
    assert errors(pred, succ, added={"S": {"foo"}}, renamed={"S": {"fooOld": "foo"}}) == []


# ── a struct renamed in the successor: the tags are collected from the successor's structs, so a struct's
#    tags are the ones written on it under its successor name. A successor may split one struct into two, as
#    StabilityPool_v3 does with TokenBalance: each position then takes the tags of the struct it holds now. ──


def _timestamped_balance(amount="t_uint128"):
    """TokenBalance's layout under the successor name TimestampedBalance."""
    tb = token_balance(amount)
    tb["label"] = "struct TimestampedBalance"
    return tb


def _two_mappings(history_tb):
    """A root struct holding a mapping of TokenBalance and a mapping whose value is `history_tb`."""
    types = dict(BASE_TYPES)
    types["t_tb"] = token_balance()
    types["t_history"] = history_tb
    types["t_map"] = {
        "encoding": "mapping",
        "label": "mapping(address => TokenBalance)",
        "numberOfBytes": "32",
        "key": "t_address",
        "value": "t_tb",
    }
    types["t_history_map"] = {
        "encoding": "mapping",
        "label": "mapping(uint256 => " + history_tb["label"][len("struct ") :] + ")",
        "numberOfBytes": "32",
        "key": "t_uint256",
        "value": "t_history",
    }
    types["t_root"] = {
        "encoding": "inplace",
        "label": "struct Root",
        "numberOfBytes": "64",
        "members": [
            {"label": "balances", "slot": "0", "offset": 0, "type": "t_map"},
            {"label": "history", "slot": "1", "offset": 0, "type": "t_history_map"},
        ],
    }
    return {"storage": [{"label": "root", "slot": "0", "offset": 0, "type": "t_root"}], "types": types}


def test_struct_renamed_in_the_successor_takes_its_own_tags():
    a = contained("mapping")
    b = contained("mapping")
    b["types"]["t_tb"] = _timestamped_balance()
    assert errors(a, b, {"TimestampedBalance": {"amount": "uint104"}}) == []


def test_struct_renamed_in_the_successor_ignores_the_tags_of_its_old_name():
    a = contained("mapping")
    b = contained("mapping")
    b["types"]["t_tb"] = _timestamped_balance()
    assert has(errors(a, b, DOC), "amount", "undocumented widen")


def test_struct_split_in_two_takes_each_structs_tags():
    # TokenBalance keeps its name, widens and retires updatedAt; the history's copy becomes TimestampedBalance
    # and widens. Each struct carries its own tags.
    retired = token_balance("t_uint128")
    retired["members"][2]["label"] = "unusedInV3"
    a = _two_mappings(token_balance())
    b = _two_mappings(_timestamped_balance())
    b["types"]["t_tb"] = retired
    retyped = {"TokenBalance": {"amount": "uint104"}, "TimestampedBalance": {"amount": "uint104"}}
    renamed = {"TokenBalance": {"unusedInV3": "updatedAt"}}
    assert errors(a, b, retyped, None, renamed) == []


def test_declarations_are_looked_up_by_the_structs_canonical_name():
    # solc labels a struct by where it is declared: `struct Lib.TokenBalance`. Its declarations are its own: a
    # struct of the same bare name declared elsewhere does not lend it its tags.
    a = contained("mapping")
    b = contained("mapping", "t_uint128")
    b["types"]["t_tb"]["label"] = "struct Lib.TokenBalance"
    assert errors(a, b, {"Lib.TokenBalance": {"amount": "uint104"}}) == []
    assert has(errors(a, b, DOC), "amount", "undocumented widen")
    assert has(errors(a, b, {"Other.TokenBalance": {"amount": "uint104"}}), "amount", "undocumented widen")


# ── rejected: a bad change buried deep inside a container (rejection must propagate) ────────────────────────


def test_deep_narrow_inside_mapping_is_rejected():
    assert has(errors(contained("mapping"), contained("mapping", "t_uint64")), "amount", "narrowed")


def test_undocumented_deep_append_inside_dynamic_array_is_rejected():
    a = contained("dynarray")
    b = contained("dynarray")
    b["types"]["t_tb"] = _tb_padding_append()
    assert has(errors(a, b), "extra", "undocumented")


def test_documented_size_preserving_append_inside_dynamic_array_is_accepted():
    # a size-preserving append packs into each element's padding without changing the stride — safe.
    a = contained("dynarray")
    b = contained("dynarray")
    b["types"]["t_tb"] = _tb_padding_append()
    assert errors(a, b, None, ADDED) == []


# ── top-level slots: before recursing into the namespace struct, successor_errors compares the layout's
#    top-level storage entries for removal / move / addition. The injection probe always emits exactly one
#    top-level var, so these cannot occur through the pipeline — but the rule guards them, so pin the branches
#    directly. They are the top-level analogues of the struct-member remove / move / add tests above. ──


def _top(entries):
    return {"storage": entries, "types": dict(BASE_TYPES)}


_ONE_SLOT = [{"label": "pool", "slot": "0", "offset": 0, "type": "t_uint128"}]
_TWO_SLOTS = _ONE_SLOT + [{"label": "extra", "slot": "1", "offset": 0, "type": "t_uint128"}]
_MOVED_SLOT = [{"label": "pool", "slot": "1", "offset": 0, "type": "t_uint128"}]


def test_top_level_slot_removed_is_rejected():
    assert has(errors(_top(_TWO_SLOTS), _top(_ONE_SLOT)), "extra", "top-level slot removed")


def test_top_level_slot_moved_is_rejected():
    assert has(errors(_top(_ONE_SLOT), _top(_MOVED_SLOT)), "pool", "top-level slot moved")


def test_top_level_slot_added_is_rejected():
    assert has(errors(_top(_ONE_SLOT), _top(_TWO_SLOTS)), "extra", "top-level slot added")


# ── a declaration naming a struct absent from the compared layout is ignored. The declarations of every struct in
#    the build are passed to each comparison; when ONE namespace's layout is compared, a declaration naming a
#    struct not present here must be skipped, or another struct's valid declaration would be reported as naming
#    a field that was not compared. Without that skip, the OtherStruct declarations below would each be reported. ──


def test_declaration_for_a_struct_absent_from_this_layout_is_ignored():
    assert errors(V2, V2, {"OtherStruct": {"amount": "uint104"}}) == []
    assert errors(V2, V2, None, {"OtherStruct": {"extra"}}) == []
    assert errors(V2, V2, None, None, {"OtherStruct": {"newName": "oldName"}}) == []


# ── namespace slot-getter helpers: slot normalization + struct-id→namespace extraction (pure). The full
#    auto-detection, which shells out to `cast index-erc7201`, is covered by the .sol-fixture integration test. ──


def test_norm_slot_lowercases_and_left_pads_to_32_bytes():
    padded = "0x" + "abc".rjust(64, "0")
    assert mod._norm_slot("0xABC") == padded
    assert mod._norm_slot("abc") == padded  # a bare (no-0x) value normalizes the same
    full = "0x077a0ba7b5c5bbac7ec1ded2b9233ddb1dee1ab5c084fb024016a2c615667600"
    assert mod._norm_slot(full) == full


def test_namespace_by_struct_id_maps_only_storage_location_structs():
    build_info = {
        "output": {
            "sources": {
                "X.sol": {
                    "ast": {
                        "nodes": [
                            {
                                "nodeType": "ContractDefinition",
                                "name": "C",
                                "nodes": [
                                    {
                                        "nodeType": "StructDefinition",
                                        "id": 1,
                                        "name": "S",
                                        "documentation": {"text": "@custom:storage-location erc7201:my.ns"},
                                    },
                                    {
                                        "nodeType": "StructDefinition",
                                        "id": 2,
                                        "name": "Plain",
                                        "documentation": {"text": "an ordinary struct"},
                                    },
                                ],
                            },
                        ]
                    }
                }
            }
        }
    }
    assert mod._namespace_by_struct_id(build_info) == {1: "my.ns"}


def _struct_node(node_id, name, canonical_name, text, holds=()):
    """A struct as the syntax tree gives it, with one member for each type in `holds`."""
    members = [{"nodeType": "VariableDeclaration", "name": f"m{at}", "typeName": held} for at, held in enumerate(holds)]
    return {
        "nodeType": "StructDefinition",
        "id": node_id,
        "name": name,
        "canonicalName": canonical_name,
        "documentation": {"text": text},
        "members": members,
    }


def _the_struct(struct_id):
    """A member's type that names a struct, an enum or any other declaration by its id."""
    return {"nodeType": "UserDefinedTypeName", "referencedDeclaration": struct_id}


def _mapping_to(value):
    key = {"nodeType": "ElementaryTypeName", "name": "address"}
    return {"nodeType": "Mapping", "keyType": key, "valueType": value}


def _array_of(base):
    return {"nodeType": "ArrayTypeName", "baseType": base}


def _build_info_with_struct_doc(text):
    """A build-info of one contract `C` holding a struct `S` with this NatSpec, and a struct with no tag."""
    contract = {
        "nodeType": "ContractDefinition",
        "id": 7,
        "name": "C",
        "linearizedBaseContracts": [7],
        "nodes": [_struct_node(1, "S", "C.S", text), _struct_node(2, "Plain", "C.Plain", "an ordinary struct")],
    }
    return {"output": {"sources": {"X.sol": {"ast": {"nodes": [contract]}}}}}, contract


def _link_declarations(build_info, struct_id=1):
    """What a link is checked with, where its successor's namespace struct is this one: the four maps of
    declarations, and the link's errors."""
    return mod._link_declarations(struct_id, mod._structs_by_id(build_info))


def test_rekeyed_declarations_are_read_from_the_struct():
    build_info, _contract = _build_info_with_struct_doc(
        "@custom:storage-location erc7201:my.ns\n@custom:bao-rekeyed-from integrals uint8"
    )
    assert _link_declarations(build_info) == (({}, {}, {}, {"C.S": {"integrals": "uint8"}}), [])


def _build_with_structs_everywhere():
    """A namespace struct `C.S` (id 1) that reaches a library's struct directly, a file-level struct through a
    mapping of mappings, and `C.Node` through an array. `C.Node` holds an array of itself and an enum. `C.Other` and
    `Lib.Unused` are reached by nothing."""
    plain = {"nodeType": "ElementaryTypeName", "name": "uint256"}
    file_level = _struct_node(2, "FileLevel", "FileLevel", "@custom:bao-retyped-from amount uint104", [plain])
    library = {
        "nodeType": "ContractDefinition",
        "id": 10,
        "name": "Lib",
        "contractKind": "library",
        "nodes": [
            _struct_node(
                11, "Inner", "Lib.Inner", "@custom:bao-added extra\n @custom:bao-renamed-from newName oldName"
            ),
            _struct_node(12, "Unused", "Lib.Unused", "@custom:bao-added never"),
            {"nodeType": "EnumDefinition", "id": 40, "name": "Mode", "canonicalName": "Lib.Mode"},
        ],
    }
    contract = {
        "nodeType": "ContractDefinition",
        "id": 20,
        "name": "C",
        "nodes": [
            _struct_node(
                1,
                "S",
                "C.S",
                "@custom:storage-location erc7201:my.ns\n @custom:bao-rekeyed-from integrals uint8",
                [_the_struct(11), _mapping_to(_mapping_to(_the_struct(2))), _array_of(_the_struct(3)), plain],
            ),
            _struct_node(3, "Node", "C.Node", "holds itself", [_array_of(_the_struct(3)), _the_struct(40)]),
            _struct_node(4, "Other", "C.Other", "@custom:bao-retyped-from amount uint96"),
        ],
    }
    return {
        "output": {
            "sources": {"A.sol": {"ast": {"nodes": [file_level, library]}}, "B.sol": {"ast": {"nodes": [contract]}}}
        }
    }


def test_structs_reached_from_a_struct():
    # through a member, a mapping's value and an array's element, wherever each struct is declared; a struct that
    # holds itself ends the walk; an enum is not a struct; what nothing reaches is left out
    structs = mod._structs_by_id(_build_with_structs_everywhere())
    assert set(structs) == {1, 2, 3, 4, 11, 12}
    reached = mod._reached_structs(1, structs)
    assert {node["canonicalName"]: path for path, node in reached.values()} == {
        "C.S": "B.sol",
        "Lib.Inner": "A.sol",
        "FileLevel": "A.sol",
        "C.Node": "B.sol",
    }
    assert set(mod._reached_structs(3, structs)) == {3}


def test_link_declarations_are_those_of_the_structs_the_successor_reaches():
    # each under its canonical name, which is how solc labels the struct in a layout. `C.Other` and `Lib.Unused`
    # are not reached, so their tags are not this link's
    build_info = _build_with_structs_everywhere()
    assert _link_declarations(build_info) == (
        (
            {"FileLevel": {"amount": "uint104"}},
            {"Lib.Inner": {"extra"}},
            {"Lib.Inner": {"newName": "oldName"}},
            {"C.S": {"integrals": "uint8"}},
        ),
        [],
    )
    assert _link_declarations(build_info, 4) == (({"C.Other": {"amount": "uint96"}}, {}, {}, {}), [])


def _two_structs_named_c_s(first_text, second_text):
    """A build with a contract `C` holding a struct `S` (ids 2 and 6) in each of two files, and a struct `P.Root`
    (id 9) that holds both."""

    def source(node_id, text):
        contract = {"nodeType": "ContractDefinition", "id": node_id, "name": "C"}
        contract["nodes"] = [_struct_node(node_id + 1, "S", "C.S", text)]
        return {"ast": {"nodes": [contract]}}

    holder = {"nodeType": "ContractDefinition", "id": 8, "name": "P"}
    holder["nodes"] = [_struct_node(9, "Root", "P.Root", "holds both", [_the_struct(2), _mapping_to(_the_struct(6))])]
    sources = {
        "One.sol": source(1, first_text),
        "Two.sol": source(5, second_text),
        "P.sol": {"ast": {"nodes": [holder]}},
    }
    return {"output": {"sources": sources}}


def test_struct_of_the_same_canonical_name_elsewhere_in_the_build_does_not_matter():
    # a contract `C` with a struct `S` in each of two files: a link's own is the one its successor reaches
    build_info = _two_structs_named_c_s(
        "@custom:bao-retyped-from amount uint104", "@custom:bao-retyped-from amount uint96"
    )
    assert _link_declarations(build_info, 2) == (({"C.S": {"amount": "uint104"}}, {}, {}, {}), [])
    assert _link_declarations(build_info, 6) == (({"C.S": {"amount": "uint96"}}, {}, {}, {}), [])


def test_two_reached_structs_of_one_canonical_name_with_different_tags_fail_the_link():
    # the comparison looks a struct's declarations up by its canonical name, so one successor cannot hold two
    # structs of one name that declare different changes: one tagged and the other not, or tagged differently
    for first, second in (
        ("@custom:bao-retyped-from amount uint104", "an ordinary struct"),
        ("@custom:bao-retyped-from amount uint104", "@custom:bao-retyped-from amount uint96"),
    ):
        _maps, errs = _link_declarations(_two_structs_named_c_s(first, second), 9)
        assert len(errs) == 1, errs
        assert "C.S" in errs[0] and "One.sol" in errs[0] and "Two.sol" in errs[0], errs


def test_two_reached_structs_of_one_canonical_name_with_the_same_tags_are_read_once():
    text = "@custom:bao-retyped-from amount uint104"
    assert _link_declarations(_two_structs_named_c_s(text, text), 9) == (
        ({"C.S": {"amount": "uint104"}}, {}, {}, {}),
        [],
    )
    assert _link_declarations(_two_structs_named_c_s("an ordinary struct", "another"), 9) == (({}, {}, {}, {}), [])


def test_rekeyed_tag_is_recognized():
    build_info, _contract = _build_info_with_struct_doc("@custom:bao-rekeyed-from integrals uint8")
    assert mod.unrecognized_bao_tags(build_info) == []


# Uses of a tag that are not a whole declaration, which is the tag and its arguments alone to the end of their line.
# Here: an argument missing, one too many, text run on after the last, another separator, another kind of type.
_NOT_A_WHOLE_DECLARATION = (
    "@custom:bao-retyped-from amount",
    "@custom:bao-retyped-from amount uint104x",
    "@custom:bao-retyped-from amount uint104 (was narrower)",
    "@custom:bao-retyped-from amount bytes4",
    "@custom:bao-retyped-from amount: uint104",
    "@custom:bao-added",
    "@custom:bao-added extra other",
    "@custom:bao-added extra, other",
    "@custom:bao-renamed-from newName",
    "@custom:bao-renamed-from newName oldName was",
    "@custom:bao-renamed-from newName <- oldName",
    "@custom:bao-rekeyed-from integrals",
    "@custom:bao-rekeyed-from integrals int8",
    "@custom:bao-rekeyed-from integrals uint",
    "@custom:bao-rekeyed-from integrals uint8_was_the_exponent",
    "@custom:bao-rekeyed-from integrals uint8x",
    "@custom:bao-rekeyed-from integrals uint8[]",
    "@custom:bao-rekeyed-from integrals uint8, uint16",
    "@custom:bao-rekeyed-from integrals uint8 (the exponent)",
    "@custom:bao-rekeyed-from integrals: uint8",
    "@custom:bao-rekeyed-from s.integrals uint8",
)


@pytest.mark.parametrize("text", _NOT_A_WHOLE_DECLARATION)
def test_tag_that_is_not_a_whole_declaration_is_not_read_as_one(text):
    build_info, _contract = _build_info_with_struct_doc(text)
    assert _link_declarations(build_info) == (({}, {}, {}, {}), [])


@pytest.mark.parametrize("text", _NOT_A_WHOLE_DECLARATION)
def test_tag_that_is_not_a_whole_declaration_is_reported(text):
    # read as nothing, it would leave the change "undocumented" with the line in plain sight, or pass unseen
    # where nothing changed
    build_info, _contract = _build_info_with_struct_doc("@custom:storage-location erc7201:my.ns\n" + text)
    assert [where for where, _message in mod.malformed_bao_tags(build_info)] == ["C.S"]


def _build_info_with_contract_doc(text):
    """A build-info of one contract `C` with this NatSpec."""
    contract = {"nodeType": "ContractDefinition", "id": 7, "name": "C", "nodes": [], "documentation": {"text": text}}
    return {"output": {"sources": {"X.sol": {"ast": {"nodes": [contract]}}}}}


@pytest.mark.parametrize(
    "text",
    [
        "@custom:bao-upgrades-from src/Pool_v2.sol Pool_v2",  # no colon: read as no link, the contract unchecked
        "@custom:bao-upgrades-from Pool_v2",
        "@custom:bao-upgrades-from src/Pool_v2.sol:Pool_v2 (the deployed one)",
        "@custom:bao-upgrades-from",
    ],
)
def test_upgrade_reference_that_is_not_whole_is_reported_and_is_no_link(text):
    build_info = _build_info_with_contract_doc(text)
    assert mod._pairs(build_info) == []
    assert [where for where, _message in mod.malformed_bao_tags(build_info)] == ["C"]


def test_two_upgrade_references_on_one_contract_are_reported():
    # only the first would be a link
    build_info = _build_info_with_contract_doc(
        "@custom:bao-upgrades-from src/A.sol:A\n @custom:bao-upgrades-from src/B.sol:B"
    )
    reports = mod.malformed_bao_tags(build_info)
    assert len(reports) == 1 and reports[0][0] == "C" and "more than once" in reports[0][1], reports


@pytest.mark.parametrize(
    "text,field",
    [
        ("@custom:bao-retyped-from amount uint96\n@custom:bao-retyped-from amount uint104", "amount"),
        ("@custom:bao-added extra\n@custom:bao-added extra", "extra"),
        ("@custom:bao-renamed-from newName oldName\n@custom:bao-renamed-from newName otherName", "newName"),
        ("@custom:bao-rekeyed-from integrals uint16\n@custom:bao-rekeyed-from integrals uint8", "integrals"),
    ],
)
def test_tag_used_twice_for_one_field_is_reported(text, field):
    # of two for one field only the last would count
    build_info, _contract = _build_info_with_struct_doc(text)
    reports = mod.malformed_bao_tags(build_info)
    assert len(reports) == 1, reports
    assert reports[0][0] == "C.S" and field in reports[0][1] and "more than once" in reports[0][1], reports


def test_whole_declarations_are_not_reported():
    # every tag in its whole form, as solc gives NatSpec: the lines after the first start with a space, and
    # trailing spaces are allowed. One per field. Each is read.
    struct_text = (
        "@custom:storage-location erc7201:my.ns\n @custom:bao-retyped-from amount uint104\n"
        " @custom:bao-added extra\n @custom:bao-added more  \n @custom:bao-renamed-from newName oldName\n"
        " @custom:bao-rekeyed-from integrals uint8\n @custom:bao-rekeyed-from other uint16  "
    )
    build_info, contract = _build_info_with_struct_doc(struct_text)
    contract["documentation"] = {"text": "The pool.\n @custom:bao-upgrades-from src/Pool_v2.sol:Pool_v2"}
    assert mod.malformed_bao_tags(build_info) == []
    assert _link_declarations(build_info) == (
        (
            {"C.S": {"amount": "uint104"}},
            {"C.S": {"extra", "more"}},
            {"C.S": {"newName": "oldName"}},
            {"C.S": {"integrals": "uint8", "other": "uint16"}},
        ),
        [],
    )
    assert mod._pairs(build_info) == [("X.sol", "C", "src/Pool_v2.sol", "Pool_v2")]


_STRUCT_TAGS = (
    "@custom:bao-retyped-from amount uint104",
    "@custom:bao-added extra",
    "@custom:bao-renamed-from newName oldName",
    "@custom:bao-rekeyed-from integrals uint8",
)


@pytest.mark.parametrize("tag_line", _STRUCT_TAGS)
def test_struct_tag_on_a_node_that_is_not_a_struct_is_reported(tag_line):
    # written on the contract, an event, a function or a constant, it is whole and documents nothing: the change it
    # was meant for is reported as undocumented with the line in plain sight, or nothing is said where nothing
    # changed
    documentation = {"text": "Something.\n " + tag_line}
    contract = {
        "nodeType": "ContractDefinition",
        "id": 7,
        "name": "C",
        "documentation": documentation,
        "nodes": [
            {"nodeType": "EventDefinition", "name": "Happened", "documentation": documentation},
            {"nodeType": "FunctionDefinition", "name": "run", "documentation": documentation},
            {"nodeType": "VariableDeclaration", "name": "SLOT", "documentation": documentation},
            _struct_node(1, "S", "C.S", tag_line),
        ],
    }
    file_level_function = {"nodeType": "FunctionDefinition", "name": "free", "documentation": documentation}
    build_info = {"output": {"sources": {"X.sol": {"ast": {"nodes": [contract, file_level_function]}}}}}
    reports = mod.malformed_bao_tags(build_info)
    assert [where for where, _message in reports] == ["C", "C.Happened", "C.run", "C.SLOT", "free"], reports
    tag = tag_line.split()[0][1:]
    assert all(tag in message and "only on a struct" in message for _where, message in reports), reports
    assert "ContractDefinition" in reports[0][1] and "EventDefinition" in reports[1][1], reports


def test_upgrade_reference_on_a_node_that_is_not_a_contract_is_reported_and_is_no_link():
    # written with the struct's other tags, it is whole and makes no link: the contract would go unchecked
    build_info, _contract = _build_info_with_struct_doc(
        "@custom:storage-location erc7201:my.ns\n @custom:bao-upgrades-from src/Pool_v2.sol:Pool_v2"
    )
    assert mod._pairs(build_info) == []
    reports = mod.malformed_bao_tags(build_info)
    assert len(reports) == 1, reports
    assert reports[0][0] == "C.S" and "bao-upgrades-from" in reports[0][1] and "only on a contract" in reports[0][1]
    assert "StructDefinition" in reports[0][1], reports


def _written(tmp_path, build_info, name="build.json"):
    """The folder, with this build-info written in it as forge writes one."""
    (tmp_path / name).write_text(json.dumps(build_info))
    return str(tmp_path)


def test_main_passes_a_build_whose_tags_are_whole_and_known(tmp_path):
    build_info, _contract = _build_info_with_struct_doc("@custom:bao-added extra")
    assert mod.main([_written(tmp_path, build_info)]) == 0


def test_main_fails_on_a_malformed_tag(tmp_path):
    build_info, _contract = _build_info_with_struct_doc("@custom:bao-added")
    assert mod.main([_written(tmp_path, build_info)]) == 1


def test_main_fails_on_an_unrecognized_tag(tmp_path):
    build_info, _contract = _build_info_with_struct_doc("@custom:bao-renamd-from x y")
    assert mod.main([_written(tmp_path, build_info)]) == 1


# ── every compiled build-info in the folder is read. forge writes one for each compiler version a build uses, and
#    one with no compiled output for each later `forge inspect`. A link in a compiled file left unread would not be
#    checked, and nothing would say so. ──────────────────────────────────────────────────────────────────────────


def _linked(node_id, name, predecessor=None, namespace=None):
    """A contract as the syntax tree gives it: with `@custom:bao-upgrades-from <predecessor>` when one is given,
    and a struct `S` of this namespace when one is given."""
    structs = [("S", f"@custom:storage-location erc7201:{namespace}")] if namespace else []
    contract = _contract(node_id, name, [], structs)
    if predecessor:
        contract["documentation"] = {"text": f"@custom:bao-upgrades-from {predecessor}"}
    return contract


def _sources(by_path):
    """A compiled build-info of these sources: {path: [top-level nodes]}, in that order."""
    return {"output": {"sources": {path: {"ast": {"nodes": nodes}} for path, nodes in by_path.items()}}}


def _folder(tmp_path, *build_infos):
    """The folder holding these build-infos as forge writes them, the last one written the newest."""
    for at, build_info in enumerate(build_infos):
        path = tmp_path / f"{at}.json"
        path.write_text(json.dumps(build_info))
        os.utime(path, (at + 1, at + 1))
    return str(tmp_path)


@pytest.fixture
def laid_out(monkeypatch):
    """The probe that lays the structs out, replaced by one that records what it was asked to lay out and lays
    every struct out empty, so that a link is judged here by the contracts and namespaces it was given."""
    asked = []

    def lay_out(jobs, root):
        asked.extend(jobs)
        return {index: {"storage": [], "types": {}} for index, *_job in jobs}

    monkeypatch.setattr(mod, "_inject_layouts", lay_out)
    return asked


def _main(capsys, *argv):
    """main's exit code, and what it printed as one line of single spaces."""
    code = mod.main(list(argv))
    return code, " ".join(capsys.readouterr().out.split())


def test_links_are_read_from_every_compiled_build_info(tmp_path, capsys):
    # one compiled build-info for each compiler version: a link in the older one is checked as well
    older = _sources({"src/A_v2.sol": [_linked(1, "A_v2", "src/A_v1.sol:A_v1")]})
    newer = _sources({"src/B_v2.sol": [_linked(1, "B_v2", "src/B_v1.sol:B_v1")]})
    code, out = _main(capsys, _folder(tmp_path, older, newer))
    assert code == 1
    assert "A_v2 <- A_v1" in out and "predecessor A_v1 (src/A_v1.sol) not in build" in out, out
    assert "B_v2 <- B_v1" in out and "predecessor B_v1 (src/B_v1.sol) not in build" in out, out


def test_a_contract_in_two_build_infos_is_checked_once(tmp_path, capsys):
    # a file with a pragma range, compiled in both compilations
    both = _sources({"src/A_v2.sol": [_linked(1, "A_v2", "src/A_v1.sol:A_v1")]})
    code, out = _main(capsys, _folder(tmp_path, both, both))
    assert code == 1
    assert out.count("A_v2 <- A_v1") == 1, out


def test_the_successor_is_the_contract_that_carries_the_reference(tmp_path, capsys, laid_out):
    # another contract of the successor's name comes first in the build and declares the predecessor's namespace
    build_info = _sources(
        {
            "src/other/Pool_v3.sol": [_linked(1, "Pool_v3", None, "fx.a")],
            "src/Pool_v2.sol": [_linked(2, "Pool_v2", None, "fx.a")],
            "src/Pool_v3.sol": [_linked(3, "Pool_v3", "src/Pool_v2.sol:Pool_v2")],
        }
    )
    code, out = _main(capsys, _folder(tmp_path, build_info))
    assert code == 1
    assert "namespace fx.a gone" in out, out
    assert laid_out == [], laid_out


def test_the_predecessor_is_the_contract_at_the_referenced_path(tmp_path, capsys, laid_out):
    # two contracts of the predecessor's name: the reference names the second by its path
    build_info = _sources(
        {
            "src/old/Pool_v2.sol": [_linked(1, "Pool_v2", None, "fx.b")],
            "src/Pool_v2.sol": [_linked(2, "Pool_v2", None, "fx.a")],
            "src/Pool_v3.sol": [_linked(3, "Pool_v3", "src/Pool_v2.sol:Pool_v2")],
        }
    )
    code, out = _main(capsys, _folder(tmp_path, build_info))
    assert code == 1
    assert "namespace fx.a gone" in out and "fx.b" not in out, out


def test_a_predecessor_in_another_build_info_is_found(tmp_path, capsys, laid_out):
    # a successor moved to another compiler version than its predecessor's
    older = _sources({"src/Pool_v2.sol": [_linked(1, "Pool_v2", None, "fx.a")]})
    newer = _sources({"src/Pool_v3.sol": [_linked(1, "Pool_v3", "src/Pool_v2.sol:Pool_v2")]})
    code, out = _main(capsys, _folder(tmp_path, older, newer))
    assert code == 1
    assert "namespace fx.a gone" in out and "not in build" not in out, out


def test_each_side_is_laid_out_from_its_own_build_info(tmp_path, capsys, laid_out):
    # syntax-tree ids are numbered for each compilation: the two sides' structs are found each in its own build-info
    older = _sources({"src/Pool_v2.sol": [_linked(1, "Pool_v2", None, "fx.a")]})
    newer = _sources(
        {
            "src/Lib.sol": [_linked(1, "Lib", None, "fx.unrelated")],
            "src/Pool_v3.sol": [_linked(2, "Pool_v3", "src/Pool_v2.sol:Pool_v2", "fx.a")],
        }
    )
    code, _out = _main(capsys, _folder(tmp_path, older, newer))
    assert code == 0
    assert [job[1:] for job in laid_out] == [("src/Pool_v2.sol", "Pool_v2", "S"), ("src/Pool_v3.sol", "Pool_v3", "S")]


def test_build_infos_without_compiled_output_are_passed_over(tmp_path, capsys):
    # forge writes one with no compiled output after `forge inspect`, after the compiled one
    compiled, _contract = _build_info_with_struct_doc("@custom:bao-added")
    code, out = _main(capsys, _folder(tmp_path, compiled, _NO_COMPILED_OUTPUT))
    assert code == 1
    assert "bao-added not of the form" in out, out


def test_no_compiled_build_info_stops_the_run(tmp_path):
    # nothing was read, which must not look like a build with nothing to check
    folder = _folder(tmp_path, _NO_COMPILED_OUTPUT, _NO_COMPILED_OUTPUT)
    for argv in ([folder], [folder, "--list"], [folder, "--list-initializable"]):
        with pytest.raises(SystemExit) as stop:
            mod.main(argv)
        assert stop.value.code == f"storage-successor: no build-info in {folder} holds compiled output", argv


def test_lists_and_reports_read_every_compiled_build_info(tmp_path, capsys):
    # the links, the contracts that inherit Initializable, and a malformed tag, each in the older of two files
    older = _sources(
        {
            "src/A_v2.sol": [_linked(1, "A_v2", "src/A_v1.sol:A_v1")],
            "src/Init.sol": [_OZ_INITIALIZABLE],
            "src/Bad.sol": [_struct_node(5, "Bad", "Bad", "@custom:bao-added")],
        }
    )
    newer = _sources({"src/B_v2.sol": [_linked(1, "B_v2", "src/B_v1.sol:B_v1")], "src/Init.sol": [_OZ_INITIALIZABLE]})
    folder = _folder(tmp_path, older, newer)
    assert _main(capsys, folder, "--list") == (0, "A_v2 A_v1 B_v2 B_v1")
    assert _main(capsys, folder, "--list-initializable") == (0, "src/Init.sol:Initializable")
    code, out = _main(capsys, folder)
    assert code == 1
    assert "Bad — 1 use(s) of @custom:bao-added" in out, out


def test_unrecognized_bao_tag_is_flagged_recognized_ones_ignored():
    build_info = {
        "output": {
            "sources": {
                "X.sol": {
                    "ast": {
                        "nodes": [
                            {
                                "nodeType": "ContractDefinition",
                                "name": "C",
                                "documentation": {"text": "@custom:bao-upgrades-from a:B"},  # recognized -> ignored
                                "nodes": [
                                    {
                                        "nodeType": "StructDefinition",
                                        "name": "S",
                                        "documentation": {"text": "@custom:bao-renamd-from x y"},
                                    },  # typo of bao-renamed-from -> flagged
                                ],
                            },
                        ]
                    }
                }
            }
        }
    }
    assert mod.unrecognized_bao_tags(build_info) == [("C.S", "bao-renamd-from")]


# ── which contracts inherit OpenZeppelin's Initializable. bin/validate asks this to decide what a production
#    implementation's constructor must do: one inheriting Initializable must disable them (one SSTORE, to the
#    Initializable slot), while one that does not has no initializer to disable and must write no storage at
#    all. The inheritance chain is the signal, not the bytecode, so a contract that DOES inherit Initializable
#    and omits `_disableInitializers()` cannot opt out of the check by producing no SSTORE. Identity comes from
#    the ERC-7201 namespace its storage struct declares, not the contract's name — the same namespace whose
#    hash validate greps for in the creation bytecode, so the two halves of that check cannot drift apart. ──


def _contract(node_id, name, bases, structs=()):
    return {
        "nodeType": "ContractDefinition",
        "id": node_id,
        "name": name,
        "linearizedBaseContracts": [node_id] + list(bases),
        "nodes": [
            {
                "nodeType": "StructDefinition",
                "id": node_id * 100 + i,
                "name": n,
                "canonicalName": f"{name}.{n}",
                "documentation": {"text": d},
                "members": [],
            }
            for i, (n, d) in enumerate(structs)
        ],
    }


_OZ_INITIALIZABLE = _contract(
    10,
    "Initializable",
    [],
    [("InitializableStorage", "@custom:storage-location erc7201:openzeppelin.storage.Initializable")],
)
_UUPS = _contract(20, "UUPSUpgradeable", [])  # OZ 5.x: no longer inherits Initializable


def _tree(*contracts):
    return {"output": {"sources": {"X.sol": {"ast": {"nodes": list(contracts)}}}}}


def test_contract_inheriting_initializable_indirectly_is_listed():
    # Impl -> Base -> Initializable: the namespace is two levels up, reached via the linearized chain.
    # Initializable is listed too — it declares the namespace, so it trivially has it.
    base = _contract(30, "Base", [10])
    impl = _contract(40, "Impl", [30, 10])
    listed = mod.initializable_contracts(_tree(_OZ_INITIALIZABLE, base, impl))
    assert listed == ["X.sol:Initializable", "X.sol:Base", "X.sol:Impl"]


def test_contract_without_initializable_is_not_listed():
    # the fixed-owner UUPS shape: owner set in the constructor, no initializer anywhere in the chain. Neither
    # the implementation nor either of its bases is listed, though Initializable is compiled alongside them.
    fixed = _contract(50, "FixedOwnable", [])
    impl = _contract(60, "Impl", [50, 20])
    listed = mod.initializable_contracts(_tree(_OZ_INITIALIZABLE, _UUPS, fixed, impl))
    assert listed == ["X.sol:Initializable"]


def test_another_namespace_does_not_count_as_initializable():
    # a contract with namespaced storage of its own must not be mistaken for an initializable one.
    minter = _contract(70, "Minter", [], [("MinterStorage", "@custom:storage-location erc7201:bao.storage.Minter")])
    assert mod.initializable_contracts(_tree(minter)) == []


# ── which contracts have root variables: the state variables solc places in sequential slots. bin/validate fails a
#    production implementation that has any. solc's storage layout lists them and never lists an ERC-7201 namespaced
#    field. forge leaves the layout out of the build-info when it would be empty, so a contract with no root variables
#    has no layout at all, which is why a build that never asked for layouts has to be an error. What the real forge
#    writes is covered by test_root_storage_with_forge.py. ──


def _compiled(layouts, requested=("abi", "storageLayout")):
    """A build-info in the shape forge writes: `layouts` maps '<source>:<Name>' to that contract's storage entries."""
    contracts = {}
    for contract, storage in layouts.items():
        source, name = contract.split(":")
        entry = {"abi": []}
        if storage:
            entry["storageLayout"] = {"storage": storage, "types": {}}
        contracts.setdefault(source, {})[name] = entry
    return {
        "input": {"settings": {"outputSelection": {"*": {"*": list(requested)}}}},
        "output": {"contracts": contracts},
    }


def _variable(label, slot, offset=0):
    return {"label": label, "slot": slot, "offset": offset, "type": "t_uint256", "contract": "X"}


# forge writes one of these for a later `forge inspect`, beside the build-info holding the compiled output
_NO_COMPILED_OUTPUT = {"id": "dd58ffd9af95c782", "language": "Solidity", "source_id_to_path": {}}


def test_contract_with_no_root_variables_is_not_listed():
    assert mod.root_storage([_compiled({"src/A.sol:A": []})]) == []


def test_contract_with_a_root_variable_is_listed():
    assert mod.root_storage([_compiled({"src/A.sol:A": [_variable("first", "0")]})]) == [
        "src/A.sol:A first slot 0 offset 0"
    ]


def test_every_root_variable_of_every_contract_is_listed():
    # a contract with none between two with several: each line belongs to its own contract, in slot order
    build_info = _compiled(
        {
            "src/A.sol:A": [_variable("first", "0"), _variable("second", "0", 20)],
            "src/A.sol:Empty": [],
            "src/B.sol:B": [_variable("third", "0"), _variable("fourth", "1")],
        }
    )
    assert mod.root_storage([build_info]) == [
        "src/A.sol:A first slot 0 offset 0",
        "src/A.sol:A second slot 0 offset 20",
        "src/B.sol:B third slot 0 offset 0",
        "src/B.sol:B fourth slot 1 offset 0",
    ]


def test_root_variables_are_listed_from_every_build_info():
    # a repository using two solc versions has contracts in separate files, and one left unread would look clean
    assert mod.root_storage(
        [_compiled({"src/A.sol:A": [_variable("first", "0")]}), _compiled({"src/B.sol:B": [_variable("second", "0")]})]
    ) == ["src/A.sol:A first slot 0 offset 0", "src/B.sol:B second slot 0 offset 0"]


def test_build_info_without_compiled_output_is_passed_over():
    assert mod.root_storage([_NO_COMPILED_OUTPUT, _compiled({"src/A.sol:A": [_variable("first", "0")]})]) == [
        "src/A.sol:A first slot 0 offset 0"
    ]


@pytest.mark.parametrize("build_infos", [[], [_NO_COMPILED_OUTPUT]])
def test_no_compiled_output_anywhere_is_an_error(build_infos):
    # nothing was read, which must not look like a build with no root variables
    with pytest.raises(SystemExit) as refused:
        mod.root_storage(build_infos)
    assert refused.value.code == "storage-successor: no build-info holds compiled output"


def test_build_that_did_not_ask_for_storage_layouts_is_an_error():
    # every contract would have no layout, which must not look like a build with no root variables
    with pytest.raises(SystemExit) as refused:
        mod.root_storage([_compiled({"src/A.sol:A": []}, requested=("abi",))])
    assert refused.value.code == "storage-successor: a build-info did not ask solc for storageLayout"


def test_list_root_storage_reads_every_build_info_in_the_folder(tmp_path, capsys):
    (tmp_path / "a.json").write_text(json.dumps(_compiled({"src/A.sol:A": [_variable("first", "0")]})))
    (tmp_path / "b.json").write_text(json.dumps(_NO_COMPILED_OUTPUT))
    (tmp_path / "c.json").write_text(json.dumps(_compiled({"src/C.sol:C": [_variable("second", "1")]})))
    assert mod.main([str(tmp_path), "--list-root-storage"]) == 0
    assert capsys.readouterr().out == "src/A.sol:A first slot 0 offset 0\nsrc/C.sol:C second slot 1 offset 0\n"
