#!/usr/bin/env python3
"""The configuration forge builds with, as `forge config` resolves it.

Shared by doctor, which checks settings in it, and bin/dep, which reads the remappings from it. Read from
forge rather than from foundry.toml, because the active profile and `FOUNDRY_*` environment variables
override the file, and forge builds with what it resolves.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any


def forge_config(repo_root: Path) -> dict[str, Any]:
    """`forge config --json`, parsed. Raises `subprocess.CalledProcessError`, carrying forge's stderr, when
    forge cannot resolve a configuration."""
    return json.loads(
        subprocess.run(["forge", "config", "--json"], cwd=repo_root, capture_output=True, text=True, check=True).stdout
    )
