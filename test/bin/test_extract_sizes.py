import importlib.util
import pathlib

import pandas as pd


def load_module():
    module_path = pathlib.Path(__file__).resolve().parents[2] / "bin" / "extract-sizes.py"
    spec = importlib.util.spec_from_file_location("extract_sizes", module_path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)  # type: ignore[attr-defined]
    return module


def sample_table() -> str:
    return """
| Contract | Runtime Size (B) | Runtime Margin (B) | Initcode Size (B) | Initcode Margin (B) |
| MinimalStub | 1,828 | 23 | 2,295 | 500 |
| OzStyleStub | 4,350 | 50 | 4,454 | 600 |
""".strip()


def test_deploy_cost_includes_init_and_is_last_column():
    module = load_module()
    df, path = module.toNamedDataFrame(sample_table())

    assert path == ""
    expected_columns = [
        "Contract",
        "Runtime Size (B)",
        "Runtime Margin (B)",
        "Initcode Size (B)",
        "Deploy Gas",
        "Deploy Cost ($)",
    ]
    assert list(df.columns) == expected_columns

    runtime_minimal = 1828
    init_minimal = 2295
    expected_gas_minimal = runtime_minimal * module.GAS_PER_BYTE + init_minimal * module.INITCODE_AVG_GAS_PER_BYTE
    deploy_cost_col = "Deploy Cost ($)"
    assert df.loc[0, "Deploy Gas"] == expected_gas_minimal

    expected_cost_minimal = expected_gas_minimal * module.USD_PER_GAS
    assert df.loc[0, deploy_cost_col] == expected_cost_minimal

    # Ensure we keep numerical types for downstream aggregation
    assert pd.api.types.is_integer_dtype(df["Initcode Size (B)"])  # type: ignore[arg-type]
    assert pd.api.types.is_integer_dtype(df["Deploy Gas"])  # type: ignore[arg-type]
    assert pd.api.types.is_float_dtype(df[deploy_cost_col])  # type: ignore[arg-type]


def test_is_excluded_filters_test_contracts(monkeypatch):
    module = load_module()

    def mock_path(name):
        paths = {
            "Array": "test/Array.sol",
            "Clog": "test/Useful.sol",
            "Useful": "test/Useful.sol",
            "FakeStabilityPool": "test/_sizes/FakeContracts.sol",
            "StabilityPool_v3": "src/minter/StabilityPool_v3.sol",
            "Minter_v3": "src/minter/Minter_v3.sol",
            "SomeLib": "lib/openzeppelin/Token.sol",
            "SomeVerify": "script/verify/sp-v2-upgrade/SomeTest.sol",
        }
        return paths.get(name)

    monkeypatch.setattr(module, "get_contract_source_path", mock_path)

    # test/ contracts excluded
    assert module.is_excluded_contract("Array") is True
    assert module.is_excluded_contract("Clog") is True
    assert module.is_excluded_contract("Useful") is True

    # test/_sizes/ contracts kept (Fake* for measuring abstract sizes)
    assert module.is_excluded_contract("FakeStabilityPool") is False

    # src/ contracts kept
    assert module.is_excluded_contract("StabilityPool_v3") is False
    assert module.is_excluded_contract("Minter_v3") is False

    # lib/ contracts excluded
    assert module.is_excluded_contract("SomeLib") is True

    # script/verify/ excluded
    assert module.is_excluded_contract("SomeVerify") is True

    # unknown contract (no artifact) — not excluded
    assert module.is_excluded_contract("Unknown") is False


if __name__ == "__main__":
    raise SystemExit("Run this test with pytest or python -m pytest")
