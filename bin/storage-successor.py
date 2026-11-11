#!/usr/bin/env python3
"""storage-successor: verify every `@custom:bao-upgrades-from` storage link in a build is a byte-compatible,
*documented* successor of its predecessor.

This is the storage-layout check OpenZeppelin cannot do: a field WIDENED in place into its own former padding
is byte-safe, but OZ blanket-rejects any retype — and its `@custom:oz-retyped-from` escape hatch can't reach
inside a namespaced ERC-7201 struct, because solc does not expose struct-member NatSpec (ethereum/solidity
#12295, OpenZeppelin/openzeppelin-upgrades#802 — both open). So bao contracts carry `@custom:bao-upgrades-from`
(which OZ ignores, validating the contract in isolation) and this script does the comparison instead. It runs
in bin/validate's version-reference step.

Given a build env (the fresh build-info directory validate produced, plus the project root), it:
  1. SEARCHES the build-info for every contract with `@custom:bao-upgrades-from <path>:<name>` — the pairs;
  2. for each, reads BY NAME the successor's and the named predecessor's `@custom:storage-location
     erc7201:<ns>` struct(s), and the declarations of what the successor's structs changed
     (`@custom:bao-retyped-from`, `@custom:bao-added`, `@custom:bao-renamed-from`, `@custom:bao-rekeyed-from`;
     all live in *struct-level* NatSpec, the only NatSpec solc preserves);
  3. INJECTS each namespaced struct as a plain state variable in a probe contract and builds it, so solc lays
     it out (a namespaced struct reached by assembly has no storageLayout otherwise);
  4. COMPARES the two layouts. A change is accepted only where it leaves every byte the predecessor wrote where
     it was AND the owning struct documents it. There are four such changes.
       - An unsigned integer field widened in place: uintN->uintM, M > N, nothing relocated. Documented with
         `@custom:bao-retyped-from <field> <oldType>`, where <field> is the member's name in the successor and
         <oldType> is the predecessor's type. A signed integer widened is refused: the bytes the wider type adds
         are zero in storage, so a negative value stored at the old width would read as a positive one.
       - A field added in bytes the predecessor never wrote: inside the struct without growing it, or at the end
         of the top-level namespace struct. Documented with `@custom:bao-added <field>`.
       - A field renamed where it stands. Documented with `@custom:bao-renamed-from <newField> <oldField>`.
       - A mapping key widened from one built-in unsigned integer to a wider one: uintN->uintM, M > N. Documented
         with `@custom:bao-rekeyed-from <field> <oldKeyType>`, where <field> is the member's name in the
         successor and <oldKeyType> is the predecessor's key type. An entry's slot is the hash of its key
         followed by the mapping's own slot, and the key goes in as 32 bytes, left-padded for an unsigned
         integer. The same number is the same 32 bytes under the wider type, so every entry stays where it is.
         The declaration covers the keys reached from <field> through mappings and arrays. A key inside a struct
         the field holds is declared on that struct. A field takes one declaration, so one old key type.
     Every other change is rejected: narrow, an UNDOCUMENTED change of those four kinds, move, reorder, remove,
     insert, kind-change, any other mapping-key change, array-resize, and a declaration that documents no change
     or contradicts the predecessor. The walk recurses through structs, mappings, arrays (static and dynamic),
     and their arbitrary nestings, so a change buried inside `mapping(k => S[])` is found. A struct that holds
     itself is not compared again inside its own comparison. The top-level struct is compared once more where it
     is nested in itself, since only at the top level may it grow.
     Three things are told by solc's type id, where the label does not tell them. Whether a type is a built-in
     integer: a user-defined value type's label is only its name, and it is never an integer whatever it is
     called. Whether a user-defined value type or an enum is the same declaration in the predecessor and the
     successor, as it must be: the bytes of the first are those of the type it is declared over, and a stored
     number of the second means the member at that place in its declaration. And whether a struct is the same
     declaration on both sides: it is then not compared, since it cannot differ, and what it declares is not
     judged, since it is of an earlier step. Every other type is compared by its label. The ids of the two
     layouts mean the same only because both are laid out in one compilation.
     A struct's declarations are its own. For each link they are read from the structs the successor's
     namespace struct reaches, wherever each is declared, and looked up by the struct's canonical name
     (`Scope.Name`, the scope being the contract or library that declares it), which is how solc labels it. The
     predecessor's own declarations, of what it changed from the version before it, are not read.
  5. REPORTS a `@custom:bao-*` tag that is not read as it stands: a tag the tool does not know, a use that is not
     the tag's whole declaration alone to the end of its line, a tag on a node of a kind it is not read on, a tag
     given twice for one field, and two upgrade references on one contract. A tag that solc does not keep is not
     seen: only the last NatSpec block before a declaration reaches the syntax tree.

The comparison functions take plain storageLayout dicts + a declarations map, so the rule is unit-testable
with synthetic inputs; `main` is exercised end-to-end by building `.sol` fixtures and running this script.

Exit 0 if every link is a documented byte-compatible successor (or there are none); 1 otherwise.
"""

import argparse
import glob
import json
import os
import re
import subprocess
import sys

from rich.console import Console

_NAMESPACE = re.compile(r"custom:storage-location\s+erc7201:(\S+)")
# A declaration is a tag and its arguments, alone to the end of their line. A use of a tag that is not one is
# reported (`malformed_bao_tags`) and not passed over: read loosely it could take a mistyped argument for a right
# one, and read as nothing it would leave its change undocumented with the line in plain sight.
_BAO_REF = re.compile(r"custom:bao-upgrades-from[ \t]+(\S+):([A-Za-z_]\w*)[ \t]*$", re.MULTILINE)
_BAO_RETYPED = re.compile(r"custom:bao-retyped-from[ \t]+(\w+)[ \t]+(u?int\d+)[ \t]*$", re.MULTILINE)
_BAO_ADDED = re.compile(r"custom:bao-added[ \t]+(\w+)[ \t]*$", re.MULTILINE)
_BAO_RENAMED = re.compile(r"custom:bao-renamed-from[ \t]+(\w+)[ \t]+(\w+)[ \t]*$", re.MULTILINE)
_BAO_REKEYED = re.compile(r"custom:bao-rekeyed-from[ \t]+(\w+)[ \t]+(uint\d+)[ \t]*$", re.MULTILINE)
# every `@custom:bao-*` tag this tool acts on, with its declaration, the form a report states, and the kind of
# syntax-tree node it is read on. A `@custom:bao-*` tag NOT here is a typo or an unimplemented tag: solc accepts
# it (it is a valid custom tag) but the tool silently ignores it, so the intended check never runs and the change
# ships unverified. `unrecognized_bao_tags` catches that. When you add a new bao tag, add it here.
_ON_A_CONTRACT = "ContractDefinition"
_ON_A_STRUCT = "StructDefinition"
_BAO_DECLARATIONS = {
    "bao-upgrades-from": (_BAO_REF, "<path>:<Contract>", _ON_A_CONTRACT),
    "bao-retyped-from": (_BAO_RETYPED, "<field> <oldIntegerType>", _ON_A_STRUCT),
    "bao-added": (_BAO_ADDED, "<field>", _ON_A_STRUCT),
    "bao-renamed-from": (_BAO_RENAMED, "<newField> <oldField>", _ON_A_STRUCT),
    "bao-rekeyed-from": (_BAO_REKEYED, "<field> <uintN>", _ON_A_STRUCT),
}
_BAO_TAG = re.compile(r"custom:(bao-[a-z-]+)")
_RECOGNIZED_BAO_TAGS = frozenset(_BAO_DECLARATIONS)
# the namespace OpenZeppelin's Initializable declares on its storage struct. Identifying Initializable by its
# namespace rather than by the contract name ties this to the same string bin/validate hashes into the slot it
# looks for in the creation bytecode, so the two cannot drift; it also means a home-grown contract that happens
# to be called Initializable cannot pass for it.
_OZ_INITIALIZABLE_NAMESPACE = "openzeppelin.storage.Initializable"


