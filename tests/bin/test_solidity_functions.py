"""Tests for bin/solidity-functions — per-function deployed-bytecode attribution.

Two properties carry the tool's whole value, and BOTH fail silently when broken — the report still
prints, still looks plausible, and is wrong — which is why they are pinned here rather than checked
by eye:

  - A contract that links external libraries carries a `__$<hash>$__` placeholder wherever the
    linker will write an address. It must be replaced by EXACTLY the 20 bytes it stands for; any
    other length shifts every instruction boundary after the first library reference, and every
    byte from there on is charged to the wrong function.
  - The reported TOTAL must reconcile with the contract's actual byte count in every mode. That is
    the tool's headline claim ("exact attribution ... not a heuristic"), and it is only worth
    anything if nothing can be dropped from the sum unnoticed.
"""

import importlib.machinery
import importlib.util
import json
import pathlib
import re

import pytest


def load_module():
    """Load bin/solidity-functions. It has no .py suffix, so the loader is named explicitly."""
    module_path = pathlib.Path(__file__).resolve().parents[2] / "bin" / "solidity-functions"
    loader = importlib.machinery.SourceFileLoader("solidity_functions", str(module_path))
    spec = importlib.util.spec_from_loader("solidity_functions", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


SAMPLE_SOURCE = """contract Sample {
    function alpha() external { }
    function beta() internal { }
}
"""

# `__$` + 34 hex characters of the library-name hash + `$__` — 40 characters standing for the 20
# bytes of the PUSH20 operand that loads the library address.
PLACEHOLDER = "__$" + "a" * 34 + "$__"

# The synthetic contract's instruction plan, by index into the source map:
#   0  PUSH20 <library address>  21 bytes, inside alpha
#   1  single byte                        inside alpha
#   2  single byte                        inside beta
#   3  single byte                        contract-level (source offset 0, outside every function)
#   4  single byte                        a different source file: base contracts & libraries
#   5  single byte                        past the end of the source map: metadata/unmapped
#   6  single byte                        likewise
EXPECTED_TOTAL = 21 + 6
EXPECTED_ALPHA = 21 + 1
EXPECTED_BETA = 1


def build_artifact(tmp_path, *, linked=True):
    """Write a synthetic source + forge artifact and return the path to the source.

    The artifact is hand-built rather than produced by `forge build` so the expected attribution is
    known exactly: a real build would make the test assert whatever the compiler happened to emit.
    """
    module = load_module()
    funcs = module.find_functions(SAMPLE_SOURCE)
    alpha = next(f for f in funcs if f["name"] == "alpha")
    beta = next(f for f in funcs if f["name"] == "beta")

    operand = PLACEHOLDER if linked else "00" * 20
    code = "73" + operand + "00" * 6
    source_map = ";".join(
        [
            f"{alpha['start_off']}:1:0",
            f"{alpha['start_off']}:1:0",
            f"{beta['start_off']}:1:0",
            "0:1:0",
            "0:1:1",
        ]
    )
    link_references = {"src/SampleLib.sol": {"SampleLib": [{"start": 1, "length": 20}]}} if linked else {}
    artifact = {
        "deployedBytecode": {
            "object": "0x" + code,
            "sourceMap": source_map,
            "linkReferences": link_references,
        }
    }

    source_dir = tmp_path / "src"
    source_dir.mkdir(exist_ok=True)
    source_path = source_dir / "Sample.sol"
    source_path.write_text(SAMPLE_SOURCE)
    out_dir = tmp_path / "out" / "Sample.sol"
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "Sample.json").write_text(json.dumps(artifact))
    return source_path


def run_main(monkeypatch, capsys, source_path, *extra_args):
    module = load_module()
    monkeypatch.setattr("sys.argv", ["solidity-functions", str(source_path), "--bytecode", *extra_args])
    assert module.main() == 0
    return capsys.readouterr().out


def header_total(output: str) -> int:
    return int(re.search(r"total (\d+) bytes", output).group(1))


def reported_total(output: str) -> int:
    return int(re.search(r"(\d+)\s+TOTAL attributed", output).group(1))


