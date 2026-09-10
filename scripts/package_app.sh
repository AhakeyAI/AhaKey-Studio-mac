#!/bin/bash
# CI/local release app, including the Agent, icons and verified firmware resources.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export CONFIGURATION=Release
export SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
exec "$SCRIPT_DIR/build.sh" "$@"
