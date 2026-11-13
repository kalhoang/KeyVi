# SPDX-License-Identifier: LicenseRef-App-Pending
"""Shared helpers for the Python self-tests in scripts/tests (test_scripts.py, test_docs_and_workflows.py)."""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPTS = REPO / "scripts"


def run(*args: str, env: dict | None = None, check: bool = False) -> subprocess.CompletedProcess:
    """Runs a command with the GitHub Actions variables removed, so scripts behave as on a developer Mac."""
    merged = dict(os.environ)
    merged.pop("GITHUB_ACTIONS", None)
    merged.pop("GITHUB_STEP_SUMMARY", None)
    merged.update(env or {})
    return subprocess.run(list(args), capture_output=True, text=True, env=merged, check=check)


def py(script: str, *args: str, env: dict | None = None) -> subprocess.CompletedProcess:
    """Runs scripts/<script> with the current interpreter in isolated mode."""
    return run(sys.executable, "-I", str(SCRIPTS / script), *args, env=env)
