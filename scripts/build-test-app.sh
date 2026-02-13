#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# iOS constants
IOS_PROJECT_DIR="$ROOT_DIR/MCPTestApp"
IOS_DERIVED_DATA="$IOS_PROJECT_DIR/DerivedData"
IOS_APP_PATH="$IOS_DERIVED_DATA/Build/Products/Debug-iphonesimulator/MCPTestApp.app"
IOS_BUNDLE_ID="com.mcp-test.playground"
IOS_SCHEME="MCPTestApp"

# watchOS constants
WATCH_PROJECT_DIR="$ROOT_DIR/WatchTestApp"
WATCH_DERIVED_DATA="$WATCH_PROJECT_DIR/DerivedData"
WATCH_APP_PATH="$WATCH_DERIVED_DATA/Build/Products/Debug-watchsimulator/WatchTestApp.app"
WATCH_BUNDLE_ID="com.mcp-test.playground.watchapp"
WATCH_SCHEME="WatchTestApp"

# Platform selection: ios, watchos, or both
PLATFORM="${1:-both}"

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

# Find iOS simulator by exact name, return its UUID
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

# Find watchOS simulator by exact name, return its UUID
get_watch_simulator_id() {
    local name="$1"
    xcrun simctl list devices -j | \
        python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data.get('devices', {}).items():
    if 'watchOS' in runtime:
        for d in devices:
            if d['name'] == '$name' and d['isAvailable']:
                print(d['udid'])
                sys.exit(0)
" 2>/dev/null || true
}

# --- iOS ---
if [ "$PLATFORM" = "ios" ] || [ "$PLATFORM" = "both" ]; then
    SIM_ID=$(get_simulator_id "$SIM_NAME")

    if [ -z "$SIM_ID" ]; then
        RUNTIME=$(xcrun simctl list runtimes -j | python3 -c "
import json, sys
data = json.load(sys.stdin)
ios_runtimes = [r for r in data.get('runtimes', []) if 'iOS' in r.get('name', '') and r.get('isAvailable')]
if ios_runtimes:
    print(ios_runtimes[-1]['identifier'])
")
        SIM_ID=$(xcrun simctl create "$SIM_NAME" "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro" "$RUNTIME")
        echo "Created iOS simulator '$SIM_NAME' ($SIM_ID)"
    fi

    if ! xcrun simctl list devices | grep "$SIM_ID" | grep -q "Booted"; then
        xcrun simctl boot "$SIM_ID" >> "$LOG" 2>&1 || true
    fi

    echo "==> Building $IOS_SCHEME for simulator '$SIM_NAME' ($SIM_ID)..."
    quiet xcodebuild build \
        -project "$IOS_PROJECT_DIR/MCPTestApp.xcodeproj" \
        -scheme "$IOS_SCHEME" \
        -destination "platform=iOS Simulator,id=$SIM_ID" \
        -configuration Debug \
        -derivedDataPath "$IOS_DERIVED_DATA"

    echo "==> Installing on $SIM_NAME..."
    quiet xcrun simctl install "$SIM_ID" "$IOS_APP_PATH"

    echo "==> Launching $IOS_BUNDLE_ID..."
    xcrun simctl launch "$SIM_ID" "$IOS_BUNDLE_ID" || true
fi

# --- watchOS ---
if [ "$PLATFORM" = "watchos" ] || [ "$PLATFORM" = "both" ]; then
    WATCH_SIM_NAME="${SIM_NAME}-watch"
    WATCH_SIM_ID=$(get_watch_simulator_id "$WATCH_SIM_NAME")

    if [ -z "$WATCH_SIM_ID" ]; then
        WATCH_RUNTIME=$(xcrun simctl list runtimes -j | python3 -c "
import json, sys
data = json.load(sys.stdin)
runtimes = [r for r in data.get('runtimes', []) if 'watchOS' in r.get('name', '') and r.get('isAvailable')]
if runtimes:
    print(runtimes[-1]['identifier'])
")
        WATCH_SIM_ID=$(xcrun simctl create "$WATCH_SIM_NAME" "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Ultra-2-49mm" "$WATCH_RUNTIME")
        echo "Created watchOS simulator '$WATCH_SIM_NAME' ($WATCH_SIM_ID)"
    fi

    if ! xcrun simctl list devices | grep "$WATCH_SIM_ID" | grep -q "Booted"; then
        xcrun simctl boot "$WATCH_SIM_ID" >> "$LOG" 2>&1 || true
    fi

    echo "==> Building $WATCH_SCHEME for simulator '$WATCH_SIM_NAME' ($WATCH_SIM_ID)..."
    quiet xcodebuild build \
        -project "$WATCH_PROJECT_DIR/WatchTestApp.xcodeproj" \
        -scheme "$WATCH_SCHEME" \
        -destination "platform=watchOS Simulator,id=$WATCH_SIM_ID" \
        -configuration Debug \
        -derivedDataPath "$WATCH_DERIVED_DATA"

    echo "==> Installing on $WATCH_SIM_NAME..."
    quiet xcrun simctl install "$WATCH_SIM_ID" "$WATCH_APP_PATH"

    echo "==> Launching $WATCH_BUNDLE_ID..."
    xcrun simctl launch "$WATCH_SIM_ID" "$WATCH_BUNDLE_ID" || true
fi