# ── the successor rule (pure; unit-testable with synthetic storageLayout dicts + declarations) ──────────────


def _kind(type_id, type_def):
    """The kind of a type in solc's storage layout. An integer is told by the type id, `t_uint<bits>` or
    `t_int<bits>`, and not by the label: a user-defined value type's label is its name, which can read as an
    integer (`type uint9 is int8;` compiles), while its id says `t_userDefinedValueType`."""
    if "members" in type_def:
        return "struct"
    if type_def.get("encoding") == "mapping":
        return "mapping"
    if "base" in type_def:
        return "array"  # dynamic_array, or a static (inplace) array — both carry `base`
    if re.fullmatch(r"t_u?int\d+", type_id):
        return "integer"
    return "elementary"  # address, bool, bytesN, string, ... — must match exactly


def _is_another_declaration(a_type_id, b_type_id):
    """Whether two types of one label are different declarations, where either is a user-defined value type or an
    enum. The label of each is only its name. A user-defined value type's bytes are those of the type it is declared
    over, and an enum's stored number means the member at that place in its declaration: the layout gives neither.
    The predecessor and the successor are laid out in one compilation, so one declaration has one id in both."""
    told_by_declaration = ("t_userDefinedValueType(", "t_enum(")
    return a_type_id != b_type_id and (
        a_type_id.startswith(told_by_declaration) or b_type_id.startswith(told_by_declaration)
    )


def _named(type_id, label):
    """A type's label as a report names it: a user-defined value type's label is its bare name, so it is said to be
    one; an enum's label already says `enum`."""
    return f"user-defined value type {label}" if type_id.startswith("t_userDefinedValueType(") else label


def _struct_name(label):
    # "struct Scope.Name" -> "Scope.Name", "struct Name" -> "Name": a StructDefinition's AST `canonicalName`, which
    # names the contract or library that declares the struct, and not its file. Its declarations are looked up by
    # it, so that a struct takes its own tags and not those of another struct of the same bare name.
    return label[len("struct ") :] if label.startswith("struct ") else label


def _occupied_ranges(entries, types):
    """The byte ranges [start, end) that a list of storage entries (struct members or top-level slots) occupy.
    A new field is a byte-safe APPEND exactly when its range overlaps none of these — it takes storage the
    predecessor never wrote (former padding or fresh trailing slots), so a live proxy reads it zero."""
    ranges = []
    for e in entries:
        start = int(e["slot"]) * 32 + int(e["offset"])
        ranges.append((start, start + int(types[e["type"]]["numberOfBytes"])))
    return ranges


# What `used` holds: (tag, structName, field) for a declaration that documented a change, each tag apart, so that
# one tag's declaration for a field does not stand for another's; and (_COMPARED, structName) for a successor's
# struct that was compared with another declaration.
_RETYPED = "retyped"
_ADDED = "added"
_RENAMED = "renamed"
_REKEYED = "rekeyed"
_COMPARED = "compared"


def _is_unsigned_widen(a_type_id, b_type_id):
    """Whether solc's type id `b_type_id` is a built-in unsigned integer wider than the built-in unsigned integer
    `a_type_id`. Judged on the id, `t_uint<bits>`, and not on the label: a user-defined value type may be named
    `uint7`, and its label then reads as an integer, while its id says `t_userDefinedValueType`."""
    a, b = re.fullmatch(r"t_uint(\d+)", a_type_id), re.fullmatch(r"t_uint(\d+)", b_type_id)
    return bool(a and b) and int(b.group(1)) > int(a.group(1))


