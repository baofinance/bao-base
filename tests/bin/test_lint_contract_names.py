"""Two contracts compiled under one name is a silent hazard: forge writes both to
out/<file>.sol/<Contract>.json, so one artifact overwrites the other and every tool keyed on the bare
name then reads whichever survived. These tests pin the detector that finds it."""

import importlib.util
import json
import pathlib

import pytest


def load_module():
    module_path = pathlib.Path(__file__).resolve().parents[2] / "bin" / "lint-contract-names.py"
    spec = importlib.util.spec_from_file_location("lint_contract_names", module_path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)  # type: ignore[attr-defined]
    return module


def write_build_info(directory: pathlib.Path, name: str, contracts_by_path: dict[str, list[str]]):
    """One build-info file, in forge's shape: output.contracts maps source path -> contract names."""
    directory.mkdir(parents=True, exist_ok=True)
    payload = {"output": {"contracts": {path: {c: {} for c in names} for path, names in contracts_by_path.items()}}}
    (directory / f"{name}.json").write_text(json.dumps(payload))


def touch(root: pathlib.Path, *relative_paths: str):
    """Create the source files a build-info entry claims to describe."""
    for relative in relative_paths:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("// source")


def test_one_name_declared_by_two_paths_is_a_collision(tmp_path):
    module = load_module()
    touch(tmp_path, "src/a/Foo.sol", "src/b/Foo.sol")
    write_build_info(tmp_path / "out/build-info", "one", {"src/a/Foo.sol": ["Foo"], "src/b/Foo.sol": ["Foo"]})

    found = module.collisions(tmp_path / "out/build-info", root=tmp_path)

    assert found == {"Foo": ["src/a/Foo.sol", "src/b/Foo.sol"]}


def test_a_name_declared_once_is_not_a_collision(tmp_path):
    module = load_module()
    touch(tmp_path, "src/a/Foo.sol", "src/b/Bar.sol")
    write_build_info(tmp_path / "out/build-info", "one", {"src/a/Foo.sol": ["Foo"], "src/b/Bar.sol": ["Bar"]})

    assert module.collisions(tmp_path / "out/build-info", root=tmp_path) == {}


def test_every_colliding_path_is_reported_not_only_the_first_two(tmp_path):
    """The Chainlink feed libraries collide four ways; a report naming two of them is not actionable."""
    module = load_module()
    paths = ["src/feeds/arbitrum/USDE_USD.sol", "src/feeds/mainnet/USDE_USD.sol", "src/feeds/monad/USDE_USD.sol"]
    touch(tmp_path, *paths)
    write_build_info(tmp_path / "out/build-info", "one", {p: ["USDE_USD"] for p in paths})

    assert module.collisions(tmp_path / "out/build-info", root=tmp_path) == {"USDE_USD": sorted(paths)}


def test_a_source_that_no_longer_exists_is_not_a_collision(tmp_path):
    """build-info accumulates and never self-cleans, so a moved file leaves its old path behind. Without
    this filter, moving a file reports it as colliding with itself at its new path."""
    module = load_module()
    touch(tmp_path, "src/new/Foo.sol")  # src/old/Foo.sol was moved away and no longer exists
    write_build_info(tmp_path / "out/build-info", "stale", {"src/old/Foo.sol": ["Foo"]})
    write_build_info(tmp_path / "out/build-info", "fresh", {"src/new/Foo.sol": ["Foo"]})

    assert module.collisions(tmp_path / "out/build-info", root=tmp_path) == {}


def test_declarations_are_merged_across_build_info_files(tmp_path):
    """forge writes one build-info file per compilation unit, so the two halves of a collision routinely
    land in different files."""
    module = load_module()
    touch(tmp_path, "src/a/Foo.sol", "src/b/Foo.sol")
    write_build_info(tmp_path / "out/build-info", "first", {"src/a/Foo.sol": ["Foo"]})
    write_build_info(tmp_path / "out/build-info", "second", {"src/b/Foo.sol": ["Foo"]})

    assert module.collisions(tmp_path / "out/build-info", root=tmp_path) == {"Foo": ["src/a/Foo.sol", "src/b/Foo.sol"]}


def test_one_file_declaring_two_contracts_is_not_a_collision(tmp_path):
    module = load_module()
    touch(tmp_path, "src/a/Pair.sol")
    write_build_info(tmp_path / "out/build-info", "one", {"src/a/Pair.sol": ["First", "Second"]})

    assert module.collisions(tmp_path / "out/build-info", root=tmp_path) == {}


def test_a_missing_build_info_directory_is_an_error_not_an_empty_pass(tmp_path):
    """Reporting "no collisions" because nothing was built is the silent pass this check exists to
    remove: it would report success having examined nothing."""
    module = load_module()

    with pytest.raises(module.NothingToCheck):
        module.collisions(tmp_path / "out/build-info", root=tmp_path)


def test_an_empty_build_info_directory_is_an_error_not_an_empty_pass(tmp_path):
    module = load_module()
    (tmp_path / "out/build-info").mkdir(parents=True)

    with pytest.raises(module.NothingToCheck):
        module.collisions(tmp_path / "out/build-info", root=tmp_path)


def test_the_report_names_the_contract_and_all_of_its_paths(tmp_path):
    module = load_module()

    report = module.format_report({"Foo": ["src/a/Foo.sol", "src/b/Foo.sol"]})

    assert report.splitlines() == ["Foo", "    src/a/Foo.sol", "    src/b/Foo.sol"]


def test_the_report_for_no_collisions_is_empty(tmp_path):
    module = load_module()

    assert module.format_report({}) == ""


def test_a_collision_fails_the_run(tmp_path, monkeypatch):
    """Pass/fail, not a measurement: any collision is a defect, so there is no baseline to compare to."""
    module = load_module()
    touch(tmp_path, "src/a/Foo.sol", "src/b/Foo.sol")
    write_build_info(tmp_path / "out/build-info", "one", {"src/a/Foo.sol": ["Foo"], "src/b/Foo.sol": ["Foo"]})
    monkeypatch.chdir(tmp_path)

    assert module.main([]) == 1


def test_no_collisions_passes_the_run(tmp_path, monkeypatch):
    module = load_module()
    touch(tmp_path, "src/a/Foo.sol")
    write_build_info(tmp_path / "out/build-info", "one", {"src/a/Foo.sol": ["Foo"]})
    monkeypatch.chdir(tmp_path)

    assert module.main([]) == 0


def test_nothing_built_fails_the_run(tmp_path, monkeypatch):
    """Distinct from "no collisions": passing here would report success having examined nothing."""
    module = load_module()
    monkeypatch.chdir(tmp_path)

    assert module.main([]) == 1


def test_a_named_build_info_directory_is_used_instead_of_the_default(tmp_path, monkeypatch):
    """The slither target passes its own out directory, so the default must not be assumed."""
    module = load_module()
    touch(tmp_path, "src/a/Foo.sol", "src/b/Foo.sol")
    write_build_info(tmp_path / "out/slither/build-info", "one", {"src/a/Foo.sol": ["Foo"], "src/b/Foo.sol": ["Foo"]})
    monkeypatch.chdir(tmp_path)

    assert module.main(["out/slither/build-info"]) == 1
    assert module.main([]) == 1  # the default is absent here, which is an error, not a pass
