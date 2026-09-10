#!/bin/bash
# Launch demo targets with the caller's plugin environment intact.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="${1:-PluginShowcase}"
if [[ $# -gt 0 ]]; then shift; fi
case "$TARGET" in
  PluginShowcase|VibeBarSmoke) PRODUCT="$TARGET.app/Contents/MacOS/$TARGET" ;;
  Plugin|SocketServer|Client) PRODUCT="$TARGET" ;;
  AhaKeyConfigAgent) PRODUCT=ahakeyconfig-agent ;;
  *) echo "Supported targets: PluginShowcase, VibeBarSmoke, Plugin, AhaKeyConfigAgent, SocketServer, Client" >&2; exit 2 ;;
esac
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$REPO_ROOT/DerivedData}"
xcodebuild -quiet -project "$REPO_ROOT/AhaKey Studio.xcodeproj" -scheme "$TARGET" \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA_PATH" build
exec "$DERIVED_DATA_PATH/Build/Products/Debug/$PRODUCT" "$@"
