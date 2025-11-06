import importlib.util
import pathlib
import textwrap


def load_module():
    module_path = pathlib.Path(__file__).resolve().parents[2] / "bin" / "extract-coverage.py"
    spec = importlib.util.spec_from_file_location("extract_coverage", module_path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)  # type: ignore[attr-defined]
    return module


def sample_table() -> str:
    return textwrap.dedent(
        """
        | File | % Lines | % Statements | % Branches | % Funcs |
        |------+---------+--------------+------------+---------|
        | script/examples/ExampleProductionDeployment.s.sol | 0% (0/8) | 0% (0/7) | 100% (0/0) | 0% (0/3) |
        | script/deployment/Deployment.sol | 87% (118/136) | 89% (128/144) | 50% (14/28) | 84% (16/19) |
        | src/BaoOwnable.sol | 100% (27/27) | 100% (24/24) | 100% (3/3) | 100% (6/6) |
        | Total | 80% (1722/2151) | 83% (1671/2002) | 57% (149/261) | 70% (362/514) |
        """
    ).strip()


def test_to_named_dataframe_formats_percentages_with_markers():
    module = load_module()
    df, path = module.toNamedDataFrame(sample_table())

    assert path == ""
    assert list(df.columns) == ["File", "% Lines", "% Statements", "% Branches", "% Funcs"]

    expected_files = [
        "script/deployment/Deployment.sol",
        "src/BaoOwnable.sol",
        "Total",
    ]
    assert list(df["File"]) == expected_files
    assert all(not name.endswith(".s.sol") for name in df["File"])

    script_lines = df.loc[df["File"] == "script/deployment/Deployment.sol", "% Lines"].iat[0]
    assert script_lines.startswith("X")
    assert "87%" in script_lines
    assert script_lines.endswith("(118/136)")

    src_lines = df.loc[df["File"] == "src/BaoOwnable.sol", "% Lines"].iat[0]
    assert src_lines.startswith("✓")
    assert src_lines == "✓ 100% (27/27)"

    total_branches = df.loc[df["File"] == "Total", "% Branches"].iat[0]
    assert total_branches.startswith("X")
    assert "57%" in total_branches
    assert total_branches.endswith("(149/261)")


if __name__ == "__main__":
    raise SystemExit("Run this test with pytest or python -m pytest")
