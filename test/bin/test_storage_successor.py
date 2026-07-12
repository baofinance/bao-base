"""Unit tests for the successor RULE in bin/storage-successor.py (successor_errors).

These pin the rule's branches with synthetic storageLayout dicts — the cheap, exhaustive way to cover every
kind of change and every container nesting. The rule: the ONLY accepted change is an integer field widened in
place AND documented with `@custom:bao-retyped-from <field> <oldType>` on its owning struct (oldType matching
the predecessor); everything else is rejected. The end-to-end pipeline (extract -> inject -> build -> this rule
on REAL solc output) is covered separately by the .sol-fixture integration test, which also keeps these
synthetic layouts honest — if their shape ever diverged from solc's, that test's verdict would break.

The golden case is the StabilityPool widening: TokenBalance.amount uint104 -> uint128, exercised directly and
through a mapping, a dynamic array, a static array, and a mapping-of-mappings.
"""
import importlib.util
import pathlib


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
    "t_uint256": _int(256), "t_uint192": _int(192), "t_uint136": _int(136), "t_uint128": _int(128),
    "t_uint104": _int(104), "t_uint64": _int(64), "t_uint40": _int(40), "t_int128": _int(128, signed=True),
    "t_address": {"encoding": "inplace", "label": "address", "numberOfBytes": "20"},
    "t_bytes32": {"encoding": "inplace", "label": "bytes32", "numberOfBytes": "32"},
}

DOC = {"TokenBalance": {"amount": "uint104"}}  # documents the amount widen on its owning struct


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
        types["t_map"] = {"encoding": "mapping", "label": "mapping(address => TokenBalance)", "numberOfBytes": "32", "key": "t_address", "value": "t_tb"}
        member = "t_map"
    elif kind == "dynarray":
        types["t_arr"] = {"encoding": "dynamic_array", "label": "TokenBalance[]", "numberOfBytes": "32", "base": "t_tb"}
        member = "t_arr"
    elif kind == "staticarray":
        types["t_sarr"] = {"encoding": "inplace", "label": "TokenBalance[3]", "numberOfBytes": "192", "base": "t_tb"}
        member = "t_sarr"
    elif kind == "mapmap":
        types["t_inner"] = {"encoding": "mapping", "label": "mapping(uint256 => TokenBalance)", "numberOfBytes": "32", "key": "t_uint256", "value": "t_tb"}
        types["t_outer"] = {"encoding": "mapping", "label": "mapping(address => mapping(uint256 => TokenBalance))", "numberOfBytes": "32", "key": "t_address", "value": "t_inner"}
        member = "t_outer"
    types["t_root"] = {"encoding": "inplace", "label": "struct Root", "numberOfBytes": "32", "members": [{"label": "field", "slot": "0", "offset": 0, "type": member}]}
    return {"storage": [{"label": "root", "slot": "0", "offset": 0, "type": "t_root"}], "types": types}


V2 = flat("t_uint104")  # deployed: uint104 amount


def errors(a, b, retyped=None, added=None, renamed=None):
    if renamed is None:
        return mod.successor_errors(a, b, retyped, added)
    return mod.successor_errors(a, b, retyped, added, renamed)


def nested(depth, tb=None):
    """A top-level var reaching a TokenBalance nested `depth` struct-layers deep (depth 0 = TokenBalance is the
    top-level var itself). Each wrapping layer holds the previous type as its single member, so nesting alone
    changes no struct's size."""
    types = dict(BASE_TYPES)
    types["t_tb"] = tb if tb is not None else token_balance()
    inner = "t_tb"
    for d in range(depth):
        name = f"t_L{d}"
        types[name] = {"encoding": "inplace", "label": f"struct L{d}", "numberOfBytes": types[inner]["numberOfBytes"],
                       "members": [{"label": "inner", "slot": "0", "offset": 0, "type": inner}]}
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
    assert has(errors(V2, flat("t_uint128"), {"TokenBalance": {"amount": "uint96"}}), "amount", "predecessor is uint104")


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
    tb["members"] = tb["members"] + [{"label": "extra", "slot": "0", "offset": 0, "type": "t_uint40"}]  # overlaps product
    assert has(errors(nested(0), nested(0, tb=tb), None, ADDED), "extra", "overlapping")


def test_stale_added_declaration_is_rejected():
    # names a field that is not actually a new member
    assert has(errors(nested(0), nested(0), None, {"TokenBalance": {"ghost"}}), "ghost", "not added")


def test_reordered_members_is_rejected():
    swapped = {"encoding": "inplace", "label": "struct TokenBalance", "numberOfBytes": "64", "members": [
        {"label": "product", "slot": "0", "offset": 13, "type": "t_uint128"},
        {"label": "amount", "slot": "0", "offset": 0, "type": "t_uint104"},
        {"label": "updatedAt", "slot": "1", "offset": 0, "type": "t_uint40"},
    ]}
    assert has(errors(V2, flat(tb=swapped)), "moved")


def test_mapping_key_change_is_rejected():
    a = contained("mapping")
    b = contained("mapping", "t_uint128")
    b["types"]["t_map"]["key"] = "t_bytes32"  # address -> bytes32 key
    assert has(errors(a, b, DOC), "mapping key changed")


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
