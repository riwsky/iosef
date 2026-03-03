---
name: ios-simulator-interaction
description: >-
  Interaction with the iOS simulator using iosef, a CLI optimized for agent
  usage. Use when building or testing changes on the iOS Simulator — viewing
  the screen, tapping buttons, reading accessibility trees, finding elements
  by selector, asserting UI state, scripting multi-step test flows, installing
  and launching apps, reading simulator logs, or performing gestures like
  drag-reorder, swipe-to-delete, and scrolling. If you're doing anything with
  an iOS simulator, use this skill.
---

# iOS Simulator Interaction

Use `iosef` (via Bash) as the primary tool for all iOS simulator interactions. Compared to `idb` and `simctl`, it:
* Lets you interact by AX-tree selectors (`--name`, `--role`, `--identifier`) instead of only bare coordinates
* Scales screenshots so pixel coordinates match iOS point space — no translation needed
* Infers which simulator to use from VCS root or session state
* Provides dedicated assert commands (`exists`, `count`, `text`, `wait`) with exit codes for scripting

## Getting Started

**Session lifecycle:**

```bash
# Create a local session (scoped to this directory)
iosef start --local --device "my-sim"

# ... do work (tap, type, describe, view, etc.) ...

# Tear down — shuts down simulator, deletes device, removes .iosef/
iosef stop
```

Use `--local` to avoid interfering with simulators used by other agents. Session state lives in `.iosef/state.json` — ensure `.iosef/` is in `.gitignore`.

For existing simulators: `iosef connect "iPhone 16" --local`

Check session state anytime: `iosef status` (or `iosef status --json`)

## Core Workflow

### Inspect: describe and view

Always start with `iosef describe` to get the accessibility tree. The format is:

```
AXButton "Label" (center_x±half_width, center_y±half_height)
```

The **center values are the tap targets**. Example: `AXButton "Start" (197±160, 270±22)` → tap at (197, 270).

```bash
iosef describe                        # Full AX tree
iosef describe --depth 2              # Limit tree depth
iosef describe --x 200 --y 400       # What's at this coordinate?
iosef describe --json | jq '.. | objects | select(.role == "button")'
```

Use `iosef view` for screenshots (not `simctl` or `idb` — iosef aligns coordinate spaces):

```bash
iosef view                            # Screenshot to temp file (prints path)
iosef view --output /tmp/screen.png   # Screenshot to specific path
```

### Interact: tap, type, swipe

**Prefer selectors over coordinates** — selectors survive layout changes and scroll position shifts.

```bash
iosef tap --name "Sign In"                    # Find element + tap
iosef tap --role AXButton --name "Submit"     # Combine selectors
iosef tap --name "Menu" --duration 0.5        # Long-press
iosef tap --x 200 --y 400                     # Coordinate fallback
```

`type` combines find + tap + type in one step when given selectors:

```bash
iosef type --text "Hello World"               # Type into focused field
iosef type --name "Search" --text "query"     # Find field + tap + type
iosef type --identifier "text_field" --text "hello"
```

```bash
iosef swipe --x-start 200 --y-start 600 --x-end 200 --y-end 200
iosef swipe --x-start 200 --y-start 600 --x-end 200 --y-end 200 --duration 0.3
```

### Assert: exists, count, text, wait

Dedicated commands for checking UI state — no need to `describe | grep`.

```bash
iosef exists --name "Sign In"                 # Prints "true"/"false", exit 0 or 1
iosef count --role AXButton                   # Prints number of matches
iosef text --name "Tap count"                 # Extracts text content from first match
iosef text --identifier "tap_count_label"     # By accessibilityIdentifier

iosef wait --name "Welcome"                   # Poll until element appears (default 10s)
iosef wait --name "Continue" --timeout 5      # Custom timeout
```

Use `wait` instead of `sleep` — it's deterministic and returns as soon as the element appears.

## Selectors

Three selector flags, composable with AND logic:

| Flag | Matching | Example |
|---|---|---|
| `--name "text"` | Case-insensitive **substring** on label or title | `--name "Sign"` matches "Sign In" |
| `--identifier "id"` | **Exact** match on `accessibilityIdentifier` | `--identifier "grid_2_3"` |
| `--role AXType` | Case-insensitive **exact** match on role | `--role AXButton` |

Combine them: `iosef tap --role AXButton --name "Submit"` matches only buttons whose label contains "Submit".

`find` lets you explore what's available: `iosef find --role AXButton` lists all buttons.

## Chaining and Scripting

Chain multiple commands in one Bash call to save round trips:

```bash
iosef tap --name "Sign In" && iosef wait --name "Dashboard" --timeout 10
```

**Exit codes** for scripting conditionals:

| Code | Meaning |
|---|---|
| `0` | Success (or check passed) |
| `1` | Check failed (`exists` → false) or runtime error |
| `2` | Bad arguments / usage error |

Use in scripts:

```bash
if iosef exists --name "Error"; then
    echo "Error dialog appeared"
    exit 1
fi
```

For complex flows, parse `--json` output:

```bash
COUNT=$(iosef count --role AXButton --json | jq '.count')
```

## App Management

```bash
iosef install_app --app-path ./build/MyApp.app
iosef launch_app --bundle-id com.example.myapp
iosef launch_app --bundle-id com.example.myapp --terminate-running  # Kill + relaunch
```

## Logging

Read simulator logs to verify app behavior:

```bash
iosef log_show --process MyApp --last 5s           # Recent entries from a process
iosef log_show --predicate 'process == "MyApp"' --last 3s
iosef log_show --level debug --last 1m

iosef log_stream --process SpringBoard --duration 3  # Live stream for N seconds
iosef log_stream --predicate 'process == "MyApp"' --duration 10
```

Useful for verifying callbacks fired, checking error messages, or debugging UI state.

## Advanced Gestures

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

UIKit `UIImageView` drag handles are often hidden from accessibility. Add labels so they appear in `describe`:

```swift
dragHandle.isAccessibilityElement = true
dragHandle.accessibilityLabel = "Reorder"
```

Then the AX tree shows: `AXImage "Reorder" (374±12, 221±7)` — use center (374, 221).

## Command Quick Reference

**Session**

| Command | Purpose |
|---|---|
| `start --local --device "N"` | Create + boot simulator, local session |
| `connect "N" --local` | Associate with existing simulator |
| `status` | Show simulator name, UDID, state |
| `stop` | Shut down, delete device, remove session |

**Inspect**

| Command | Purpose |
|---|---|
| `describe` | Full AX tree |
| `describe --depth N` | Limit tree depth |
| `describe --x X --y Y` | Element at coordinate |
| `view --output path.png` | Coordinate-aligned screenshot |

**Interact**

| Command | Purpose |
|---|---|
| `tap --name "N"` | Tap by selector |
| `tap --x X --y Y` | Tap at coordinates |
| `tap --name "N" --duration S` | Long-press |
| `type --name "N" --text "T"` | Find + tap + type |
| `type --text "T"` | Type into focused field |
| `swipe --x-start/y-start/x-end/y-end` | Swipe gesture |

**Assert**

| Command | Purpose |
|---|---|
| `exists --name "N"` | Check presence (exit 0/1) |
| `count --role AXButton` | Count matching elements |
| `text --identifier "id"` | Extract text from first match |
| `wait --name "N" --timeout S` | Poll until element appears |
| `find --role AXButton` | List matching elements |

**App & Logs**

| Command | Purpose |
|---|---|
| `install_app --app-path P` | Install .app or .ipa |
| `launch_app --bundle-id B` | Launch app |
| `log_show --process P --last T` | Recent log entries |
| `log_stream --process P --duration S` | Live log stream |

All commands accept `--json` for machine-readable output and `--device` to target a specific simulator.

## Demos with showboat

For user-facing demos, use [showboat](https://github.com/simonw/showboat) (`uvx showboat`). Tips:
- Include session start/stop in the showboat script — demos should be self-contained
- Use selector-based interactions (more robust across replays)
- For coordinate-dependent actions (scrolling), chain `iosef describe --json` to grab coordinates at replay time
- Use `iosef wait` instead of `sleep` for timing

## Troubleshooting

- **Blank AX tree?** If `describe` returns only `AXApplication (0±0, 0±0)`, the simulator process is broken. Kill and restart: `killall Simulator && sleep 2 && xcrun simctl boot "<device>" && open -a Simulator`, then rebuild and launch the app.
- **Missing elements in AX tree?** Some `AXGroup` containers don't appear in top-level `describe` — try a point-wise describe on the container's coordinates, or fall back to screenshots.
- **No accessibility labels?** Add them to the source — it improves the UX for all users, not just automation. Let the user know when you do this.
- **Worktree cleanup**: For worktree-based workflows, consider a `WorktreeRemove` hook that runs `xcrun simctl delete "$NAME"` to prevent orphaned simulators.
- **Selector not matching?** Remember: `--name` is a case-insensitive substring (so `--name "Sign"` matches "Sign In"), while `--identifier` is exact.