def _compare_type(
    a_id,
    a_types,
    b_id,
    b_types,
    path,
    errors,
    retyped,
    used,
    declared_old,
    added=None,
    renamed=None,
    is_root=False,
    rekeyed=None,
    key_declaration=None,
    in_progress=None,
):
    """Recurse a matched type position. `retyped` = {structName: {field: oldTypeLabel}}; `added` =
    {structName: {field}}; `renamed` = {structName: {newField: oldField}}; `rekeyed` = {structName: {field:
    oldKeyTypeLabel}}; each keyed by the canonical name (`Scope.Name`) of the successor's struct, since the
    declarations are written on the successor's structs. `used` accumulates the declarations that documented a
    change, as (tag, structName, field), and the successor's structs compared with another declaration, as
    (_COMPARED, structName); `declared_old` is the declaration for THIS position (only meaningful on an integer
    leaf), or None; `key_declaration` is the key declaration of the struct member this position was reached from
    through mappings and arrays, as {"old": oldKeyTypeLabel, "consumed": whether a changed key has met it}, or
    None; `is_root` marks the top-level namespace struct (which may grow, since nothing follows it);
    `in_progress` holds the (predecessor, successor, is_root) struct pairs whose comparison this position is
    inside, so that a struct which holds itself is not compared within its own comparison of the same kind."""
    added = added or {}
    renamed = renamed or {}
    rekeyed = rekeyed or {}
    in_progress = set() if in_progress is None else in_progress
    a, b = a_types[a_id], b_types[b_id]
    ak, bk = _kind(a_id, a), _kind(b_id, b)
    if ak != bk:
        errors.append(f"{path}: type kind changed ({a['label']} -> {b['label']}; {a_id} -> {b_id})")
        return
    if declared_old is not None and ak != "integer":
        errors.append(f"{path}: @custom:bao-retyped-from declared on a non-integer field ({a['label']})")

    if ak == "struct":
        # One type id on both sides is one declaration: the two layouts come from one compilation, and a struct's
        # type id carries the id of its declaration. It cannot differ from itself, and what it declares is of an
        # earlier step than this one, so it is neither compared nor marked as compared.
        if a_id == b_id:
            return
        # A struct may hold itself through a mapping or an array. Met again inside its own comparison of the same
        # kind, the pair is passed over. The kind is part of it: the top-level struct may grow and a nested one may
        # not, so a top-level struct that holds itself is compared once more where it is nested.
        under_way = (a_id, b_id, is_root)
        if under_way in in_progress:
            return
        in_progress.add(under_way)
        struct_name = _struct_name(b["label"])
        used.add((_COMPARED, struct_name))
        declarations = retyped.get(struct_name, {})
        added_here = added.get(struct_name, set())
        renames = renamed.get(struct_name, {})  # {newLabel: oldLabel} — a documented member rename
        rekeys = rekeyed.get(struct_name, {})  # {successor's label: oldKeyTypeLabel} — a documented key widen
        old_to_new = {old: new for new, old in renames.items()}
        a_members = {m["label"]: m for m in a["members"]}
        b_members = {m["label"]: m for m in b["members"]}
        matched_b = set()  # successor members consumed by a predecessor match; the rest are candidate appends
        for label, ma in a_members.items():
            # A documented rename for this field takes precedence over same-name matching WHEN its new name is
            # present in the successor: an upgrade may free a name and reuse it for a different field, so
            # `label` in the predecessor and `label` in the successor can be different fields. Only when the
            # rename target is absent do we fall back to same-name matching (which keeps a stale rename a failure).
            mb = None
            if label in old_to_new:
                new_label = old_to_new[label]  # a documented rename maps this predecessor field to a new name
                mb = b_members.get(new_label)
                if mb is not None:
                    used.add((_RENAMED, struct_name, new_label))  # the rename was applied (new name present)
            if mb is None:
                mb = b_members.get(label)
            if mb is None:
                errors.append(f"{path}.{label}: member removed")
                continue
            matched_b.add(mb["label"])
            # A declaration names the member as the successor does: it is written on the successor's struct, and
            # where a name is freed and reused, the name is the successor's field of that name.
            member_declared = declarations.get(mb["label"])
            if member_declared is not None:
                used.add((_RETYPED, struct_name, mb["label"]))  # matched to a predecessor's member
            member_key = None
            if mb["label"] in rekeys:
                used.add((_REKEYED, struct_name, mb["label"]))  # matched to a predecessor's member
                member_key = {"old": rekeys[mb["label"]], "consumed": False}
            if str(ma["slot"]) != str(mb["slot"]) or ma["offset"] != mb["offset"]:
                errors.append(
                    f"{path}.{label}: member moved (slot {ma['slot']}:{ma['offset']} -> {mb['slot']}:{mb['offset']})"
                )
                continue
            _compare_type(
                ma["type"],
                a_types,
                mb["type"],
                b_types,
                f"{path}.{label}",
                errors,
                retyped,
                used,
                member_declared,
                added,
                renamed,
                rekeyed=rekeyed,
                key_declaration=member_key,
                in_progress=in_progress,
            )
            if member_key is not None and not member_key["consumed"]:
                errors.append(
                    f"{path}.{mb['label']}: `@custom:bao-rekeyed-from` is declared for this field and none of its "
                    f"mapping keys changed (a key inside a struct the field holds is declared on that struct)"
                )
        # A new member is a byte-compatible APPEND when its bytes overlap no existing member (it takes storage the
        # predecessor never wrote) AND it relocates nothing: either the struct's size is unchanged (it packs into
        # the struct's own trailing padding — safe in any container, since the field after a struct starts a new
        # slot) or this is the top-level namespace struct (nothing follows it, so it may grow). Every accepted
        # append must be documented with `@custom:bao-added`, so no layout change is silent.
        occupied = _occupied_ranges(a["members"], a_types)
        grows = int(b["numberOfBytes"]) > int(a["numberOfBytes"])
        for label, mb in b_members.items():
            if label in matched_b:  # already paired with a predecessor member (by same name or by rename)
                continue
            start = int(mb["slot"]) * 32 + int(mb["offset"])
            end = start + int(b_types[mb["type"]]["numberOfBytes"])
            if any(start < r_end and r_start < end for r_start, r_end in occupied):
                errors.append(f"{path}.{label}: member added overlapping existing storage (an insert, not an append)")
            elif grows and not is_root:
                errors.append(
                    f"{path}.{label}: member added grows a nested struct (relocates the storage after it); only a "
                    f"size-preserving append, or an append to the top-level namespace struct, is byte-compatible"
                )
            elif label not in added_here:
                errors.append(
                    f"{path}.{label}: undocumented add; annotate the owning struct `@custom:bao-added {label}`"
                )
            else:
                used.add((_ADDED, struct_name, label))  # documented, byte-compatible append
        in_progress.discard(under_way)

    elif ak == "mapping":
        a_key, b_key = a_types[a["key"]]["label"], b_types[b["key"]]["label"]
        if a_key != b_key:
            # A built-in unsigned integer key WIDENED in place leaves every entry where it is. An entry's slot is
            # the hash of its key followed by the mapping's own slot, and the key goes in as 32 bytes, left-padded
            # for an unsigned integer: the same number is the same 32 bytes under either type. It is accepted on
            # a widened field's terms: documented on the owning struct, the declared old type being the
            # predecessor's. Any other change of a key is refused, documented or not.
            if key_declaration is not None:
                key_declaration["consumed"] = True  # a changed key met the declaration: reported here, not as stale
            if not _is_unsigned_widen(a["key"], b["key"]):
                errors.append(f"{path}: mapping key changed ({a_key} -> {b_key})")
            elif key_declaration is None:
                errors.append(
                    f"{path}: undocumented key widen ({a_key} -> {b_key}): no `@custom:bao-rekeyed-from <field> "
                    f"{a_key}` was read for it from the owning struct"
                )
            elif key_declaration["old"] != a_key:
                errors.append(
                    f"{path}: `@custom:bao-rekeyed-from` declares the old key type {key_declaration['old']} and "
                    f"the predecessor's key is {a_key}"
                )
        elif _is_another_declaration(a["key"], b["key"]):
            if key_declaration is not None:
                key_declaration["consumed"] = True  # reported here, as a refused change of the key
            errors.append(
                f"{path}: the mapping key's type, {_named(a['key'], a_key)}, is not the same declaration in the "
                f"predecessor and the successor ({a['key']}, {b['key']})"
            )
        _compare_type(
            a["value"],
            a_types,
            b["value"],
            b_types,
            f"{path}[k]",
            errors,
            retyped,
            used,
            None,
            added,
            renamed,
            rekeyed=rekeyed,
            key_declaration=key_declaration,
            in_progress=in_progress,
        )

    elif ak == "array":
        if a["numberOfBytes"] != b["numberOfBytes"]:
            errors.append(
                f"{path}: array resized ({a['label']} {a['numberOfBytes']}B -> {b['label']} {b['numberOfBytes']}B)"
            )
        _compare_type(
            a["base"],
            a_types,
            b["base"],
            b_types,
            f"{path}[i]",
            errors,
            retyped,
            used,
            None,
            added,
            renamed,
            rekeyed=rekeyed,
            key_declaration=key_declaration,
            in_progress=in_progress,
        )

    elif ak == "integer":
        a_signed, b_signed = not a["label"].startswith("u"), not b["label"].startswith("u")
        a_size, b_size = int(a["numberOfBytes"]), int(b["numberOfBytes"])
        if a_signed != b_signed:
            errors.append(f"{path}: signedness changed ({a['label']} -> {b['label']})")
        elif b_size < a_size:
            errors.append(f"{path}: integer narrowed ({a['label']} -> {b['label']})")
        elif b_size > a_size and a_signed:
            # The bytes a wider type adds are zero in storage. A negative value stored at the old width has its
            # sign in the old top bit, so at the wider type it reads as a positive one. Refused, documented or not.
            errors.append(
                f"{path}: signed integer widened ({a['label']} -> {b['label']}): a negative value stored at the "
                f"old width reads as a positive one at the new"
            )
        elif b_size > a_size:
            # an unsigned widen — safe in bytes (any displacement would have moved a following member, caught
            # above), but only allowed when the developer documented it and the declared old type is the real one.
            if declared_old is None:
                errors.append(
                    f"{path}: undocumented widen ({a['label']} -> {b['label']}); add `@custom:bao-retyped-from "
                    f"<field> {a['label']}` to the owning struct, <field> being the member's name in the successor"
                )
            elif declared_old != a["label"]:
                errors.append(
                    f"{path}: declared `@custom:bao-retyped-from ... {declared_old}` but predecessor is {a['label']}"
                )
        else:  # same size, same sign: unchanged
            if declared_old is not None:
                errors.append(
                    f"{path}: stale `@custom:bao-retyped-from ... {declared_old}` — {a['label']} is unchanged"
                )

    else:  # elementary — must be identical
        if a["label"] != b["label"]:
            errors.append(f"{path}: type changed ({a['label']} -> {b['label']})")
        elif _is_another_declaration(a_id, b_id):
            errors.append(
                f"{path}: {_named(a_id, a['label'])} is not the same declaration in the predecessor and the "
                f"successor ({a_id}, {b_id})"
            )


