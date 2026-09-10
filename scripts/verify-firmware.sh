#!/bin/bash
# Read-only validation runs sandboxed; Xcode's native Copy Files phases copy and sign resources.
set -euo pipefail
cd "$SRCROOT/AhaKey Studio/Resources/FirmwareFlasher"
shasum -a 256 -c SOURCE_SHA256SUMS
touch "$SCRIPT_OUTPUT_FILE_0"