def test_linked_bytecode_is_decoded_rather_than_crashing(tmp_path, monkeypatch, capsys):
    """A contract linking an external library reports at all — the placeholder is not hexadecimal,
    so decoding it as-is aborts the whole run."""
    output = run_main(monkeypatch, capsys, build_artifact(tmp_path))
    assert header_total(output) == EXPECTED_TOTAL


def test_totals_reconcile_when_only_public_functions_are_listed(tmp_path, monkeypatch, capsys):
    """TOTAL matches the contract's real size even though `beta` is filtered out of the listing —
    its bytes are reported as a named line, never silently dropped from the sum."""
    output = run_main(monkeypatch, capsys, build_artifact(tmp_path))
    assert reported_total(output) == EXPECTED_TOTAL == header_total(output)
    unlisted = int(re.search(r"(\d+)\s+functions not listed above", output).group(1))
    assert unlisted == EXPECTED_BETA


def test_totals_reconcile_when_every_function_is_listed(tmp_path, monkeypatch, capsys):
    """--all lists `beta` directly, so there is nothing left over and the sum still closes."""
    output = run_main(monkeypatch, capsys, build_artifact(tmp_path), "--all")
    assert reported_total(output) == EXPECTED_TOTAL == header_total(output)
    assert "functions not listed above" not in output


def test_bytes_are_charged_to_the_function_containing_the_instruction(tmp_path, monkeypatch, capsys):
    """The PUSH20 that loads the library address costs its full 21 bytes, charged to the function
    that makes the call — not 1 byte, and not to whatever follows the operand."""
    output = run_main(monkeypatch, capsys, build_artifact(tmp_path), "--all")
    rows = dict(re.findall(r"(\d+)\s+\w+\s+[\d-]+\s+Sample\.(\w+)", output))
    assert {name: int(size) for size, name in rows.items()} == {
        "alpha": EXPECTED_ALPHA,
        "beta": EXPECTED_BETA,
    }


def test_linked_libraries_are_named_in_the_header(tmp_path, monkeypatch, capsys):
    """The reader has to know the library bodies are NOT in this total, and which they are."""
    output = run_main(monkeypatch, capsys, build_artifact(tmp_path))
    assert "SampleLib" in output
    assert "links 1 external library" in output


def test_an_unlinked_contract_reports_no_libraries(tmp_path, monkeypatch, capsys):
    """The linked-library note appears only when there is one — it is not boilerplate."""
    output = run_main(monkeypatch, capsys, build_artifact(tmp_path, linked=False))
    assert "external librar" not in output
    assert reported_total(output) == EXPECTED_TOTAL


def test_placeholder_substitution_preserves_every_instruction_boundary(tmp_path):
    """The property the attribution rests on: resolving the placeholders yields byte-for-byte the
    same instruction stream as the same contract with a real address linked in. A substitution of
    any other length would silently re-align every instruction after the library reference."""
    module = load_module()
    linked = "73" + PLACEHOLDER + "00" * 6
    already_linked = "73" + "0" * 40 + "00" * 6

    resolved, replaced = module.resolve_link_placeholders(linked, pathlib.Path("Sample.json"))

    assert replaced == 1
    assert len(resolved) == len(linked)
    assert list(module.opcode_offsets(resolved)) == list(module.opcode_offsets(already_linked))
    assert list(module.opcode_offsets(resolved))[0] == 21


def test_bytecode_without_placeholders_is_left_alone(tmp_path):
    module = load_module()
    code = "60ff00"

    resolved, replaced = module.resolve_link_placeholders(code, pathlib.Path("Sample.json"))

    assert (resolved, replaced) == (code, 0)


def test_malformed_bytecode_reports_what_was_seen(tmp_path):
    """A non-hexadecimal byte that is NOT a link placeholder is a fact worth reporting — which
    artifact, which character, where — rather than a bare fromhex traceback."""
    module = load_module()
    artifact_path = pathlib.Path("out/Sample.sol/Sample.json")

    with pytest.raises(SystemExit) as excinfo:
        module.resolve_link_placeholders("6000zz00", artifact_path)

    message = str(excinfo.value)
    assert str(artifact_path) in message
    assert "'z'" in message
    assert "4" in message