def successor_errors(a_layout, b_layout, retyped=None, added=None, renamed=None, rekeyed=None):
    """a_layout/b_layout: solc storageLayout dicts ({"storage", "types"}), laid out in ONE compilation: a type id
    means the same declaration in both only then, and the comparison reads one id in both as one declaration.
    retyped: {structName: {field: oldTypeLabel}} from `@custom:bao-retyped-from`; added: {structName: {field}}
    from `@custom:bao-added`; renamed: {structName: {newField: oldField}} from `@custom:bao-renamed-from`;
    rekeyed: {structName: {field: oldKeyTypeLabel}} from `@custom:bao-rekeyed-from`; each the successor's.
    Return the list of changes that stop B being a documented byte-compatible successor of A (empty ==
    compatible)."""
    retyped = retyped or {}
    added = added or {}
    renamed = renamed or {}
    rekeyed = rekeyed or {}
    errors = []
    used = set()
    a_by_label = {s["label"]: s for s in a_layout["storage"]}
    b_by_label = {s["label"]: s for s in b_layout["storage"]}
    for label, sa in a_by_label.items():
        sb = b_by_label.get(label)
        if sb is None:
            errors.append(f"{label}: top-level slot removed")
            continue
        if str(sa["slot"]) != str(sb["slot"]) or sa["offset"] != sb["offset"]:
            errors.append(
                f"{label}: top-level slot moved (slot {sa['slot']}:{sa['offset']} -> {sb['slot']}:{sb['offset']})"
            )
            continue
        _compare_type(
            sa["type"],
            a_layout["types"],
            sb["type"],
            b_layout["types"],
            label,
            errors,
            retyped,
            used,
            None,
            added,
            renamed,
            is_root=True,
            rekeyed=rekeyed,
        )
    for label in b_by_label:
        if label not in a_by_label:
            errors.append(f"{label}: top-level slot added (not yet allowed)")
    # A declaration is the successor's: it is written on the successor's struct and says what that struct changed.
    # One that documented nothing is reported, for every struct of the successor's layout but one that is the same
    # declaration in the predecessor's and was compared with no other: its declarations are of an earlier step.
    # Declarations of any other struct are not this comparison's: the predecessor's own, of what it changed from the
    # version before it, and those of structs in other layouts.
    judged = set()
    for type_id, type_def in b_layout["types"].items():
        if "members" in type_def:
            name = _struct_name(type_def["label"])
            if type_id not in a_layout["types"] or (_COMPARED, name) in used:
                judged.add(name)
    for struct_name, fields in retyped.items():
        if struct_name not in judged:
            continue
        for field in fields:
            if (_RETYPED, struct_name, field) not in used:
                errors.append(
                    f"{struct_name}.{field}: `@custom:bao-retyped-from` names a field that was not compared with "
                    f"a field of the predecessor"
                )
    for struct_name, fields in added.items():
        if struct_name not in judged:
            continue
        for field in fields:
            if (_ADDED, struct_name, field) not in used:
                errors.append(f"{struct_name}.{field}: `@custom:bao-added` names a field that was not added")
    for struct_name, new_fields in renamed.items():
        if struct_name not in judged:
            continue
        for new_field in new_fields:
            if (_RENAMED, struct_name, new_field) not in used:
                errors.append(
                    f"{struct_name}.{new_field}: `@custom:bao-renamed-from` names a field that was not renamed"
                )
    for struct_name, fields in rekeyed.items():
        if struct_name not in judged:
            continue
        for field in fields:
            if (_REKEYED, struct_name, field) not in used:
                errors.append(
                    f"{struct_name}.{field}: `@custom:bao-rekeyed-from` names a field that was not compared with "
                    f"a field of the predecessor"
                )
    return errors


# ── build-env access: find the pairs, namespaces, and retype declarations BY NAME from the build-info ───────


def _doc(node):
    d = node.get("documentation") if isinstance(node, dict) else None
    return d.get("text") if isinstance(d, dict) else ""


def _contracts(build_info):
    """Yield every (source_path, ContractDefinition node) in the build-info."""
    for path, src in build_info.get("output", {}).get("sources", {}).items():
        ast = src.get("ast")
        if isinstance(ast, dict):
            for node in ast.get("nodes", []):
                if isinstance(node, dict) and node.get("nodeType") == "ContractDefinition":
                    yield path, node


def _inherited_structs(build_info, contract_node):
    """Yield every StructDefinition in the contract AND all its linearized base contracts, most-derived first.
    A namespaced ERC-7201 struct usually lives in a base (the reward distributor/accumulator, not the pool that
    inherits them), so a contract's storage is the union across its inheritance chain — this walk mirrors OZ
    upgrades-core, which collects namespaces over `linearizedBaseContracts` (storage/namespace.js, extract.js)."""
    by_id = {node["id"]: node for _path, node in _contracts(build_info)}
    for cid in contract_node.get("linearizedBaseContracts", [contract_node.get("id")]):
        base = by_id.get(cid)
        if base is None:
            continue
        for member in base.get("nodes", []):
            if isinstance(member, dict) and member.get("nodeType") == "StructDefinition":
                yield member


def _namespaces(build_info, contract_node):
    """namespace -> StructDefinition for the @custom:storage-location structs of the contract and its bases."""
    out = {}
    for member in _inherited_structs(build_info, contract_node):
        m = _NAMESPACE.search(_doc(member))
        if m:
            out.setdefault(m.group(1), member)  # most-derived wins (linearized is derived-first)
    return out


