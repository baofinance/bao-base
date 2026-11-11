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

import importlib.util
import json
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


def errors(a, b, retyped=None, added=None, renamed=None, rekeyed=None):
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
    assert has(errors(V2, flat("t_uint128"), {"TokenBalance": {"typo": "uint104"}}), "typo", "not found")


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
    assert not has(errs, "not found"), errs


def test_narrowed_amount_is_rejected():
    assert has(errors(V2, flat("t_uint64")), "amount", "narrowed")


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


# ── a declaration naming a struct absent from the compared layout is ignored. A contract with several
#    namespaced structs (the reward distributor: its storage struct plus RewardData) collects retyped / added /
#    renamed declarations across its whole inheritance chain; when ONE namespace's layout is compared, a
#    declaration naming a struct not present here must be skipped, or a sibling struct's valid declaration
#    false-fires "not found". Without that skip, the OtherStruct declarations below would each report unfound. ──


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


def _build_info_with_struct_doc(text):
    """A build-info of one contract `C` holding a struct `S` with this NatSpec, and a struct with no tag."""
    contract = {
        "nodeType": "ContractDefinition",
        "id": 7,
        "name": "C",
        "linearizedBaseContracts": [7],
        "nodes": [
            {"nodeType": "StructDefinition", "id": 1, "name": "S", "documentation": {"text": text}},
            {"nodeType": "StructDefinition", "id": 2, "name": "Plain", "documentation": {"text": "an ordinary struct"}},
        ],
    }
    return {"output": {"sources": {"X.sol": {"ast": {"nodes": [contract]}}}}}, contract


def test_rekeyed_declarations_are_read_from_the_struct():
    build_info, contract = _build_info_with_struct_doc(
        "@custom:storage-location erc7201:my.ns\n@custom:bao-rekeyed-from integrals uint8"
    )
    assert mod._rekeyed(build_info, contract) == {"S": {"integrals": "uint8"}}


def test_rekeyed_tag_is_recognized():
    build_info, _contract = _build_info_with_struct_doc("@custom:bao-rekeyed-from integrals uint8")
    assert mod.unrecognized_bao_tags(build_info) == []


# uses of the tag that are not a declaration: no old type, a signed one, no width, text run on after the type,
# two types, punctuation after the field, a path for the field
_NOT_A_KEY_DECLARATION = (
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


@pytest.mark.parametrize("text", _NOT_A_KEY_DECLARATION)
def test_tag_that_is_not_a_whole_declaration_is_not_read_as_one(text):
    build_info, contract = _build_info_with_struct_doc(text)
    assert mod._rekeyed(build_info, contract) == {}


@pytest.mark.parametrize("text", _NOT_A_KEY_DECLARATION)
def test_tag_that_is_not_a_whole_declaration_is_reported(text):
    # read as nothing, it would leave a widened key "undocumented" with the line in plain sight, or pass unseen
    # where the key did not change
    build_info, _contract = _build_info_with_struct_doc("@custom:storage-location erc7201:my.ns\n" + text)
    assert [where for where, _message in mod.malformed_rekeyed_tags(build_info)] == ["C.S"]


def test_field_given_two_key_declarations_is_reported():
    build_info, _contract = _build_info_with_struct_doc(
        "@custom:bao-rekeyed-from integrals uint16\n@custom:bao-rekeyed-from integrals uint8"
    )
    reports = mod.malformed_rekeyed_tags(build_info)
    assert len(reports) == 1, reports
    assert reports[0][0] == "C.S" and "integrals" in reports[0][1] and "more than once" in reports[0][1], reports


def test_whole_key_declarations_are_not_reported():
    # one per field, each alone to the end of its line, as solc gives a struct's NatSpec: the lines after the first
    # start with a space, and trailing spaces are allowed
    text = "@custom:storage-location erc7201:my.ns\n @custom:bao-rekeyed-from integrals uint8\n @custom:bao-rekeyed-from other uint16  "
    build_info, contract = _build_info_with_struct_doc(text)
    assert mod.malformed_rekeyed_tags(build_info) == []
    assert mod._rekeyed(build_info, contract) == {"S": {"integrals": "uint8", "other": "uint16"}}


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
            {"nodeType": "StructDefinition", "id": node_id * 100 + i, "name": n, "documentation": {"text": d}}
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
