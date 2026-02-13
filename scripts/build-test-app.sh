#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_DIR="$ROOT_DIR/MCPTestApp"
DERIVED_DATA="$PROJECT_DIR/DerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/MCPTestApp.app"
BUNDLE_ID="com.mcp-test.playground"
SCHEME="MCPTestApp"

# Determine simulator name from VCS root (mirrors computeDefaultDeviceName())
SIM_NAME="$(jj root 2>/dev/null || git rev-parse --show-toplevel 2>/dev/null || echo "$ROOT_DIR")"
SIM_NAME="$(basename "$SIM_NAME")"

# Quiet on success, verbose on failure
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

quiet() {
    if ! "$@" >> "$LOG" 2>&1; then
        cat "$LOG"
        exit 1
    fi
}

# Find simulator by exact name, return its UUID
get_simulator_id() {
    local name="$1"
    xcrun simctl list devices -j | \
        python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data.get('devices', {}).items():
    if 'iOS' in runtime:
        for d in devices:
            if d['name'] == '$name' and d['isAvailable']:
                print(d['udid'])
                sys.exit(0)
" 2>/dev/null || true
}

SIM_ID=$(get_simulator_id "$SIM_NAME")

if [ -z "$SIM_ID" ]; then
    # Get latest iOS runtime
    RUNTIME=$(xcrun simctl list runtimes -j | python3 -c "
import json, sys
data = json.load(sys.stdin)
ios_runtimes = [r for r in data.get('runtimes', []) if 'iOS' in r.get('name', '') and r.get('isAvailable')]
if ios_runtimes:
    print(ios_runtimes[-1]['identifier'])
")
    SIM_ID=$(xcrun simctl create "$SIM_NAME" "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro" "$RUNTIME")
    echo "Created simulator '$SIM_NAME' ($SIM_ID)"
fi

# Boot simulator if not running
if ! xcrun simctl list devices | grep "$SIM_ID" | grep -q "Booted"; then
    xcrun simctl boot "$SIM_ID" >> "$LOG" 2>&1 || true
fi

echo "==> Building $SCHEME for simulator '$SIM_NAME' ($SIM_ID)..."
quiet xcodebuild build \
    -project "$PROJECT_DIR/MCPTestApp.xcodeproj" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$SIM_ID" \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA"

echo "==> Installing on $SIM_NAME..."
quiet xcrun simctl install "$SIM_ID" "$APP_PATH"

echo "==> Launching $BUNDLE_ID..."
xcrun simctl launch --console-pty "$SIM_ID" "$BUNDLE_ID"
