#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export CONFIGURATION=Debug
exec "$SCRIPT_DIR/build.sh" "$@"