def initializable_contracts(build_info):
    """'<source>:<Name>' for every contract that inherits OpenZeppelin's Initializable, directly or indirectly.

    bin/validate asks this to decide what a production implementation's constructor must do: one inheriting
    Initializable must disable them, one that does not has no initializer to disable and must write no storage
    at all. Answering from the inheritance chain rather than from the bytecode is what keeps the check
    unfakeable — a contract that inherits Initializable and omits `_disableInitializers()` still has to satisfy
    the stricter rule, instead of being read as a contract that never had initializers."""
    return [
        f"{path}:{node.get('name')}"
        for path, node in _contracts(build_info)
        if _OZ_INITIALIZABLE_NAMESPACE in _namespaces(build_info, node)
    ]


def root_storage(build_infos):
    """'<source>:<Name> <variable> slot <slot> offset <offset>' for every root variable: a state variable solc
    places in sequential slots.

    bin/validate asks this to enforce namespace-only storage. It reads solc's own storage layout, which never lists
    an ERC-7201 namespaced field, rather than `forge inspect`, whose report can list them in the same array. forge
    leaves the layout out when it would be empty, so a contract with no root variables has none at all. That makes
    a build that read nothing, or never asked for layouts, look clean, so both are refused."""
    compiled = [build_info for build_info in build_infos if "output" in build_info]
    if not compiled:
        sys.exit("storage-successor: no build-info holds compiled output")
    lines = []
    for build_info in compiled:
        if "storageLayout" not in build_info["input"]["settings"]["outputSelection"]["*"]["*"]:
            sys.exit("storage-successor: a build-info did not ask solc for storageLayout")
        for source, contracts in build_info["output"]["contracts"].items():
            for name, contract in contracts.items():
                for entry in contract.get("storageLayout", {}).get("storage", []):
                    lines.append(f"{source}:{name} {entry['label']} slot {entry['slot']} offset {entry['offset']}")
    return lines


def _structs_by_id(build_info):
    """Syntax-tree id -> (source_path, StructDefinition) for every struct in the build: declared in a contract, a
    library or an interface, or at file level."""
    out = {}
    for path, src in build_info.get("output", {}).get("sources", {}).items():
        ast = src.get("ast")
        if not isinstance(ast, dict):
            continue
        for node in ast.get("nodes", []):
            if not isinstance(node, dict):
                continue
            if node.get("nodeType") == "StructDefinition":
                out[node["id"]] = (path, node)
            elif node.get("nodeType") == "ContractDefinition":
                for member in node.get("nodes", []):
                    if isinstance(member, dict) and member.get("nodeType") == "StructDefinition":
                        out[member["id"]] = (path, member)
    return out


def _reached_structs(struct_id, structs_by_id):
    """Syntax-tree id -> (source_path, StructDefinition) for this struct and every struct its storage holds: the
    type of a member, the value of a mapping, the element of an array, and so on through each struct met. A type
    names its declaration by id, so each is the very struct the layout lays out, whatever else in the build shares
    its name. A struct that holds itself ends the walk."""
    reached = {}

    def follow(type_name):
        kind = type_name.get("nodeType")
        if kind == "UserDefinedTypeName":
            enter(type_name.get("referencedDeclaration"))
        elif kind == "Mapping":
            follow(type_name["valueType"])
        elif kind == "ArrayTypeName":
            follow(type_name["baseType"])

    def enter(declaration_id):
        # an id that is no struct's is an enum's, a contract's or a user-defined value type's
        if declaration_id in structs_by_id and declaration_id not in reached:
            reached[declaration_id] = structs_by_id[declaration_id]
            for member in structs_by_id[declaration_id][1].get("members", []):
                follow(member["typeName"])

    enter(struct_id)
    return reached


def _link_declarations(struct_id, structs_by_id):
    """What a link is checked with, where `struct_id` is its successor's namespace struct: the changes declared by
    the structs that struct reaches, and the errors that stop them being read.

    The changes are the four maps `successor_errors` takes, in its order: retyped {struct: {field: oldTypeLabel}},
    added {struct: {field}}, renamed {struct: {newField: oldField}}, rekeyed {struct: {field: oldKeyTypeLabel}}.
    Each is keyed by the struct's canonical name, `Scope.Name`, which is how solc labels the struct in a layout and
    how the comparison looks its declarations up. So a struct declared at file level or in a library carries its
    own tags, no struct takes those of another of the same bare name, and the predecessor's declarations, of what
    it changed from the version before it, are not read at all.

    Two contracts of one name in two files give two structs one canonical name. The link's own is the one its
    successor reaches, so the other does not matter. Where the successor reaches both and they declare different
    changes, the comparison could not tell them apart: that is the link's error."""
    maps = ({}, {}, {}, {})
    errors = []
    first = {}  # canonical name -> (source path, what the first reached struct of that name declares)
    for path, node in _reached_structs(struct_id, structs_by_id).values():
        name = node["canonicalName"]
        text = _doc(node)
        declared = (
            {field: old for field, old in _BAO_RETYPED.findall(text)},
            set(_BAO_ADDED.findall(text)),
            {new: old for new, old in _BAO_RENAMED.findall(text)},
            {field: old for field, old in _BAO_REKEYED.findall(text)},
        )
        if name in first:
            if first[name][1] != declared:
                errors.append(
                    f"two structs the successor holds have the canonical name {name} and declare different changes "
                    f"({first[name][0]}, {path})"
                )
            continue
        first[name] = (path, declared)
        for target, declarations in zip(maps, declared):
            if declarations:
                target[name] = declarations
    return maps, errors


def _pairs(build_info):
    """Every bao-upgrade link to check: list of (succ_path, succ_contract, pred_path, pred_contract)."""
    found = []
    for succ_path, node in _contracts(build_info):
        m = _BAO_REF.search(_doc(node))
        if m:
            found.append((succ_path, node.get("name"), m.group(1), m.group(2)))
    return found


# ── namespace slot-getter check: solc records, in each inline-assembly block's `externalReferences`, which
#    Solidity declarations its Yul touches. So the tool AUTO-DETECTS every getter that returns a single
#    `storage <struct>` (a struct carrying `@custom:storage-location erc7201:<ns>`) and sets that return var's
#    `.slot` from a hardcoded constant, and verifies the constant equals the namespace's canonical ERC-7201 slot
#    (`cast index-erc7201`, reusing foundry rather than re-implementing keccak). No annotation is needed and none
#    can be forgotten — a hardcoded slot that drifts from its namespace is caught wherever it lives (a pool, a
#    reward base, a throwaway migrator, even OZ's Initializable). A getter that COMPUTES its slot has no hardcoded
#    value to verify and is skipped. ──


def _namespace_by_struct_id(build_info):
    """StructDefinition node id -> namespace, for every struct with `@custom:storage-location erc7201:<ns>`."""
    out = {}
    for _path, node in _contracts(build_info):
        for member in node.get("nodes", []):
            if isinstance(member, dict) and member.get("nodeType") == "StructDefinition":
                m = _NAMESPACE.search(_doc(member))
                if m:
                    out[member["id"]] = m.group(1)
    return out


