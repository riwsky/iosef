---
name: ios-simulator-interaction
description: Interaction with the iOS simulator using iosef, a CLI optimized for agent usage. Use when building or testing changes on the iOS Simulator — viewing the screen, tapping buttons, reading accessibility trees, testing drag-reorder, swipe-to-delete, or scrolling.
---

# iOS Simulator Interaction

Use `iosef` (via Bash) as the primary tool for all iOS simulator interactions. Compared to `idb` and `simctl`, it makes your life easier by:
* allowing you to interact (tap, input, etc) by AXtree selectors instead of only by bare coordinates
* scaling screenshots so their coordinate space matches the tool coordinates
* inferring which simulator to used based on VCS root, or explicit session establishment (see `iosef start --help` or `iosef connect --help`)

Always run `iosef --help` at least once, to get a sense of how it works. You can also pass `--help` to subcommands for details on their arguments.

Local session state is kept in `.iosef` in the current directory, so ensure that's in `.gitignore` to keep it out of version control history.


## Recommendations when using iosef

* Make use of --local sessions with `iosef start`/`connect` to avoid accidentally interfering with simulators being used by other agents on the system.
* `iosef describe`, with no arguments, will give you the accessibility tree - a much more compact starting point than screenshots
* Prefer selector-based targeting to coordinate-based targeting, as selectors are more robust (to e.g. scroll position) and don't require you to recheck the accessibility tree on reuse.
* Remember that you can chain multiple commands together using your bash tools, to save yourself some round trips.
* Prefer `iosef view` to other screenshot methods like `simctl` or `idb`, since it lines up the coordinate spaces for you.
* For even more complicated chaining, consider writing small scripts that parse `--json` output.

## Reading the AX Tree

Always `iosef describe` at the start of your usage. The format is:

```
AXButton "Label" (center_x±half_width, center_y±half_height)
```

The **center values are the tap targets**. Example: `AXButton "Start" (197±160, 270±22)` → tap at (197, 270).

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

## Cleanup

When you're done with a simulator session:

```bash
iosef stop
```

This shuts down the simulator, deletes the device, and removes the session directory.

For worktree-based workflows where each worktree gets its own simulator, consider adding a `WorktreeRemove` hook that runs `xcrun simctl delete "$NAME"` to prevent orphaned simulators from accumulating.

## Proof of Work

If a user request a demo or walkthrough, consider using [simonw/showboat](https://github.com/simonw/showboat). If users don't already have it installed, you can run it without installing it first by using `uvx showboat --help`.

General usage of `showboat` is better understood via it's own documentation, but some `iosef`-specific tips include:

* remember to include the session start and stop portions in the showboat script - they're designed to be replayed, so they shouldn't assume a certain simulator already exists
* also ensure the showboat script includes whatever's needed to set up expected app state
* use the selector-based interaction forms, as they're more robust. If demoing something that is naturally coordinate-based, like scrolling, consider chaining `iosef describe --json` to grab coordinates at showboat replay time instead of baking in the coordinates at creation time.


```bash
showboat init demos/my-feature-demo.md "Feature Name Demo"
showboat note demos/my-feature-demo.md "Description of what we're demonstrating."
# Setup: build app and create any required state
showboat exec demos/my-feature-demo.md bash "./scripts/build.sh 2>&1 | tail -1"
showboat exec demos/my-feature-demo.md bash "sleep 1"
showboat exec demos/my-feature-demo.md bash "iosef tap --name 'Add' --device \$NAME_OR_UDID 2>/dev/null"
# ... more setup as needed ...
# Then the actual demo actions
showboat exec demos/my-feature-demo.md bash "iosef tap --name 'Button' --device \$NAME_OR_UDID 2>/dev/null"
showboat exec demos/my-feature-demo.md bash "iosef view --device \$NAME_OR_UDID --output /tmp/screenshot.png 2>/dev/null"
showboat image demos/my-feature-demo.md /tmp/screenshot.png
showboat verify demos/my-feature-demo.md  # must pass before done
```

**Timing**: Use `wait` commands (`iosef wait --name 'Expected' --timeout 5`) instead of fixed `sleep` for state that depends on async operations (e.g. WatchConnectivity sync). Fixed sleeps are flaky; `wait` is deterministic.

## Troubleshooting

- **Blank AX tree?** If `describe` returns only `AXApplication (0±0, 0±0)`, the simulator process is probably broken. Don't work around it with screenshots — kill and restart: `killall Simulator && sleep 2 && xcrun simctl boot "<device>" && open -a Simulator`, then rebuild and launch the app.
- **Code doesn't have accessibility labels?**: Add them - it'd improve the UX for more than just yourself. Let the user know if/when you do this.
- **Not seeing elements and labels expected in the AXTree?** Some container elements like `AXGroup`s don't naturally show up in the top level describe calls - an issue that also afflicts `idb`, and is seemingly a bug in Apple's frameworks. Sometimes this can be resolved by doing a point-wise describe on the coordinates of the container, but you might need to fall back to screenshots.
