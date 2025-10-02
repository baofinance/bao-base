#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
from typing import Any, cast

try:
    import tomllib as _toml_loader

    def load_toml(path: Path) -> dict[str, Any]:
        with path.open("rb") as stream:
            return _toml_loader.load(stream)

except ModuleNotFoundError:
    try:
        import toml as _toml_loader
    except ModuleNotFoundError as exc:  # pragma: no cover - dependency should be present via pyproject
        raise SystemExit(
            "doctor.py requires either the stdlib tomllib (Python >=3.11) or the third-party toml package."
        ) from exc

    def load_toml(path: Path) -> dict[str, Any]:
        with path.open("r", encoding="utf-8") as stream:
            return _toml_loader.load(stream)


script_path = Path(__file__).resolve()
repo_root = script_path.parents[3]
foundry_path = repo_root / "foundry.toml"
wake_path = repo_root / "wake.toml"

missing = [path for path in (foundry_path, wake_path) if not path.is_file()]
if missing:
    readable = ", ".join(path.name for path in missing)
    raise SystemExit(f"Missing config file(s): {readable}.")

foundry_data = load_toml(foundry_path)
wake_data = load_toml(wake_path)

try:
    foundry_remappings = foundry_data["profile"]["default"]["remappings"]
except KeyError as exc:
    raise SystemExit("foundry.toml does not define profile.default.remappings.") from exc

try:
    wake_remappings = wake_data["compiler"]["solc"]["remappings"]
except KeyError as exc:
    raise SystemExit("wake.toml does not define compiler.solc.remappings.") from exc

if not isinstance(foundry_remappings, list):
    raise SystemExit("profile.default.remappings in foundry.toml is not a list.")

if not isinstance(wake_remappings, list):
    raise SystemExit("compiler.solc.remappings in wake.toml is not a list.")

foundry_items = cast(list[Any], foundry_remappings)
for item in foundry_items:
    if not isinstance(item, str):
        raise SystemExit("profile.default.remappings in foundry.toml must contain only strings.")

wake_items = cast(list[Any], wake_remappings)
for item in wake_items:
    if not isinstance(item, str):
        raise SystemExit("compiler.solc.remappings in wake.toml must contain only strings.")

foundry_remappings = cast(list[str], foundry_items)
wake_remappings = cast(list[str], wake_items)

if foundry_remappings != wake_remappings:
    foundry_only = [item for item in foundry_remappings if item not in wake_remappings]
    wake_only = [item for item in wake_remappings if item not in foundry_remappings]

    mismatch_details: list[str] = []

    if foundry_only:
        mismatch_details.append("Entries only in foundry.toml:\n  " + "\n  ".join(foundry_only))

    if wake_only:
        mismatch_details.append("Entries only in wake.toml:\n  " + "\n  ".join(wake_only))

    if not mismatch_details:
        for index, pair in enumerate(zip(foundry_remappings, wake_remappings)):
            if pair[0] != pair[1]:
                mismatch_details.append(
                    f"Order mismatch at index {index}: "
                    f"foundry.toml has {pair[0]!r} while wake.toml has {pair[1]!r}."
                )
                break

        if len(foundry_remappings) != len(wake_remappings):
            mismatch_details.append(
                "The lists have different lengths: " f"{len(foundry_remappings)} vs {len(wake_remappings)}."
            )

    if not mismatch_details:
        mismatch_details.append("Remapping lists differ but no specific difference found.")

    raise SystemExit("Remapping mismatch detected:\n" + "\n".join(mismatch_details))

print("Foundry and Wake remappings are identical.")
