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


def _compare_type(a_id, a_types, b_id, b_types, path, errors, retyped, used, declared_old, added=None, is_root=False):
    """Recurse a matched type position. `retyped` = {structName: {field: oldTypeLabel}}; `added` =
    {structName: {field}}; `used` accumulates the (structName, field) declarations actually reached;
    `declared_old` is the declaration for THIS position (only meaningful on an integer leaf), or None;
    `is_root` marks the top-level namespace struct (which may grow, since nothing follows it)."""
    added = added or {}
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
        a_members = {m["label"]: m for m in a["members"]}
        b_members = {m["label"]: m for m in b["members"]}
        for label, ma in a_members.items():
            member_declared = declarations.get(label)
            if member_declared is not None:
                used.add((struct_name, label))  # the field exists in the predecessor, so the declaration is not a typo
            mb = b_members.get(label)
            if mb is None:
                errors.append(f"{path}.{label}: member removed")
                continue
            if str(ma["slot"]) != str(mb["slot"]) or ma["offset"] != mb["offset"]:
                errors.append(
                    f"{path}.{label}: member moved "
                    f"(slot {ma['slot']}:{ma['offset']} -> {mb['slot']}:{mb['offset']})"
                )
                continue
            _compare_type(ma["type"], a_types, mb["type"], b_types, f"{path}.{label}", errors, retyped, used, member_declared, added)
        # A new member is a byte-compatible APPEND when its bytes overlap no existing member (it takes storage the
        # predecessor never wrote) AND it relocates nothing: either the struct's size is unchanged (it packs into
        # the struct's own trailing padding — safe in any container, since the field after a struct starts a new
        # slot) or this is the top-level namespace struct (nothing follows it, so it may grow). Every accepted
        # append must be documented with `@custom:bao-added`, so no layout change is silent.
        occupied = _occupied_ranges(a["members"], a_types)
        grows = int(b["numberOfBytes"]) > int(a["numberOfBytes"])
        for label, mb in b_members.items():
            if label in a_members:
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
        _compare_type(a["value"], a_types, b["value"], b_types, f"{path}[k]", errors, retyped, used, None, added)

    elif ak == "array":
        if a["numberOfBytes"] != b["numberOfBytes"]:
            errors.append(f"{path}: array resized ({a['label']} {a['numberOfBytes']}B -> {b['label']} {b['numberOfBytes']}B)")
        _compare_type(a["base"], a_types, b["base"], b_types, f"{path}[i]", errors, retyped, used, None, added)

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


def successor_errors(a_layout, b_layout, retyped=None, added=None):
    """a_layout/b_layout: solc storageLayout dicts ({"storage", "types"}). retyped: {structName: {field:
    oldTypeLabel}} from `@custom:bao-retyped-from`; added: {structName: {field}} from `@custom:bao-added`.
    Return the list of changes that stop B being a documented byte-compatible successor of A (empty ==
    compatible)."""
    retyped = retyped or {}
    added = added or {}
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
        _compare_type(sa["type"], a_layout["types"], sb["type"], b_layout["types"], label, errors, retyped, used, None, added, is_root=True)
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


def _namespaces(contract_node):
    """namespace -> struct name for the contract's @custom:storage-location structs (annotation form only)."""
    out = {}
    for member in contract_node.get("nodes", []):
        if isinstance(member, dict) and member.get("nodeType") == "StructDefinition":
            m = _NAMESPACE.search(_doc(member))
            if m:
                out[m.group(1)] = member.get("name")
    return out


def _retyped(contract_node):
    """structName -> {field: oldTypeLabel} from `@custom:bao-retyped-from` on the contract's struct docs."""
    out = {}
    for member in contract_node.get("nodes", []):
        if isinstance(member, dict) and member.get("nodeType") == "StructDefinition":
            declarations = {field: old for field, old in _BAO_RETYPED.findall(_doc(member))}
            if declarations:
                out[member.get("name")] = declarations
    return out


def _added(contract_node):
    """structName -> {field} from `@custom:bao-added` on the contract's struct docs."""
    out = {}
    for member in contract_node.get("nodes", []):
        if isinstance(member, dict) and member.get("nodeType") == "StructDefinition":
            fields = set(_BAO_ADDED.findall(_doc(member)))
            if fields:
                out[member.get("name")] = fields
    return out


def _pairs(build_info):
    """Every bao-upgrade link to check: list of (succ_path, succ_contract, pred_path, pred_contract)."""
    found = []
    for succ_path, node in _contracts(build_info):
        m = _BAO_REF.search(_doc(node))
        if m:
            found.append((succ_path, node.get("name"), m.group(1), m.group(2)))
    return found


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
    for succ_path, succ_contract, pred_path, pred_contract in _pairs(build_info):
        _, succ_node = _contract_by_name(build_info, succ_contract)
        _, pred_node = _contract_by_name(build_info, pred_contract)
        if pred_node is None:
            plan.append((succ_contract, pred_contract, None, [f"predecessor {pred_contract} ({pred_path}) not in build"], None, None))
            continue
        succ_ns, pred_ns = _namespaces(succ_node), _namespaces(pred_node)
        succ_retyped = _retyped(succ_node)
        succ_added = _added(succ_node)
        errs = [f"namespace {ns} gone" for ns in pred_ns if ns not in succ_ns]
        for ns, struct in succ_ns.items():
            if ns not in pred_ns:
                continue  # new namespace = new storage, allowed
            pi, si = idx, idx + 1
            idx += 2
            jobs.append((pi, pred_path, pred_contract, pred_ns[ns]))
            jobs.append((si, succ_path, succ_contract, struct))
            plan.append((succ_contract, pred_contract, ns, (pi, si), succ_retyped, succ_added))
        for pre_err in errs:
            plan.append((succ_contract, pred_contract, None, [pre_err], None, None))

    layouts = _inject_layouts(jobs, root) if jobs else {}

    checked, failures = [], []
    for succ_contract, pred_contract, ns, data, succ_retyped, succ_added in plan:
        if isinstance(data, tuple):
            pi, si = data
            errs = successor_errors(layouts[pi], layouts[si], succ_retyped, succ_added)
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
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
