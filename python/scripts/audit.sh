#!/usr/bin/env bash
set -euo pipefail
. .venv/bin/activate

# Lightweight vulnerability scan of the current environment.
# You can run this after installing a non-remediated version, then again after installing a +cgr.1 remediated version.
pip install --upgrade pip pip-audit >/dev/null
pip-audit || true