def _state_vars_by_id(build_info):
    """Node id -> VariableDeclaration for every contract-level and file-level state variable/constant — the
    declarations an inline-assembly block references by id in its `externalReferences`."""
    out = {}
    for _path, src in build_info.get("output", {}).get("sources", {}).items():
        ast = src.get("ast")
        if not isinstance(ast, dict):
            continue
        for node in ast.get("nodes", []):
            if not isinstance(node, dict):
                continue
            if node.get("nodeType") == "VariableDeclaration":
                out[node["id"]] = node
            elif node.get("nodeType") == "ContractDefinition":
                for member in node.get("nodes", []):
                    if isinstance(member, dict) and member.get("nodeType") == "VariableDeclaration":
                        out[member["id"]] = member
    return out


def _inline_assembly_nodes(node):
    """Yield every InlineAssembly node anywhere under `node`."""
    if isinstance(node, dict):
        if node.get("nodeType") == "InlineAssembly":
            yield node
        for value in node.values():
            yield from _inline_assembly_nodes(value)
    elif isinstance(node, list):
        for item in node:
            yield from _inline_assembly_nodes(item)


def _norm_slot(hexstr):
    """A hex slot as 0x + 64 lowercase hex digits (so a value and cast's output compare regardless of padding)."""
    h = str(hexstr).strip().lower()
    if h.startswith("0x"):
        h = h[2:]
    return "0x" + h.rjust(64, "0")


def _cast_erc7201(namespace, cache):
    if namespace not in cache:
        result = subprocess.run(["cast", "index-erc7201", namespace], capture_output=True, text=True)
        if result.returncode != 0:
            sys.exit(f"storage-successor: `cast index-erc7201 {namespace}` failed\n{result.stderr}")
        cache[namespace] = _norm_slot(result.stdout)
    return cache[namespace]


def _namespace_getters(build_info):
    """Yield (contract, fn, namespace, struct_id, slot_const_or_None) for every namespace slot getter: a function
    returning a single `storage <struct>` whose struct has an `@custom:storage-location`, that sets the return
    var's `.slot` in assembly. `slot_const` is the literal constant the `.slot` is set from, or None when it is
    computed. Shared by the slot check (verify the constant) and the partial-successor check (which struct/namespace
    a migrator reaches)."""
    namespace_by_struct = _namespace_by_struct_id(build_info)
    state_vars = _state_vars_by_id(build_info)
    for _path, contract in _contracts(build_info):
        for fn in contract.get("nodes", []):
            if not (isinstance(fn, dict) and fn.get("nodeType") == "FunctionDefinition"):
                continue
            params = fn.get("returnParameters", {}).get("parameters", [])
            if len(params) != 1:
                continue
            ret = params[0]
            typ = ret.get("typeName") or {}
            if ret.get("storageLocation") != "storage" or typ.get("nodeType") != "UserDefinedTypeName":
                continue
            struct_id = typ.get("referencedDeclaration")
            namespace = namespace_by_struct.get(struct_id)
            if namespace is None:
                continue  # returns a storage struct, but not a namespaced one
            ret_id = ret.get("id")
            sets_slot = False
            slot_const = None
            for asm in _inline_assembly_nodes(fn.get("body")):
                refs = asm.get("externalReferences", [])
                if not any(r.get("declaration") == ret_id and r.get("isSlot") for r in refs):
                    continue
                sets_slot = True
                for r in refs:
                    target = state_vars.get(r.get("declaration"))
                    if target is None or not target.get("constant"):
                        continue
                    value = target.get("value")
                    if isinstance(value, dict) and value.get("nodeType") == "Literal" and value.get("kind") == "number":
                        slot_const = target
            if sets_slot:
                yield contract, fn, namespace, struct_id, slot_const


def slot_getter_errors(build_info):
    """Verify every namespace slot getter's hardcoded slot equals its namespace's canonical ERC-7201 slot (a getter
    that computes its slot has no literal to verify and is skipped). Return a list of (where, message)."""
    cache = {}
    errors = []
    for contract, fn, namespace, _struct_id, slot_const in _namespace_getters(build_info):
        if slot_const is None:
            continue
        actual = _norm_slot(slot_const["value"]["value"])
        expected = _cast_erc7201(namespace, cache)
        if actual != expected:
            where = f"{contract.get('name')}.{fn.get('name')}"
            errors.append(
                (where, f"slot constant {slot_const.get('name')} = {actual} != erc7201({namespace}) = {expected}")
            )
    return errors


# ── partial-migrator support: a light contract with `@custom:bao-upgrades-from` that REACHES a namespace by
#    assembly through another contract's struct (one it does not declare) touches only that namespace. The
#    successor check byte-compares each reached struct against the predecessor's same namespace and, because such a
#    migrator is partial by construction, does not flag the predecessor namespaces it never touches as "gone". ──


def _struct_owner_and_ref(build_info):
    """Two maps over every StructDefinition: id -> owning ContractDefinition id, and id -> (source_path, contract
    name, struct name) for injecting it into a probe."""
    owner, ref = {}, {}
    for path, contract in _contracts(build_info):
        for member in contract.get("nodes", []):
            if isinstance(member, dict) and member.get("nodeType") == "StructDefinition":
                owner[member["id"]] = contract["id"]
                ref[member["id"]] = (path, contract.get("name"), member.get("name"))
    return owner, ref


def _accessed_namespaces_by_contract(build_info):
    """contract id -> {namespace: struct_id} for namespaces each contract REACHES via its own getters that return a
    struct defined OUTSIDE its inheritance chain (a foreign struct) — the mark of a partial migrator that accesses
    another contract's storage rather than declaring its own."""
    owner, _ref = _struct_owner_and_ref(build_info)
    chains = {
        contract["id"]: set(contract.get("linearizedBaseContracts", [contract["id"]]))
        for _path, contract in _contracts(build_info)
    }
    out = {}
    for contract, _fn, namespace, struct_id, _slot in _namespace_getters(build_info):
        cid = contract["id"]
        if owner.get(struct_id) not in chains.get(cid, {cid}):
            out.setdefault(cid, {})[namespace] = struct_id
    return out


# ── unrecognized-tag check: a misspelled `@custom:bao-*` tag (bao-renamd-from, bao-retype-from, …) compiles
#    fine but matches no regex, so its intended check is silently skipped — the most dangerous failure mode for a
#    validator. Every `@custom:bao-*` tag in the build must be one the tool recognizes. ──────────────────────


def _documented_nodes(build_info):
    """Yield (where, node_type, doc_text) for every documented declaration — file-level nodes and contract members
    — since a `@custom:bao-*` tag can sit on a contract, a struct, or a state-variable constant. `node_type` is
    the declaration's kind as the syntax tree names it: `ContractDefinition`, `StructDefinition`, and so on."""
    for path, src in build_info.get("output", {}).get("sources", {}).items():
        ast = src.get("ast")
        if not isinstance(ast, dict):
            continue
        for node in ast.get("nodes", []):
            if not isinstance(node, dict):
                continue
            name = node.get("name") or os.path.basename(path)
            if _doc(node):
                yield name, node.get("nodeType"), _doc(node)
            for member in node.get("nodes", []):
                if isinstance(member, dict) and _doc(member):
                    yield f"{name}.{member.get('name')}", member.get("nodeType"), _doc(member)


