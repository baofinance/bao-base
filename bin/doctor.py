#!/usr/bin/env python3
from __future__ import annotations

import subprocess
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


repo_root = Path(
    subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True, text=True, check=True
    ).stdout.strip()
)
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


def strip_context_prefix(entry: str) -> str:
    """Foundry supports context-specific remappings ('ctx/:key=val'); Wake does not.
    Strip the context prefix so both sides can be compared on equal footing."""
    eq = entry.find("=")
    colon = entry.find(":", 0, eq if eq != -1 else len(entry))
    if colon != -1:
        return entry[colon + 1 :]
    return entry


def submodule_url_drift(repo_dir: Path, prefix: str = "") -> list[tuple[str, str, str]]:
    """Find submodules whose initialized URL in .git/config disagrees with the committed
    .gitmodules. `git submodule update` trusts .git/config (written once at init/sync) and
    never reconciles it when .gitmodules changes, so a stale .git/config silently clones the
    wrong URL. Read-only: compares the two configs, recursing into populated submodules so
    drift at any nesting level is reported. Returns (display path, .gitmodules url, .git/config url)."""
    gitmodules = repo_dir / ".gitmodules"
    if not gitmodules.is_file():
        return []

    listing = subprocess.run(
        ["git", "config", "-f", ".gitmodules", "--get-regexp", r"^submodule\..*\.url$"],
        cwd=repo_dir, capture_output=True, text=True,
    )

    drift: list[tuple[str, str, str]] = []
    for line in listing.stdout.splitlines():
        key, _, gitmodules_url = line.partition(" ")
        gitmodules_url = gitmodules_url.strip()
        name = key[len("submodule.") : -len(".url")]

        path_result = subprocess.run(
            ["git", "config", "-f", ".gitmodules", "--get", f"submodule.{name}.path"],
            cwd=repo_dir, capture_output=True, text=True,
        )
        sub_path = path_result.stdout.strip() or name
        display = f"{prefix}{sub_path}"

        # --local is the .git/config that `submodule update` reads. A non-zero return means
        # this submodule isn't initialized in this clone, so there is no stored URL to drift.
        local = subprocess.run(
            ["git", "config", "--local", "--get", f"submodule.{name}.url"],
            cwd=repo_dir, capture_output=True, text=True,
        )
        if local.returncode == 0:
            gitconfig_url = local.stdout.strip()
            if gitconfig_url != gitmodules_url:
                drift.append((display, gitmodules_url, gitconfig_url))

        nested = repo_dir / sub_path
        if (nested / ".git").exists():
            drift.extend(submodule_url_drift(nested, prefix=f"{display}/"))

    return drift


normalized_foundry = [strip_context_prefix(r) for r in foundry_remappings]

problems: list[str] = []

if normalized_foundry != wake_remappings:
    foundry_only = [item for item in normalized_foundry if item not in wake_remappings]
    wake_only = [item for item in wake_remappings if item not in normalized_foundry]

    mismatch_details: list[str] = []

    if foundry_only:
        mismatch_details.append("Entries only in foundry.toml:\n  " + "\n  ".join(foundry_only))

    if wake_only:
        mismatch_details.append("Entries only in wake.toml:\n  " + "\n  ".join(wake_only))

    if not mismatch_details:
        for index, pair in enumerate(zip(normalized_foundry, wake_remappings)):
            if pair[0] != pair[1]:
                mismatch_details.append(
                    f"Order mismatch at index {index}: "
                    f"foundry.toml has {pair[0]!r} while wake.toml has {pair[1]!r}."
                )
                break

        if len(normalized_foundry) != len(wake_remappings):
            mismatch_details.append(
                "The lists have different lengths: " f"{len(normalized_foundry)} vs {len(wake_remappings)}."
            )

    if not mismatch_details:
        mismatch_details.append("Remapping lists differ but no specific difference found.")

    problems.append("Remapping mismatch detected:\n" + "\n".join(mismatch_details))
else:
    print("Foundry and Wake remappings are identical.")

drift = submodule_url_drift(repo_root)
if drift:
    drift_lines = ["Submodule URL drift — .git/config disagrees with the committed .gitmodules:"]
    for display, gitmodules_url, gitconfig_url in drift:
        drift_lines.append(f"  {display}")
        drift_lines.append(f"    .git/config: {gitconfig_url}")
        drift_lines.append(f"    .gitmodules: {gitmodules_url}")
    drift_lines.append("Repair (rewrites .git/config from .gitmodules): git submodule sync")
    problems.append("\n".join(drift_lines))
else:
    print("Submodule URLs match between .git/config and .gitmodules.")

if problems:
    raise SystemExit("\n\n".join(problems))
