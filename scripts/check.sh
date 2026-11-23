#!/bin/sh
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
sh -n scripts/dynbq-controller.sh
sh -n scripts/router-cleanup.sh
sh -n scripts/check.sh
bash -n scripts/update-router-macos.sh
bash -n scripts/update-router-v3.2-macos.sh
bash -n scripts/test-high-macos.sh
bash -n scripts/package-release.sh
python3 tests/state_machine.py
