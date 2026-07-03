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
        ["forge", "build", fixture, "--build-info", "--build-info-path", str(out_dir), "--extra-output", "storageLayout"],
        cwd=ROOT, check=True, capture_output=True, text=True,
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


def test_all_pairs_were_checked(mixed):
    checked, _ = mixed
    assert len(checked) == 11, checked


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
