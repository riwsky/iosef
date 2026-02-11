#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_DIR="$ROOT_DIR/MCPTestApp"
DERIVED_DATA="$PROJECT_DIR/DerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/MCPTestApp.app"
BUNDLE_ID="com.mcp-test.playground"

echo "==> Building MCPTestApp..."
xcodebuild build \
    -project "$PROJECT_DIR/MCPTestApp.xcodeproj" \
    -scheme MCPTestApp \
    -destination 'generic/platform=iOS Simulator' \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    -quiet

echo "==> Installing on booted simulator..."
xcrun simctl install booted "$APP_PATH"

echo "==> Launching $BUNDLE_ID..."
xcrun simctl launch --console-pty booted "$BUNDLE_ID"
