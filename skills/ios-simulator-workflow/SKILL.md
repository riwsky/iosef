---
name: ios-simulator-workflow
description: Validate iOS UI changes using the iOS Simulator. Use when building, testing, or verifying SwiftUI/UIKit changes on the iOS Simulator — tapping buttons, reading accessibility trees, testing drag-reorder, swipe-to-delete, scrolling, and general UI interaction. Invoke this skill whenever CLAUDE.md says to use the simulator for validation.
---

# iOS Simulator Workflow

Use `iosef` (via Bash) as the primary tool for all simulator interactions.

## Project Setup

Set up a project config directory so subsequent commands auto-detect the target simulator:

```bash
iosef start --local --device "my-sim-name"
```

This creates `.ios-simulator-mcp/config.json` in the current directory, boots the simulator, and opens Simulator.app. Without `--local`, config goes to `~/.ios-simulator-mcp/` (global).

## Build-Test Loop

1. Start the simulator: `iosef start --local --device "<name>"` (first time)
2. Build and launch the app (project-specific — check CLAUDE.md)
3. Interact — prefer selector commands (`tap_element`, `input`, `exists`, `wait`) over coordinate-based (`tap`, `swipe`). Use `describe_all` when you need to survey the full screen or elements lack stable labels.
4. Take a screenshot: `iosef view` (saves to `.ios-simulator-mcp/cache/`; use `--output /path/to/file.png` for a specific path)
5. Screenshot again after each action to verify result

## CLI Reference

All commands use named arguments. Tool names have no `ui_` prefix. Run `iosef <subcommand> --help` for full details.

### Selector Commands (preferred)

Use selector commands for 1-step interactions instead of describe_all → parse → tap:

```bash
# Tap by selector (replaces describe_all → parse → tap)
iosef tap_element --name "Sign In"
iosef tap_element --name "Menu" --duration 0.5  # long press

# Focus + type in one step (replaces tap → sleep → type)
iosef input --role AXTextField --text "hello"

# Find elements by role/name/identifier (AND logic)
iosef find --role AXButton --name "Submit"

# Quick queries
iosef exists --name "Error"          # "true" / "false"
iosef count --role AXButton           # "48"
iosef text --name "Score"             # extract text content

# Wait for UI state
iosef wait --name "Success" --timeout 5
```

**Prefer selector commands** when the element has a stable name or role. Fall back to coordinate-based commands for elements without useful labels or for swipe gestures.

### Coordinate-Based Commands

```bash
# AX tree — use when elements lack labels or you need to survey the full screen
iosef describe_all
iosef describe_all --depth 2    # limit tree depth
iosef describe_point --x 200 --y 400

# Tap
iosef tap --x 201 --y 740
iosef tap --x 201 --y 740 --duration 1.0   # long press

# Swipe / scroll
iosef swipe --x-start 200 --y-start 300 --x-end 200 --y-end 700 --duration 0.3

# Type text (requires a field to already have focus)
iosef type --text "hello"

# Screenshot (saves to .ios-simulator-mcp/cache/ by default)
iosef view
iosef view --output /tmp/sim.png  # explicit path

# Chain for rapid repeated actions
iosef tap --x 201 --y 740 && sleep 0.3 && iosef tap --x 201 --y 740
```

**Screenshot fallback**: If `view` fails with a Screen Recording error, use the MCP `view` tool instead.

## Reading the AX Tree

Always `describe_all` before interacting. The format is:

```
AXButton "Label" (center_x±half_width, center_y±half_height)
```

The **center values are the tap targets**. Example: `AXButton "Start" (197±160, 270±22)` → tap at (197, 270).

## Gestures

### Scroll

```bash
# Vertical scroll (short duration = scroll with momentum)
iosef swipe --x-start 200 --y-start 500 --x-end 200 --y-end 200 --duration 0.3

# Horizontal scroll
iosef swipe --x-start 300 --y-start 400 --x-end 100 --y-end 400 --duration 0.3
```

### Swipe-to-delete

