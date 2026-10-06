"""End-to-end tests for bin/upgrade-references.py over REAL OpenZeppelin output.

The rule: only the latest version of each upgradeable family must name its predecessor, so an older
version can be parked once the annotation naming it is deleted; any annotation that is present must
name its own family, and a version carries at most one.

The harness builds the fixture families exactly as validate builds src (a fresh build-info), runs
OpenZeppelin upgrades-core validate and `storage-successor --list` on it as validate does, then runs the
production main on their output with `--scope` set to one fixture file — so each test audits one family
in isolation, and the report format the script parses is the one OpenZeppelin actually writes.

Skipped if forge is unavailable.
"""

import importlib.util
import pathlib
import shutil
import subprocess
import sys

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[2]  # bao-base root
FIXTURES = "test/fixtures/upgrade-references"
OUT = ROOT / "out" / "_upgrade_references"


def load_module():
    module_path = ROOT / "bin" / "upgrade-references.py"
    spec = importlib.util.spec_from_file_location("upgrade_references", module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


mod = load_module()


@pytest.fixture(scope="module")
def inputs():
    """The OpenZeppelin report and bao-link list for a fresh build of every fixture family."""
    if shutil.which("forge") is None:
        pytest.skip("forge not available")
    build_info = OUT / "build-info"
    subprocess.run(
        [
            "forge",
            "build",
            FIXTURES,
            "--force",
            "--out",
            str(OUT),
            "--cache-path",
            str(ROOT / "cache" / "_upgrade_references"),
            "--build-info",
            "--build-info-path",
            str(build_info),
            "--extra-output",
            "storageLayout",
        ],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    # OpenZeppelin itself must accept every fixture: each one is a failure of THIS audit only
    report = subprocess.run(
        ["npx", "@openzeppelin/upgrades-core", "validate", str(build_info)],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    bao_links = subprocess.run(
        [sys.executable, str(ROOT / "bin" / "storage-successor.py"), str(build_info), "--list"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    (OUT / "oz-validate.txt").write_text(report)
    (OUT / "bao-upgrade-links.txt").write_text(bao_links)
    return OUT / "oz-validate.txt", OUT / "bao-upgrade-links.txt"


def audit(inputs, scope):
    report, bao_links = inputs
    return mod.main([str(report), "--bao-links", str(bao_links), "--scope", scope])


def failed_lines(output):
    return [line for line in output.splitlines() if "✘" in line]


def test_middle_version_without_annotation_passes(inputs, capsys):
    # a parked predecessor leaves the middle version unannotated; only the latest must name one
    assert audit(inputs, f"{FIXTURES}/MiddleUnannotated.sol") == 0
    output = capsys.readouterr().out
    assert failed_lines(output) == []
    assert "MiddleUnannotated_v3 upgrades from MiddleUnannotated_v2" in output


def test_latest_version_without_annotation_fails(inputs, capsys):
    # the latest version's layout would never be checked against the version before it
    assert audit(inputs, f"{FIXTURES}/LatestUnannotated.sol") == 1
    failures = failed_lines(capsys.readouterr().out)
    assert len(failures) == 1
    assert "LatestUnannotated_v3: no @custom:oz-upgrades-from" in failures[0]


def test_older_version_may_keep_its_annotation(inputs, capsys):
    # keeping an older version's annotation is allowed, as long as what it names still resolves
    assert audit(inputs, f"{FIXTURES}/AllAnnotated.sol") == 0
    output = capsys.readouterr().out
    assert failed_lines(output) == []
    assert "AllAnnotated_v2 upgrades from AllAnnotated_v1" in output
    assert "AllAnnotated_v3 upgrades from AllAnnotated_v2" in output


def test_annotation_naming_another_family_fails_on_any_version(inputs, capsys):
    # the form check applies to every annotation present, not only the latest version's
    assert audit(inputs, f"{FIXTURES}/ForeignMiddle.sol") == 1
    failures = failed_lines(capsys.readouterr().out)
    assert len(failures) == 1
    assert "ForeignMiddle_v2: @custom:oz-upgrades-from references a non-ForeignMiddle_v* contract" in failures[0]


def test_both_annotations_fail_on_any_version(inputs, capsys):
    # a version carries exactly one annotation, whichever version it is
    assert audit(inputs, f"{FIXTURES}/BothMiddle.sol") == 1
    failures = failed_lines(capsys.readouterr().out)
    assert len(failures) == 1
    assert "BothMiddle_v2: declares BOTH" in failures[0]


def test_contract_outside_scope_is_not_audited(inputs, capsys):
    # validate scopes the audit to src/, so a fixture's unannotated latest version is not audited there
    assert audit(inputs, "src/") == 0
    assert failed_lines(capsys.readouterr().out) == []


def test_single_version_family_needs_no_annotation(inputs, capsys):
    # a first version has no predecessor to name
    assert audit(inputs, f"{FIXTURES}/SingleVersion.sol") == 0
    assert failed_lines(capsys.readouterr().out) == []


def test_report_whose_count_disagrees_with_its_lines_is_refused(tmp_path):
    # a change in the report's format must stop the audit, not leave it reading nothing and passing
    report = tmp_path / "oz-validate.txt"
    report.write_text(" ✔  src/Foo_v2.sol:Foo_v2\n\nSUCCESS (2 upgradeable contracts detected, 2 passed, 0 failed)\n")
    bao_links = tmp_path / "bao-upgrade-links.txt"
    bao_links.write_text("")
    with pytest.raises(SystemExit, match="reports 2 upgradeable contracts but 1 contract lines"):
        mod.main([str(report), "--bao-links", str(bao_links), "--scope", "src/"])
