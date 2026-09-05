"""End-to-end test for bin/storage-successor.py over REAL solc output.

The harness builds the .sol fixtures exactly as validate builds src (a fresh build-info), then runs the
production check_build / main on them — no re-implementation of extract/inject/build, so the very code that
ships is the code under test. The documented widens (flat and nested-through-containers) must pass; every
other pair must be rejected with the right reason. This also anchors the synthetic-input rule tests in
test_storage_successor.py: if their layout shape ever diverged from solc's, the verdicts here would break.

Skipped if forge is unavailable (the only integration tests in bin/ that need a build).
"""

import importlib.util
import pathlib
import shutil
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[2]  # bao-base root
FIXTURES = "test/fixtures/BaoUpgradeFixtures.sol"
GOOD = "test/fixtures/BaoUpgradeGood.sol"


def load_module():
    module_path = ROOT / "bin" / "storage-successor.py"
    spec = importlib.util.spec_from_file_location("storage_successor", module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def build_info_dir(fixture, subdir):
    """Build one fixture file with a fresh build-info (as validate builds src); return the build-info dir."""
    out_dir = ROOT / "out" / subdir / "build-info"
    subprocess.run(
        [
            "forge",
            "build",
            fixture,
            "--build-info",
            "--build-info-path",
            str(out_dir),
            "--extra-output",
            "storageLayout",
        ],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return out_dir


@pytest.fixture(scope="module")
def mixed():
    if shutil.which("forge") is None:
        pytest.skip("forge not available")
    mod = load_module()
    build_info = mod._latest_build_info(str(build_info_dir(FIXTURES, "_bao_test_mixed")))
    checked, failures = mod.check_build(build_info, str(ROOT))
    return checked, {succ: errs for succ, pred, ns, errs in failures}


@pytest.fixture(scope="module")
def mixed_build():
    """The raw (module, build_info) for the mixed fixtures — for unit-testing the AST-analysis internals directly."""
    if shutil.which("forge") is None:
        pytest.skip("forge not available")
    mod = load_module()
    return mod, mod._latest_build_info(str(build_info_dir(FIXTURES, "_bao_test_mixed")))


def _contract_id(mod, build_info, name):
    for _path, c in mod._contracts(build_info):
        if c.get("name") == name:
            return c["id"]
    raise AssertionError(f"{name} not in build")


def test_namespace_getter_detected_for_reached_foreign_struct(mixed_build):
    # PartialMigrator._a() reaches test.partial.a through PartialSucc's struct (defined outside its inheritance);
    # the getter detector must yield that (contract, function, namespace) triple so the partial check can find it
    mod, build_info = mixed_build
    getters = [(c.get("name"), fn.get("name"), ns) for c, fn, ns, _sid, _slot in mod._namespace_getters(build_info)]
    assert ("PartialMigrator", "_a", "test.partial.a") in getters, getters


def test_accessed_map_lists_only_reached_foreign_namespaces(mixed_build):
    # a partial migrator's access map is exactly the namespaces it REACHES via a foreign struct (test.partial.a),
    # never a predecessor namespace it does not touch (test.partial.b); and the reached struct is the foreign one
    mod, build_info = mixed_build
    accessed = mod._accessed_namespaces_by_contract(build_info)
    mig = accessed.get(_contract_id(mod, build_info, "PartialMigrator"), {})
    assert set(mig) == {"test.partial.a"}, mig
    owner, _ref = mod._struct_owner_and_ref(build_info)
    assert owner[mig["test.partial.a"]] == _contract_id(mod, build_info, "PartialSucc"), "reached struct is not foreign"


def test_contract_declaring_its_own_namespace_is_absent_from_accessed_map(mixed_build):
    # a getter that returns a struct declared in its OWN inheritance chain is not "accessing" a foreign namespace,
    # so it must not appear in the access map (only reached-foreign structs make a contract a partial migrator)
    mod, build_info = mixed_build
    accessed = mod._accessed_namespaces_by_contract(build_info)
    assert _contract_id(mod, build_info, "SlotGetterGood") not in accessed


def test_all_pairs_were_checked(mixed):
    checked, _ = mixed
    assert len(checked) == 16, checked


@pytest.mark.parametrize("succ", ["WidenSucc", "NestGoodSucc"])
def test_documented_widen_pairs_pass(mixed, succ):
    checked, failures = mixed
    assert any(succ in c for c in checked), f"{succ} was not even checked"
    assert succ not in failures, failures.get(succ)


@pytest.mark.parametrize(
    "succ,needle",
    [
        ("UndocSucc", "undocumented widen"),
        ("NarrowSucc", "narrowed"),
        ("MoveSucc", "moved"),
        ("OverflowSucc", "moved"),
        ("KindSucc", "kind changed"),
        ("RemoveSucc", "removed"),
        ("AddSucc", "added"),
        ("KeySucc", "mapping key"),
        ("NestBadSucc", "undocumented widen"),
    ],
)
def test_bad_pair_is_rejected(mixed, succ, needle):
    _, failures = mixed
    assert succ in failures, f"{succ} should have been rejected"
    assert any(needle in e for e in failures[succ]), failures[succ]


def test_inherited_bad_change_is_rejected(mixed):
    # the namespace is declared in an inherited base; the tool must walk the inheritance chain to compare it,
    # otherwise this undocumented widen is silently not checked
    _, failures = mixed
    assert "InheritBadSucc" in failures, "an undocumented widen in an inherited namespace was not caught"
    assert any("undocumented widen" in e for e in failures["InheritBadSucc"]), failures["InheritBadSucc"]


def test_inherited_documented_rename_passes(mixed):
    # a documented rename in an inherited namespace must be reached (walked) AND accepted
    checked, failures = mixed
    assert any("InheritRenameSucc" in c for c in checked), "the inherited-namespace pair was not even checked"
    assert "InheritRenameSucc" not in failures, failures.get("InheritRenameSucc")


def test_missing_predecessor_is_reported(mixed):
    # a @custom:bao-upgrades-from naming a predecessor absent from the build must fail loudly, not be skipped
    _, failures = mixed
    assert "MissingPredSucc" in failures, "a dangling bao-upgrades-from reference was silently skipped"
    assert any("not in build" in e for e in failures["MissingPredSucc"]), failures["MissingPredSucc"]


def test_dropped_namespace_is_reported(mixed):
    # dropping a @custom:storage-location the predecessor declared loses that storage's layout — must be rejected
    _, failures = mixed
    assert "NamespaceGoneSucc" in failures, "a dropped namespace was not caught"
    assert any("gone" in e for e in failures["NamespaceGoneSucc"]), failures["NamespaceGoneSucc"]


def test_partial_migrator_compatible_namespace_passes(mixed):
    # a light migrator reaching a namespace via ANOTHER contract's struct (@custom:bao-upgrades-from, but declares
    # no namespaces of its own) must have that reached struct byte-compared to the predecessor, and must NOT be
    # flagged for the predecessor namespaces (test.partial.b) it never touches
    _, failures = mixed
    assert "PartialMigrator" not in failures, failures.get("PartialMigrator")


def test_list_mode_prints_each_link_and_exits_0(capsys):
    # --list (used by validate's version-reference audit) prints '<successor> <predecessor>' per link, no build
    if shutil.which("forge") is None:
        pytest.skip("forge not available")
    mod = load_module()
    d = build_info_dir(GOOD, "_bao_test_good")
    assert mod.main([str(d), "--list"]) == 0
    assert capsys.readouterr().out == "GoodSucc GoodPred\n"


def test_build_with_no_bao_upgrade_links_is_clean():
    # the zero-pair case (most builds have none): check_build lays nothing out and returns no failures, so main
    # exits 0. Synthetic build-info (no solc needed) — a build whose sources declare no @custom:bao-upgrades-from.
    mod = load_module()
    assert mod.check_build({"output": {"sources": {}}}, ".") == ([], [])


@pytest.fixture(scope="module")
def slot_errors():
    """slot_getter_errors over the mixed fixture build, keyed by the getter's `Contract.function` (shells to `cast`)."""
    if shutil.which("forge") is None:
        pytest.skip("forge not available")
    mod = load_module()
    build_info = mod._latest_build_info(str(build_info_dir(FIXTURES, "_bao_test_mixed")))
    return {where: msg for where, msg in mod.slot_getter_errors(build_info)}


def test_correct_slot_getter_passes(slot_errors):
    # a getter whose hardcoded slot equals its namespace's ERC-7201 hash is auto-detected and NOT flagged
    assert not any(w.startswith("SlotGetterGood.") for w in slot_errors), slot_errors


def test_wrong_slot_getter_is_rejected(slot_errors):
    # the getter reaches test.slotgetter.bad but hardcodes test.slotgetter.good's slot -> auto-detected mismatch
    bad = [msg for w, msg in slot_errors.items() if w.startswith("SlotGetterWrong.")]
    assert bad, "a getter whose hardcoded slot mismatches its namespace was not caught"
    assert any("!=" in m for m in bad), bad


def test_misspelled_bao_tag_is_rejected():
    # a typo'd @custom:bao-* tag compiles but matches no regex — it must be flagged, not silently ignored,
    # and the many legitimate bao tags across the fixtures must NOT be false-flagged alongside it
    if shutil.which("forge") is None:
        pytest.skip("forge not available")
    mod = load_module()
    build_info = mod._latest_build_info(str(build_info_dir(FIXTURES, "_bao_test_mixed")))
    tags = {tag for _where, tag in mod.unrecognized_bao_tags(build_info)}
    assert "bao-renamd-from" in tags, "a misspelled @custom:bao-* tag was not caught"
    assert not (
        tags & {"bao-upgrades-from", "bao-retyped-from", "bao-added", "bao-renamed-from", "bao-storage-slot"}
    ), tags


def test_main_exits_1_when_any_link_is_incompatible():
    if shutil.which("forge") is None:
        pytest.skip("forge not available")
    mod = load_module()
    d = build_info_dir(FIXTURES, "_bao_test_mixed")
    assert mod.main([str(d), "--root", str(ROOT)]) == 1


def test_main_exits_0_when_all_links_are_documented_successors():
    if shutil.which("forge") is None:
        pytest.skip("forge not available")
    mod = load_module()
    d = build_info_dir(GOOD, "_bao_test_good")
    assert mod.main([str(d), "--root", str(ROOT)]) == 0
