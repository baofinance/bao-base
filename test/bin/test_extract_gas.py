import importlib.util
import pathlib
import textwrap

import pytest


def load_module():
    module_path = pathlib.Path(__file__).resolve().parents[2] / "bin" / "extract-gas.py"
    spec = importlib.util.spec_from_file_location("extract_gas", module_path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)  # type: ignore[attr-defined]
    return module


def sample_table_basic() -> str:
    """Standard gas table with simple function names."""
    return textwrap.dedent(
        """\
        | src/minter/Minter_v3.sol:Minter_v3 Contract |                 |        |        |        |         |
        | Function Name                                | Min             | Avg    | Median | Max    | # Calls |
        | mintPeggedToken                               | 50000           | 60000  | 55000  | 80000  | 100     |
        | collateralRatio                               | 1000            | 1200   | 1100   | 1500   | 50      |"""
    )


def sample_table_with_digits() -> str:
    """Gas table with function names containing digits (e.g. pack64, unpack64)."""
    return textwrap.dedent(
        """\
        | src/minter/library/StringPacking_v1.sol:StringPacking_v1 Contract |                 |       |        |       |         |
        | Deployment Cost                                                   | Deployment Size |       |        |       |         |
        | 243910                                                            | 1270            |       |        |       |         |
        | Function Name                                                     | Min             | Avg   | Median | Max   | # Calls |
        | pack64                                                            | 597             | 849   | 842    | 937   | 805     |
        | unpack64                                                          | 13657           | 14819 | 15382  | 15796 | 7       |"""
    )


def sample_table_with_overloads() -> str:
    """Gas table with overloaded functions showing full signatures."""
    return textwrap.dedent(
        """\
        | src/minter/Minter_v3.sol:Minter_v3 Contract |                 |        |        |        |         |
        | Function Name                                | Min             | Avg    | Median | Max    | # Calls |
        | mintPeggedToken(uint256,address,uint256)      | 15334           | 92592  | 95155  | 191101 | 25271   |
        | mintPeggedToken(uint256,address,uint256,uint256) | 36904        | 119840 | 125106 | 125114 | 67      |
        | mintPeggedTokenDryRun(uint256)                | 28000           | 30000  | 29000  | 35000  | 100     |
        | mintPeggedTokenDryRun(uint256,uint256)        | 30000           | 32000  | 31000  | 37000  | 50      |"""
    )


def sample_table_with_dollar() -> str:
    """Gas table with function names containing $ (valid Solidity identifier)."""
    return textwrap.dedent(
        """\
        | src/test/Mock.sol:Mock Contract |                 |       |        |       |         |
        | Function Name                   | Min             | Avg   | Median | Max   | # Calls |
        | $special                        | 100             | 200   | 150    | 300   | 10      |
        | _internal                       | 500             | 600   | 550    | 700   | 20      |"""
    )


def sample_table_excluded_path() -> str:
    """Gas table from an excluded path (test file)."""
    return textwrap.dedent(
        """\
        | test/SomeTest.t.sol:SomeTest Contract |                 |       |        |       |         |
        | Function Name                         | Min             | Avg   | Median | Max   | # Calls |
        | setUp                                 | 1000            | 1000  | 1000   | 1000  | 1       |"""
    )


def test_basic_table():
    module = load_module()
    result = module.toNamedDataFrame(sample_table_basic())
    assert result is not None
    df, path = result
    assert path == "src/minter/Minter_v3.sol:Minter_v3"
    assert len(df) == 2
    assert "mintPeggedToken" in df["function name"].values
    assert "collateralRatio" in df["function name"].values


def test_function_names_with_digits():
    module = load_module()
    result = module.toNamedDataFrame(sample_table_with_digits())
    assert result is not None
    df, path = result
    assert "StringPacking_v1" in path
    assert len(df) == 2
    assert "pack64" in df["function name"].values
    assert "unpack64" in df["function name"].values


def test_function_names_with_dollar_and_underscore():
    module = load_module()
    result = module.toNamedDataFrame(sample_table_with_dollar())
    assert result is not None
    df, _ = result
    assert len(df) == 2
    assert "$special" in df["function name"].values
    assert "_internal" in df["function name"].values


def test_excluded_path_returns_none():
    module = load_module()
    result = module.toNamedDataFrame(sample_table_excluded_path())
    assert result is None


def test_overloaded_function_signatures():
    module = load_module()
    result = module.toNamedDataFrame(sample_table_with_overloads())
    assert result is not None
    df, path = result
    assert "Minter_v3" in path
    assert len(df) == 4
    assert "mintPeggedToken(uint256,address,uint256)" in df["function name"].values
    assert "mintPeggedToken(uint256,address,uint256,uint256)" in df["function name"].values
    assert "mintPeggedTokenDryRun(uint256)" in df["function name"].values
    assert "mintPeggedTokenDryRun(uint256,uint256)" in df["function name"].values


def test_deployment_cost_rows_excluded():
    """Deployment cost rows (starting with digits) should not appear as function rows."""
    module = load_module()
    result = module.toNamedDataFrame(sample_table_with_digits())
    assert result is not None
    df, _ = result
    # "243910" is a deployment cost, not a function name
    assert "243910" not in df["function name"].values
    # "Deployment Cost" is a header, not a function
    assert "Deployment Cost" not in df["function name"].values