def unrecognized_bao_tags(build_info):
    """Every `@custom:bao-*` tag that the tool does not recognize (a typo, or a tag with no implementation).
    Return list of (where, tag), deduplicated."""
    out = []
    seen = set()
    for where, _node_type, text in _documented_nodes(build_info):
        for tag in _BAO_TAG.findall(text):
            if tag not in _RECOGNIZED_BAO_TAGS and (where, tag) not in seen:
                seen.add((where, tag))
                out.append((where, tag))
    return out


def malformed_bao_tags(build_info):
    """Every documented declaration with a recognized `@custom:bao-*` tag that is not read as it stands. Three
    ways. A use that is not the tag's whole declaration (`_BAO_DECLARATIONS`), alone to the end of its line. A tag
    on a node of a kind it is not read on: `bao-upgrades-from` is read on a contract and the others on a struct.
    And a tag used more than once where one is read: for one field of a struct, or on one contract.

    Read as nothing, a struct's tag would leave its change reported as undocumented with the line in plain sight,
    or pass unseen where nothing changed, and a `bao-upgrades-from` would leave its contract unchecked. Of two
    `bao-upgrades-from` only the first would be a link, and of two that give one field an old type or an old name
    only the last would count. Return list of (where, message).

    Not seen here: solc keeps only the last NatSpec block before a declaration, so a tag in an earlier block is not
    in the syntax tree."""
    out = []
    for where, node_type, text in _documented_nodes(build_info):
        for tag, (declaration, form, read_on) in _BAO_DECLARATIONS.items():
            declarations = declaration.findall(text)
            uses = len(re.findall(rf"custom:{tag}(?![a-z-])", text))
            if uses > len(declarations):
                out.append(
                    (
                        where,
                        f"{uses - len(declarations)} use(s) of @custom:{tag} not of the form `{form}` alone to the "
                        f"end of the line",
                    )
                )
            if uses and node_type != read_on:
                kind = "contract" if read_on == _ON_A_CONTRACT else "struct"
                out.append((where, f"@custom:{tag} is on a {node_type} and is read only on a {kind}"))
            if read_on == _ON_A_CONTRACT:
                if len(declarations) > 1:
                    out.append((where, f"@custom:{tag} is declared more than once"))
                continue
            # the field a struct's declaration is for is its first argument
            fields = [found if isinstance(found, str) else found[0] for found in declarations]
            for field in sorted({field for field in fields if fields.count(field) > 1}):
                out.append((where, f"@custom:{tag} declares {field} more than once"))
    return out


# ── injection: lay out each struct via a probe so solc emits its storageLayout ──────────────────────────────


def probe_source(jobs):
    """Pure: jobs = list of (index, path, contract, struct). Return (solidity_source, {index: probe_name})."""
    lines = ["// SPDX-License-Identifier: MIT", "pragma solidity >=0.8.28 <0.9.0;", ""]
    imports, bodies, names = set(), [], {}
    for idx, path, contract, struct in jobs:
        imports.add(f'import {{{contract}}} from "{path}";')
        bodies.append(f"contract _Probe{idx} {{ {contract}.{struct} s; }}")
        names[idx] = f"_Probe{idx}"
    lines += sorted(imports) + [""] + bodies + [""]
    return "\n".join(lines), names


def _inject_layouts(jobs, root):
    """Build one probe for these jobs; return {index: storageLayout dict}. The files it imports must compile in one
    compilation: a file pinned to one compiler version cannot be imported beside a file pinned to another."""
    source, names = probe_source(jobs)
    inject_dir = os.path.join(root, "out", "_bao_inject")
    os.makedirs(inject_dir, exist_ok=True)
    probe = os.path.join(inject_dir, "BaoInjectProbe.sol")
    with open(probe, "w") as f:
        f.write(source)
    out_dir = os.path.join(inject_dir, "out")
    build = subprocess.run(
        ["forge", "build", probe, "--extra-output", "storageLayout", "--out", out_dir],
        cwd=root,
        capture_output=True,
        text=True,
    )
    if build.returncode != 0:
        laid_out = ", ".join(f"{path}:{contract}.{struct}" for _idx, path, contract, struct in jobs)
        sys.exit(f"storage-successor: the probe laying out {laid_out} did not build\n{build.stdout}\n{build.stderr}")
    layouts = {}
    for idx, name in names.items():
        with open(os.path.join(out_dir, "BaoInjectProbe.sol", f"{name}.json")) as f:
            layouts[idx] = json.load(f)["storageLayout"]
    return layouts


