#!/bin/zsh
# Build the App Target with the same configuration used by Xcode.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PROJECT_ROOT/DerivedData}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_ROOT/dist}"

if [[ "${REQUIRE_DEVELOPER_ID:-0}" == "1" && "${SIGNING_IDENTITY:-}" != Developer\ ID\ Application:* ]]; then
  echo "A Developer ID Application signing identity is required."
  exit 1
fi

ARGS=(-project "$PROJECT_ROOT/AhaKey Studio.xcodeproj" -scheme "AhaKey Studio"
  -configuration "$CONFIGURATION" -derivedDataPath "$DERIVED_DATA_PATH")
if [[ "$CONFIGURATION" == "Debug" ]]; then
  ARGS+=(-destination 'platform=macOS')
else
  ARGS+=(-destination 'generic/platform=macOS')
fi
# Only explicit overrides are passed; version, deployment target and app name come from the Xcode project.
[[ -z "${APP_VERSION:-}" ]] || ARGS+=("MARKETING_VERSION=$APP_VERSION")
[[ -z "${APP_BUILD:-}" ]] || ARGS+=("CURRENT_PROJECT_VERSION=$APP_BUILD")
[[ -z "${BUILD_ARCHS:-}" ]] || ARGS+=("ARCHS=$BUILD_ARCHS" ONLY_ACTIVE_ARCH=NO)
[[ -z "${MACOS_DEPLOYMENT_TARGET:-}" ]] || ARGS+=("MACOSX_DEPLOYMENT_TARGET=$MACOS_DEPLOYMENT_TARGET")
[[ -z "${APP_BUNDLE_NAME:-}" ]] || ARGS+=("APP_BUNDLE_NAME=$APP_BUNDLE_NAME")
[[ -z "${APP_DISPLAY_NAME:-}" ]] || ARGS+=("APP_DISPLAY_NAME=$APP_DISPLAY_NAME")
[[ -z "${SIGNING_IDENTITY:-}" ]] || ARGS+=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$SIGNING_IDENTITY")

xcodebuild "${ARGS[@]}" build
SETTINGS_FILE="$(mktemp -t ahakey-build-settings)"
trap 'rm -f "$SETTINGS_FILE"' EXIT
xcodebuild "${ARGS[@]}" -showBuildSettings -json > "$SETTINGS_FILE"
BUILT_APP="$(python3 - "$SETTINGS_FILE" <<'PY'
import json, os, sys
with open(sys.argv[1]) as source:
    targets = json.load(source)
settings = next(t['buildSettings'] for t in targets if t['target'] == 'AhaKey Studio')
print(os.path.join(settings['TARGET_BUILD_DIR'], settings['FULL_PRODUCT_NAME']))
PY
)"
codesign --verify --deep --strict --verbose=2 "$BUILT_APP"
APP_BUNDLE="$OUTPUT_DIR/$(basename "$BUILT_APP")"
mkdir -p "$OUTPUT_DIR"
if [[ "$BUILT_APP" != "$APP_BUNDLE" ]]; then
  rm -rf "$APP_BUNDLE"
  ditto "$BUILT_APP" "$APP_BUNDLE"
fi

if [[ "${INSTALL_TO_APPLICATIONS:-0}" == "1" ]]; then
  INSTALL_DIR="${INSTALL_DIR:-/Applications}"
  DEST_APP="$INSTALL_DIR/$(basename "$APP_BUNDLE")"
  if pgrep -f "$DEST_APP/Contents/MacOS/AhaKeyConfig" >/dev/null 2>&1; then
    echo "Quit $(basename "$APP_BUNDLE") before replacing the installed application."
    exit 1
  fi
  mkdir -p "$INSTALL_DIR"
  rm -rf "$DEST_APP"
  ditto "$APP_BUNDLE" "$DEST_APP"
  if [[ "${LAUNCH_AFTER_INSTALL:-0}" == "1" ]]; then
    open "$DEST_APP"
  fi
fi
echo "Build complete: $APP_BUNDLE"
