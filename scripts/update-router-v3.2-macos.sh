#!/bin/bash
# Compatibility entry point retained for existing install instructions.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
exec bash "$HERE/update-router-macos.sh" "$@"