```bash
iosef swipe --x-start 300 --y-start $ROW_Y --x-end 100 --y-end $ROW_Y --duration 0.3
```

### Drag-reorder (UITableView / UICollectionView)

UIKit's `UIDragInteraction` requires a **long press** (~0.5s stationary, <10pt movement) before the drag lifts. `tap` with duration won't work — it releases the finger.

Use a **slow swipe** so the first 0.5s stays within the 10pt tolerance:

```bash
iosef swipe \
  --x-start $HANDLE_X --y-start $ROW_Y \
  --x-end $HANDLE_X --y-end $TARGET_Y \
  --duration 8.0 --delta 1
```

**Math**: 52pt distance over 8s = 6.5 pt/sec. In the first 0.5s, only ~3pt of movement — well under the 10pt threshold.

**Guidelines**:
- Keep total distance 50–100pt (1–2 row heights)
- Duration 6–8 seconds
- Always delta=1
- Target the drag handle coordinates, not the row content

### Ensuring drag handles are targetable

UIKit `UIImageView` drag handles are often hidden from accessibility. Add labels so they appear in `describe_all`:

```swift
dragHandle.isAccessibilityElement = true
dragHandle.accessibilityLabel = "Reorder"
```

Then the AX tree shows: `AXImage "Reorder" (374±12, 221±7)` — use center (374, 221).

## Proof of Work

After verifying a feature works, capture it as a showboat demo:

**Critical: demos must be self-contained.** `showboat verify` replays every `exec` block from scratch. If a demo depends on app state (e.g. tasks in a queue), the demo must set that state up itself — typically by rebuilding the app and adding test data via simulator interactions. A demo that only captures the "interesting part" will fail verify.

```bash
showboat init demos/my-feature-demo.md "Feature Name Demo"
showboat note demos/my-feature-demo.md "Description of what we're demonstrating."
# Setup: build app and create any required state
showboat exec demos/my-feature-demo.md bash "./scripts/build.sh 2>&1 | tail -1"
showboat exec demos/my-feature-demo.md bash "sleep 1"
showboat exec demos/my-feature-demo.md bash "iosef tap_element --name 'Add' --device \$NAME_OR_UDID 2>/dev/null"
# ... more setup as needed ...
# Then the actual demo actions
showboat exec demos/my-feature-demo.md bash "iosef tap_element --name 'Button' --device \$NAME_OR_UDID 2>/dev/null"
showboat exec demos/my-feature-demo.md bash "iosef view --device \$NAME_OR_UDID --output /tmp/screenshot.png 2>/dev/null"
showboat image demos/my-feature-demo.md /tmp/screenshot.png
showboat verify demos/my-feature-demo.md  # must pass before done
```

**Timing**: Use `wait` commands (`iosef wait --name 'Expected' --timeout 5`) instead of fixed `sleep` for state that depends on async operations (e.g. WatchConnectivity sync). Fixed sleeps are flaky; `wait` is deterministic.

## Tips

- **Blank AX tree?** If `describe_all` returns only `AXApplication (0±0, 0±0)`, the simulator process is broken. Don't work around it with screenshots — kill and restart: `killall Simulator && sleep 2 && xcrun simctl boot "<device>" && open -a Simulator`, then rebuild and launch the app.
- **Selector commands first**: Use `tap_element`/`input`/`exists` when elements have stable names. Fall back to coordinates for unlabeled elements and swipe gestures.
- **AX tree first**: Never guess coordinates. Always read the tree.
- **Screenshot after every action**: Confirm the UI state changed as expected.
- **Identify elements by label**: If an element isn't in the AX tree, it lacks accessibility markup. Add `isAccessibilityElement` + `accessibilityLabel` and rebuild.
- **Gesture cheat sheet**: Short duration (0.2–0.5s) = scroll/swipe. Long duration (6–8s) + delta=1 = drag-reorder. `tap` with duration = long press (not drag).
- **Chain CLI calls**: Use `&&` to chain rapid sequential taps. Add `sleep 0.3` between if needed for animation settling.
