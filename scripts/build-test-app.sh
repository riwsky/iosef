#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Platform selection: ios, watchos, visionos, both (ios + watchos), or all
PLATFORM="${1:-both}"

# Determine simulator name from VCS root (mirrors computeDefaultDeviceName())
SIM_NAME="$(jj root 2>/dev/null || git rev-parse --show-toplevel 2>/dev/null || echo "$ROOT_DIR")"
SIM_NAME="$(basename "$SIM_NAME")"

# Quiet on success, verbose on failure — log persists for agent inspection
LOG_DIR="/tmp/iosef"
LOG="$LOG_DIR/build-test-app.log"
mkdir -p "$LOG_DIR"
echo "# build-test-app.sh — $(date -Iseconds)" > "$LOG"

quiet() {
    if ! "$@" >> "$LOG" 2>&1; then
        cat "$LOG"
        exit 1
    fi
}

# Regenerate the Xcode project from project.yml via XcodeGen. The .xcodeproj is
# gitignored and treated as a build artifact — adding/renaming source files only
# requires editing project.yml (no manual project.pbxproj surgery). Args: <dir> <name>.
generate_project() {
    local dir="$1" name="$2"
    if ! command -v xcodegen >/dev/null 2>&1; then
        if [ -d "$dir/$name.xcodeproj" ]; then
            return 0  # no generator, but a project already exists — use it
        fi
        echo "error: xcodegen not found and $name.xcodeproj is missing." >&2
        echo "Install it with: brew install xcodegen" >&2
        exit 1
    fi
    echo "==> Generating $name.xcodeproj from project.yml..."
    quiet bash -c "cd '$dir' && xcodegen generate"
}

# Find a simulator by exact name on a runtime family (e.g. iOS, watchOS, xrOS), return its UUID
get_simulator_id() {
    local name="$1" family="$2"
    xcrun simctl list devices -j | \
        python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data.get('devices', {}).items():
    if '$family' in runtime:
        for d in devices:
            if d['name'] == '$name' and d['isAvailable']:
                print(d['udid'])
                sys.exit(0)
" 2>/dev/null || true
}

# Newest available runtime whose name contains <name> (e.g. iOS, watchOS, visionOS)
get_latest_runtime() {
    local name="$1"
    xcrun simctl list runtimes -j | python3 -c "
import json, sys
data = json.load(sys.stdin)
runtimes = [r for r in data.get('runtimes', []) if '$name' in r.get('name', '') and r.get('isAvailable')]
if runtimes:
    print(runtimes[-1]['identifier'])
"
}

# Create (if needed), boot, build, install and launch one playground app.
# Args: <label> <sim name> <device family in runtime id> <runtime name> <device type>
#       <project dir> <scheme> <destination platform> <products dir> <bundle id>
build_platform() {
    local label="$1" sim_name="$2" family="$3" runtime_name="$4" device_type="$5"
    local project_dir="$6" scheme="$7" destination="$8" products="$9" bundle_id="${10}"
    local derived_data="$project_dir/DerivedData"

    local sim_id
    sim_id=$(get_simulator_id "$sim_name" "$family")
    if [ -z "$sim_id" ]; then
        sim_id=$(xcrun simctl create "$sim_name" "$device_type" "$(get_latest_runtime "$runtime_name")")
        echo "Created $label simulator '$sim_name' ($sim_id)"
    fi

    # Boot in the background of the build; we only wait for it before installing.
    if ! xcrun simctl list devices | grep "$sim_id" | grep -q "Booted"; then
        xcrun simctl boot "$sim_id" >> "$LOG" 2>&1 || true
    fi

    generate_project "$project_dir" "$scheme"

    echo "==> Building $scheme for simulator '$sim_name' ($sim_id)..."
    quiet xcodebuild build \
        -project "$project_dir/$scheme.xcodeproj" \
        -scheme "$scheme" \
        -destination "platform=$destination,id=$sim_id" \
        -configuration Debug \
        -derivedDataPath "$derived_data"

    # A freshly created simulator takes a while to come up, and launching before it has
    # finished is refused (notably by visionOS's SurfBoard).
    quiet xcrun simctl bootstatus "$sim_id" -b

    echo "==> Installing on $sim_name..."
    quiet xcrun simctl install "$sim_id" "$derived_data/Build/Products/$products/$scheme.app"

    echo "==> Launching $bundle_id..."
    xcrun simctl launch "$sim_id" "$bundle_id" || true
}

case "$PLATFORM" in
    ios|both|all)
        build_platform iOS "$SIM_NAME" iOS iOS \
            com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
            "$ROOT_DIR/MCPTestApp" MCPTestApp "iOS Simulator" Debug-iphonesimulator \
            com.mcp-test.playground ;;
esac

case "$PLATFORM" in
    watchos|both|all)
        build_platform watchOS "${SIM_NAME}-watch" watchOS watchOS \
            com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Ultra-2-49mm \
            "$ROOT_DIR/WatchTestApp" WatchTestApp "watchOS Simulator" Debug-watchsimulator \
            com.mcp-test.playground.watchapp ;;
esac

case "$PLATFORM" in
    visionos|all)
        # The 4K variant is the 1920x1080-point device iosef's gaze model is calibrated for.
        build_platform visionOS "${SIM_NAME}-vision" xrOS visionOS \
            com.apple.CoreSimulator.SimDeviceType.Apple-Vision-Pro-4K \
            "$ROOT_DIR/VisionTestApp" VisionTestApp "visionOS Simulator" Debug-xrsimulator \
            com.mcp-test.playground.visionapp ;;
esac