def check_builds(build_infos, root):
    """Check every bao-upgrade link in the build-infos. Return (checked_link_descriptions, failures).

    A contract is found by its source path and name, which name one contract in one compilation: the successor is
    the contract that carries the reference, and the predecessor is the contract at the path the reference names,
    found first in the successor's build-info and then in the others. A contract compiled in two build-infos (a
    file with a pragma range, pulled into two compilations) is checked once.

    Each side's namespaces and declarations are read from its own build-info, since syntax-tree ids are numbered
    for each compilation. The structs are laid out by one probe for each pair of build-infos the links' two sides
    come from: the files of one compilation compile together, and files pinned to two compiler versions do not."""
    contracts = [
        {(path, node.get("name")): node for path, node in _contracts(build_info)} for build_info in build_infos
    ]
    accessed_by_contract = [_accessed_namespaces_by_contract(build_info) for build_info in build_infos]
    struct_refs = [_struct_owner_and_ref(build_info)[1] for build_info in build_infos]
    structs_by_id = [_structs_by_id(build_info) for build_info in build_infos]
    jobs = {}  # (successor's build-info, predecessor's build-info) -> the structs to lay out in one probe
    plan, checked_once = [], set()
    idx = 0
    for succ_at, build_info in enumerate(build_infos):
        for succ_path, succ_contract, pred_path, pred_contract in _pairs(build_info):
            if (succ_path, succ_contract) in checked_once:
                continue
            checked_once.add((succ_path, succ_contract))
            succ_node = contracts[succ_at][(succ_path, succ_contract)]
            pred_at = next(
                (
                    at
                    for at in [succ_at] + [at for at in range(len(build_infos)) if at != succ_at]
                    if (pred_path, pred_contract) in contracts[at]
                ),
                None,
            )
            if pred_at is None:
                plan.append(
                    (succ_contract, pred_contract, None, [f"predecessor {pred_contract} ({pred_path}) not in build"])
                )
                continue
            pred_node = contracts[pred_at][(pred_path, pred_contract)]
            succ_ns = _namespaces(build_infos[succ_at], succ_node)
            pred_ns = _namespaces(build_infos[pred_at], pred_node)
            # A migrator that REACHES a predecessor namespace through a foreign struct (rather than declaring it) is
            # a PARTIAL successor: it touches only those namespaces, so the "gone" flag is suppressed for the ones it
            # never touches. A full successor (which declares its namespaces) has no accessed namespaces.
            accessed = accessed_by_contract[succ_at].get(succ_node.get("id"), {})
            is_partial = bool(accessed)
            errs = [
                f"namespace {ns} gone" for ns in pred_ns if ns not in succ_ns and ns not in accessed and not is_partial
            ]
            probe = jobs.setdefault((succ_at, pred_at), [])
            # declared namespaces: compare the successor's own struct
            for ns, struct in succ_ns.items():
                if ns not in pred_ns:
                    continue  # new namespace = new storage, allowed
                pi, si = idx, idx + 1
                idx += 2
                probe.append((pi, pred_path, pred_contract, pred_ns[ns]["name"]))
                probe.append((si, succ_path, succ_contract, struct["name"]))
                plan.append((succ_contract, pred_contract, ns, (pi, si, succ_at, struct["id"])))
            # accessed namespaces (partial migrator): compare the reached foreign struct against the predecessor's.
            # The reached struct is the real successor's (the pool's own, for a pool's migrator) and carries its own
            # declarations.
            for ns, struct_id in accessed.items():
                if ns not in pred_ns or ns in succ_ns:
                    continue
                acc_path, acc_contract, acc_struct = struct_refs[succ_at][struct_id]
                pi, si = idx, idx + 1
                idx += 2
                probe.append((pi, pred_path, pred_contract, pred_ns[ns]["name"]))
                probe.append((si, acc_path, acc_contract, acc_struct))
                plan.append((succ_contract, pred_contract, ns, (pi, si, succ_at, struct_id)))
            for pre_err in errs:
                plan.append((succ_contract, pred_contract, None, [pre_err]))

    layouts = {}
    for probe in jobs.values():
        if probe:
            layouts.update(_inject_layouts(probe, root))

    checked, failures = [], []
    for succ_contract, pred_contract, ns, data in plan:
        if isinstance(data, tuple):
            pi, si, succ_at, succ_struct_id = data
            declarations, errs = _link_declarations(succ_struct_id, structs_by_id[succ_at])
            if not errs:
                errs = successor_errors(layouts[pi], layouts[si], *declarations)
        else:
            errs = data
        checked.append(f"{succ_contract} <- {pred_contract} [{ns or '-'}]")
        if errs:
            failures.append((succ_contract, pred_contract, ns, errs))
    return checked, failures


def _compiled_build_infos(build_info_dir):
    """Every build-info in the folder that holds compiled output, in file-name order. forge writes one for each
    compiler version a build uses, so a link may be in any of them, and one with no compiled output for each later
    `forge inspect`, which is passed over. forge removes the old files when it rebuilds (seen with `--force`, as
    validate builds), so none of them is from an earlier build. A folder with none stops the run: every check would
    pass having checked nothing."""
    files = sorted(glob.glob(os.path.join(build_info_dir, "*.json")))
    if not files:
        sys.exit(f"storage-successor: no build-info json in {build_info_dir}")
    compiled = []
    for path in files:
        with open(path) as f:
            build_info = json.load(f)
        if "output" in build_info:
            compiled.append(build_info)
    if not compiled:
        sys.exit(f"storage-successor: no build-info in {build_info_dir} holds compiled output")
    return compiled


def _once(items):
    """The items in their order, each once: a file compiled in two build-infos gives its findings in both."""
    return list(dict.fromkeys(items))


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Verify @custom:bao-upgrades-from storage links are documented byte-compatible successors."
    )
    parser.add_argument("build_info_dir", help="the fresh build-info directory (validate's, or the test build's)")
    parser.add_argument("--root", default=".", help="project root (for the probe build)")
    parser.add_argument(
        "--list",
        action="store_true",
        help="print '<successor> <predecessor>' for each @custom:bao-upgrades-from link (no probe build) and exit — for validate's reference audit",
    )
    parser.add_argument(
        "--list-initializable",
        action="store_true",
        help="print '<source>:<Name>' for each contract inheriting OpenZeppelin's Initializable (no probe build) and exit — for validate's constructor check",
    )
    parser.add_argument(
        "--list-root-storage",
        action="store_true",
        help="print '<source>:<Name> <variable> slot <slot> offset <offset>' for each root variable (no probe build) and exit — for validate's namespace-only storage check",
    )
    args = parser.parse_args(argv)

    # every compiled build-info, not the latest: a repository using two solc versions has contracts in separate files
    build_infos = _compiled_build_infos(args.build_info_dir)
    if args.list_root_storage:
        for line in root_storage(build_infos):
            print(line)
        return 0
    if args.list:
        links = _once((succ_path, succ, pred) for b in build_infos for succ_path, succ, _pred_path, pred in _pairs(b))
        for _succ_path, succ, pred in links:
            print(f"{succ} {pred}")
        return 0
    if args.list_initializable:
        for contract in _once(contract for b in build_infos for contract in initializable_contracts(b)):
            print(contract)
        return 0

    checked, failures = check_builds(build_infos, args.root)
    # one ✓/✗ line per link, matching the rich style bin/doctor.py uses (markup=False: link strings
    # contain "[namespace]" which rich would otherwise read as markup)
    console = Console()
    details = {f"{s} <- {p} [{ns or '-'}]": errs for s, p, ns, errs in failures}
    if not checked:
        console.print("✓ no @custom:bao-upgrades-from storage links to check", style="green", markup=False)
    for link in checked:
        errs = details.get(link)
        if errs:
            console.print(f"✗ {link} — not a documented byte-compatible successor", style="bold red", markup=False)
            for e in errs:
                console.print(f"    {e}", style="red", markup=False)
        else:
            console.print(f"✓ {link}", style="green", markup=False)

    # every hardcoded namespace slot getter must set its `.slot` to the namespace's canonical ERC-7201 slot
    slot_errors = _once(error for b in build_infos for error in slot_getter_errors(b))
    for where, message in slot_errors:
        console.print(f"✗ {where} — {message}", style="bold red", markup=False)
    if not slot_errors:
        console.print("✓ hardcoded namespace slots verify against their ERC-7201 hashes", style="green", markup=False)

    # every @custom:bao-* tag must be one the tool recognizes (a misspelled tag would be silently skipped)
    bad_tags = _once(tag for b in build_infos for tag in unrecognized_bao_tags(b))
    for where, tag in bad_tags:
        console.print(
            f"✗ {where} — unrecognized tag @custom:{tag} (typo, or a bao tag with no implementation)",
            style="bold red",
            markup=False,
        )

    # every use of a recognized tag must be read as the declaration it is meant to be
    malformed = _once(report for b in build_infos for report in malformed_bao_tags(b))
    for where, message in malformed:
        console.print(f"✗ {where} — {message}", style="bold red", markup=False)

    return 1 if (failures or slot_errors or bad_tags or malformed) else 0


if __name__ == "__main__":
    sys.exit(main())
