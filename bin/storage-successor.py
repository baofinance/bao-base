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
     erc7201:<ns>` struct(s), and the successor's `@custom:bao-retyped-from <field> <oldType>` declarations
     (both live in *struct-level* NatSpec, the only NatSpec solc preserves);
  3. INJECTS each namespaced struct as a plain state variable in a probe contract and builds it, so solc lays
     it out (a namespaced struct reached by assembly has no storageLayout otherwise);
  4. COMPARES the two layouts. The ONLY accepted change is an integer field widened in place — uintN->uintM /
     intN->intM, same sign, M > N, nothing relocated — AND documented with `@custom:bao-retyped-from <field>
     <oldType>` on the owning struct, whose <oldType> must equal the predecessor's type. Every other change is
     rejected: narrow, an UNDOCUMENTED widen, move, reorder, remove, add, kind-change, mapping-key-change,
     array-resize, and a stale or contradicted annotation. The walk recurses through structs, mappings, arrays
     (static and dynamic), and their arbitrary nestings, so a change buried inside `mapping(k => S[])` is found.

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
_BAO_REF = re.compile(r"custom:bao-upgrades-from\s+(\S+):([A-Za-z_]\w*)")
_BAO_RETYPED = re.compile(r"custom:bao-retyped-from\s+(\w+)\s+(u?int\d+)")
_BAO_ADDED = re.compile(r"custom:bao-added\s+(\w+)")
_BAO_RENAMED = re.compile(r"custom:bao-renamed-from\s+(\w+)\s+(\w+)")
# every `@custom:bao-*` tag this tool acts on — one per bao regex above. A `@custom:bao-*` tag NOT in this set
# is a typo or an unimplemented tag: solc accepts it (it is a valid custom tag) but the tool silently ignores it,
# so the intended check never runs and the change ships unverified. `unrecognized_bao_tags` catches that. When
# you add a new bao tag + its regex, add it here too.
_BAO_TAG = re.compile(r"custom:(bao-[a-z-]+)")
_RECOGNIZED_BAO_TAGS = frozenset({"bao-upgrades-from", "bao-retyped-from", "bao-added", "bao-renamed-from"})


# ── the successor rule (pure; unit-testable with synthetic storageLayout dicts + declarations) ──────────────

def _kind(type_def):
    if "members" in type_def:
        return "struct"
    if type_def.get("encoding") == "mapping":
        return "mapping"
    if "base" in type_def:
        return "array"  # dynamic_array, or a static (inplace) array — both carry `base`
    label = type_def["label"]
    if re.fullmatch(r"u?int\d+", label):
        return "integer"
    return "elementary"  # address, bool, bytesN, string, ... — must match exactly


def _struct_name(label):
    # "struct Scope.Name" or "struct Name" -> "Name"; matches a StructDefinition's AST `name`
    name = label[len("struct "):] if label.startswith("struct ") else label
    return name.rsplit(".", 1)[-1]


def _layout_struct_names(layout):
    return {_struct_name(t["label"]) for t in layout["types"].values() if "members" in t}


def _occupied_ranges(entries, types):
    """The byte ranges [start, end) that a list of storage entries (struct members or top-level slots) occupy.
    A new field is a byte-safe APPEND exactly when its range overlaps none of these — it takes storage the
    predecessor never wrote (former padding or fresh trailing slots), so a live proxy reads it zero."""
    ranges = []
    for e in entries:
        start = int(e["slot"]) * 32 + int(e["offset"])
        ranges.append((start, start + int(types[e["type"]]["numberOfBytes"])))
    return ranges


def _compare_type(a_id, a_types, b_id, b_types, path, errors, retyped, used, declared_old, added=None, renamed=None, is_root=False):
    """Recurse a matched type position. `retyped` = {structName: {field: oldTypeLabel}}; `added` =
    {structName: {field}}; `renamed` = {structName: {newField: oldField}}; `used` accumulates the
    (structName, field) declarations actually reached; `declared_old` is the declaration for THIS position
    (only meaningful on an integer leaf), or None; `is_root` marks the top-level namespace struct (which may
    grow, since nothing follows it)."""
    added = added or {}
    renamed = renamed or {}
    a, b = a_types[a_id], b_types[b_id]
    ak, bk = _kind(a), _kind(b)
    if ak != bk:
        errors.append(f"{path}: type kind changed ({a['label']} -> {b['label']})")
        return
    if declared_old is not None and ak != "integer":
        errors.append(f"{path}: @custom:bao-retyped-from declared on a non-integer field ({a['label']})")

    if ak == "struct":
        struct_name = _struct_name(a["label"])
        declarations = retyped.get(struct_name, {})
        added_here = added.get(struct_name, set())
        renames = renamed.get(struct_name, {})  # {newLabel: oldLabel} — a documented member rename
        old_to_new = {old: new for new, old in renames.items()}
        a_members = {m["label"]: m for m in a["members"]}
        b_members = {m["label"]: m for m in b["members"]}
        matched_b = set()  # successor members consumed by a predecessor match; the rest are candidate appends
        for label, ma in a_members.items():
            member_declared = declarations.get(label)
            if member_declared is not None:
                used.add((struct_name, label))  # the field exists in the predecessor, so the declaration is not a typo
            # A documented rename for this field takes precedence over same-name matching WHEN its new name is
            # present in the successor: an upgrade may free a name and reuse it for a different field, so
            # `label` in the predecessor and `label` in the successor can be different fields. Only when the
            # rename target is absent do we fall back to same-name matching (which keeps a stale rename a failure).
            mb = None
            if label in old_to_new:
                new_label = old_to_new[label]  # a documented rename maps this predecessor field to a new name
                mb = b_members.get(new_label)
                if mb is not None:
                    used.add((struct_name, new_label))  # the rename was applied (new name present)
            if mb is None:
                mb = b_members.get(label)
            if mb is None:
                errors.append(f"{path}.{label}: member removed")
                continue
            matched_b.add(mb["label"])
            if str(ma["slot"]) != str(mb["slot"]) or ma["offset"] != mb["offset"]:
                errors.append(
                    f"{path}.{label}: member moved "
                    f"(slot {ma['slot']}:{ma['offset']} -> {mb['slot']}:{mb['offset']})"
                )
                continue
            _compare_type(ma["type"], a_types, mb["type"], b_types, f"{path}.{label}", errors, retyped, used, member_declared, added, renamed)
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
                errors.append(f"{path}.{label}: undocumented add; annotate the owning struct `@custom:bao-added {label}`")
            else:
                used.add((struct_name, label))  # documented, byte-compatible append

    elif ak == "mapping":
        if a_types[a["key"]]["label"] != b_types[b["key"]]["label"]:
            errors.append(f"{path}: mapping key changed ({a_types[a['key']]['label']} -> {b_types[b['key']]['label']})")
        _compare_type(a["value"], a_types, b["value"], b_types, f"{path}[k]", errors, retyped, used, None, added, renamed)

    elif ak == "array":
        if a["numberOfBytes"] != b["numberOfBytes"]:
            errors.append(f"{path}: array resized ({a['label']} {a['numberOfBytes']}B -> {b['label']} {b['numberOfBytes']}B)")
        _compare_type(a["base"], a_types, b["base"], b_types, f"{path}[i]", errors, retyped, used, None, added, renamed)

    elif ak == "integer":
        a_signed, b_signed = not a["label"].startswith("u"), not b["label"].startswith("u")
        a_size, b_size = int(a["numberOfBytes"]), int(b["numberOfBytes"])
        if a_signed != b_signed:
            errors.append(f"{path}: signedness changed ({a['label']} -> {b['label']})")
        elif b_size < a_size:
            errors.append(f"{path}: integer narrowed ({a['label']} -> {b['label']})")
        elif b_size > a_size:
            # a widen — safe in bytes (any displacement would have moved a following member, caught above),
            # but only allowed when the developer documented it and the declared old type is the real one.
            if declared_old is None:
                errors.append(f"{path}: undocumented widen ({a['label']} -> {b['label']}); add `@custom:bao-retyped-from <field> {a['label']}` to the owning struct")
            elif declared_old != a["label"]:
                errors.append(f"{path}: declared `@custom:bao-retyped-from ... {declared_old}` but predecessor is {a['label']}")
        else:  # same size, same sign: unchanged
            if declared_old is not None:
                errors.append(f"{path}: stale `@custom:bao-retyped-from ... {declared_old}` — {a['label']} is unchanged")

    else:  # elementary — must be identical
        if a["label"] != b["label"]:
            errors.append(f"{path}: type changed ({a['label']} -> {b['label']})")


def successor_errors(a_layout, b_layout, retyped=None, added=None, renamed=None):
    """a_layout/b_layout: solc storageLayout dicts ({"storage", "types"}). retyped: {structName: {field:
    oldTypeLabel}} from `@custom:bao-retyped-from`; added: {structName: {field}} from `@custom:bao-added`;
    renamed: {structName: {newField: oldField}} from `@custom:bao-renamed-from`. Return the list of changes
    that stop B being a documented byte-compatible successor of A (empty == compatible)."""
    retyped = retyped or {}
    added = added or {}
    renamed = renamed or {}
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
            errors.append(f"{label}: top-level slot moved (slot {sa['slot']}:{sa['offset']} -> {sb['slot']}:{sb['offset']})")
            continue
        _compare_type(sa["type"], a_layout["types"], sb["type"], b_layout["types"], label, errors, retyped, used, None, added, renamed, is_root=True)
    for label in b_by_label:
        if label not in a_by_label:
            errors.append(f"{label}: top-level slot added (not yet allowed)")
    # a declaration that names a struct present in this layout but a field that was never reached is stale
    # (a typo, or a field that didn't actually change); declarations for other layouts' structs are ignored here.
    present = _layout_struct_names(a_layout) | _layout_struct_names(b_layout)
    for struct_name, fields in retyped.items():
        if struct_name not in present:
            continue
        for field in fields:
            if (struct_name, field) not in used:
                errors.append(f"{struct_name}.{field}: `@custom:bao-retyped-from` names a field not found in the struct")
    for struct_name, fields in added.items():
        if struct_name not in present:
            continue
        for field in fields:
            if (struct_name, field) not in used:
                errors.append(f"{struct_name}.{field}: `@custom:bao-added` names a field that was not added")
    for struct_name, new_fields in renamed.items():
        if struct_name not in present:
            continue
        for new_field in new_fields:
            if (struct_name, new_field) not in used:
                errors.append(f"{struct_name}.{new_field}: `@custom:bao-renamed-from` names a field that was not renamed")
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


def _contract_by_name(build_info, name):
    for path, node in _contracts(build_info):
        if node.get("name") == name:
            return path, node
    return None, None


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
    """namespace -> struct name for the @custom:storage-location structs of the contract and its bases."""
    out = {}
    for member in _inherited_structs(build_info, contract_node):
        m = _NAMESPACE.search(_doc(member))
        if m:
            out.setdefault(m.group(1), member.get("name"))  # most-derived wins (linearized is derived-first)
    return out


def _retyped(build_info, contract_node):
    """structName -> {field: oldTypeLabel} from `@custom:bao-retyped-from` across the contract and its bases."""
    out = {}
    for member in _inherited_structs(build_info, contract_node):
        declarations = {field: old for field, old in _BAO_RETYPED.findall(_doc(member))}
        if declarations:
            out.setdefault(member.get("name"), declarations)
    return out


def _added(build_info, contract_node):
    """structName -> {field} from `@custom:bao-added` across the contract and its bases."""
    out = {}
    for member in _inherited_structs(build_info, contract_node):
        fields = set(_BAO_ADDED.findall(_doc(member)))
        if fields:
            out.setdefault(member.get("name"), fields)
    return out


def _renamed(build_info, contract_node):
    """structName -> {newField: oldField} from `@custom:bao-renamed-from` across the contract and its bases."""
    out = {}
    for member in _inherited_structs(build_info, contract_node):
        renames = {new: old for new, old in _BAO_RENAMED.findall(_doc(member))}
        if renames:
            out.setdefault(member.get("name"), renames)
    return out


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
            errors.append((where, f"slot constant {slot_const.get('name')} = {actual} != erc7201({namespace}) = {expected}"))
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
    chains = {contract["id"]: set(contract.get("linearizedBaseContracts", [contract["id"]]))
              for _path, contract in _contracts(build_info)}
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
    """Yield (where, doc_text) for every documented declaration — file-level nodes and contract members — since
    a `@custom:bao-*` tag can sit on a contract, a struct, or a state-variable constant."""
    for path, src in build_info.get("output", {}).get("sources", {}).items():
        ast = src.get("ast")
        if not isinstance(ast, dict):
            continue
        for node in ast.get("nodes", []):
            if not isinstance(node, dict):
                continue
            name = node.get("name") or os.path.basename(path)
            if _doc(node):
                yield name, _doc(node)
            for member in node.get("nodes", []):
                if isinstance(member, dict) and _doc(member):
                    yield f"{name}.{member.get('name')}", _doc(member)


def unrecognized_bao_tags(build_info):
    """Every `@custom:bao-*` tag that the tool does not recognize (a typo, or a tag with no implementation).
    Return list of (where, tag), deduplicated."""
    out = []
    seen = set()
    for where, text in _documented_nodes(build_info):
        for tag in _BAO_TAG.findall(text):
            if tag not in _RECOGNIZED_BAO_TAGS and (where, tag) not in seen:
                seen.add((where, tag))
                out.append((where, tag))
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
    """Build one probe for all jobs; return {index: storageLayout dict}."""
    source, names = probe_source(jobs)
    inject_dir = os.path.join(root, "out", "_bao_inject")
    os.makedirs(inject_dir, exist_ok=True)
    probe = os.path.join(inject_dir, "BaoInjectProbe.sol")
    with open(probe, "w") as f:
        f.write(source)
    out_dir = os.path.join(inject_dir, "out")
    build = subprocess.run(
        ["forge", "build", probe, "--extra-output", "storageLayout", "--out", out_dir],
        cwd=root, capture_output=True, text=True,
    )
    if build.returncode != 0:
        sys.exit(f"storage-successor: probe build failed\n{build.stdout}\n{build.stderr}")
    layouts = {}
    for idx, name in names.items():
        with open(os.path.join(out_dir, "BaoInjectProbe.sol", f"{name}.json")) as f:
            layouts[idx] = json.load(f)["storageLayout"]
    return layouts


def check_build(build_info, root):
    """Check every bao-upgrade link in the build-info. Return (checked_link_descriptions, failures)."""
    jobs, plan = [], []
    idx = 0
    accessed_by_contract = _accessed_namespaces_by_contract(build_info)
    _owner, struct_ref = _struct_owner_and_ref(build_info)
    for succ_path, succ_contract, pred_path, pred_contract in _pairs(build_info):
        _, succ_node = _contract_by_name(build_info, succ_contract)
        _, pred_node = _contract_by_name(build_info, pred_contract)
        if pred_node is None:
            plan.append((succ_contract, pred_contract, None, [f"predecessor {pred_contract} ({pred_path}) not in build"], None, None, None))
            continue
        succ_ns, pred_ns = _namespaces(build_info, succ_node), _namespaces(build_info, pred_node)
        succ_retyped = _retyped(build_info, succ_node)
        succ_added = _added(build_info, succ_node)
        succ_renamed = _renamed(build_info, succ_node)
        # A migrator that REACHES a predecessor namespace through a foreign struct (rather than declaring it) is a
        # PARTIAL successor: it touches only those namespaces, so the "gone" flag is suppressed for the ones it never
        # touches. A full successor (which declares its namespaces) has no accessed namespaces and behaves as before.
        accessed = accessed_by_contract.get(succ_node.get("id"), {})
        is_partial = bool(accessed)
        errs = [f"namespace {ns} gone" for ns in pred_ns if ns not in succ_ns and ns not in accessed and not is_partial]
        # declared namespaces: compare the successor's own struct
        for ns, struct in succ_ns.items():
            if ns not in pred_ns:
                continue  # new namespace = new storage, allowed
            pi, si = idx, idx + 1
            idx += 2
            jobs.append((pi, pred_path, pred_contract, pred_ns[ns]))
            jobs.append((si, succ_path, succ_contract, struct))
            plan.append((succ_contract, pred_contract, ns, (pi, si), succ_retyped, succ_added, succ_renamed))
        # accessed namespaces (partial migrator): compare the reached foreign struct against the predecessor's,
        # using the OWNER contract's change annotations (the reached struct is the real successor's, e.g. SP_v3's)
        for ns, struct_id in accessed.items():
            if ns not in pred_ns or ns in succ_ns:
                continue
            acc_path, acc_contract, acc_struct = struct_ref[struct_id]
            _, owner_node = _contract_by_name(build_info, acc_contract)
            pi, si = idx, idx + 1
            idx += 2
            jobs.append((pi, pred_path, pred_contract, pred_ns[ns]))
            jobs.append((si, acc_path, acc_contract, acc_struct))
            plan.append((succ_contract, pred_contract, ns, (pi, si),
                         _retyped(build_info, owner_node), _added(build_info, owner_node), _renamed(build_info, owner_node)))
        for pre_err in errs:
            plan.append((succ_contract, pred_contract, None, [pre_err], None, None, None))

    layouts = _inject_layouts(jobs, root) if jobs else {}

    checked, failures = [], []
    for succ_contract, pred_contract, ns, data, succ_retyped, succ_added, succ_renamed in plan:
        if isinstance(data, tuple):
            pi, si = data
            errs = successor_errors(layouts[pi], layouts[si], succ_retyped, succ_added, succ_renamed)
        else:
            errs = data
        checked.append(f"{succ_contract} <- {pred_contract} [{ns or '-'}]")
        if errs:
            failures.append((succ_contract, pred_contract, ns, errs))
    return checked, failures


def _latest_build_info(build_info_dir):
    files = glob.glob(os.path.join(build_info_dir, "*.json"))
    if not files:
        sys.exit(f"storage-successor: no build-info json in {build_info_dir}")
    with open(max(files, key=os.path.getmtime)) as f:
        return json.load(f)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Verify @custom:bao-upgrades-from storage links are documented byte-compatible successors.")
    parser.add_argument("build_info_dir", help="the fresh build-info directory (validate's, or the test build's)")
    parser.add_argument("--root", default=".", help="project root (for the probe build)")
    parser.add_argument("--list", action="store_true", help="print '<successor> <predecessor>' for each @custom:bao-upgrades-from link (no probe build) and exit — for validate's reference audit")
    args = parser.parse_args(argv)

    build_info = _latest_build_info(args.build_info_dir)
    if args.list:
        for _succ_path, succ, _pred_path, pred in _pairs(build_info):
            print(f"{succ} {pred}")
        return 0

    checked, failures = check_build(build_info, args.root)
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
    slot_errors = slot_getter_errors(build_info)
    for where, message in slot_errors:
        console.print(f"✗ {where} — {message}", style="bold red", markup=False)
    if not slot_errors:
        console.print("✓ hardcoded namespace slots verify against their ERC-7201 hashes", style="green", markup=False)

    # every @custom:bao-* tag must be one the tool recognizes (a misspelled tag would be silently skipped)
    bad_tags = unrecognized_bao_tags(build_info)
    for where, tag in bad_tags:
        console.print(f"✗ {where} — unrecognized tag @custom:{tag} (typo, or a bao tag with no implementation)", style="bold red", markup=False)

    return 1 if (failures or slot_errors or bad_tags) else 0


if __name__ == "__main__":
    sys.exit(main())
