# Rodney Feature Comparison — New CLI Commands

Comparison between [rodney](https://github.com/simonw/rodney) (Chrome automation CLI) and **ios-simulator-mcp-swift**, with recommendations for new commands.

## Feature Matrix

| Rodney command | Our equivalent | Gap |
|---|---|---|
| `ax-tree --depth N` | `ui_describe_all` | No depth limit |
| `ax-find --role R --name N` | None | Must parse full tree manually |
| `ax-node SELECTOR` | `ui_describe_point` (coord-based only) | No symbolic lookup |
| `wait SELECTOR` | None | No wait-for-element |
| `exists SELECTOR` / `visible SELECTOR` | None | No existence checks |
| `count SELECTOR` | None | No element counting |
| `click SELECTOR` | `ui_tap --x --y` (coord-only) | No symbolic tap |
| `input SELECTOR TEXT` | `ui_tap` + `ui_type` (two commands) | No single-command input by selector |
| `text SELECTOR` | None | Must parse AX tree for values |
| `assert EXPR [EXPECTED]` | None | No built-in assertions |

### Things rodney has that don't apply

These are Chrome-specific and not relevant:
- `start`/`stop`/`connect` — browser lifecycle (we have `open_simulator`/`get_booted_sim_id`)
- `open URL`/`back`/`forward`/`reload` — page navigation
- `html`/`attr`/`js`/`pdf` — DOM/JS access
- `waitload`/`waitstable`/`waitidle` — page load states
- `pages`/`page`/`newpage`/`closepage` — tab management
- `select`/`submit`/`file`/`download` — form elements

## Proposed New Commands

### AX Selectors — the common building block

All new commands use **AX selectors**, the iOS accessibility equivalent of CSS selectors:

| Flag | Matches | Example |
|---|---|---|
| `--role ROLE` | AX role (case-insensitive) | `--role button` |
| `--name NAME` | Label/title (substring, case-insensitive) | `--name "Sign In"` |
| `--id ID` | `accessibilityIdentifier` (exact match) | `--id text_field` |

Flags compose with AND logic: `--role button --name Submit` matches buttons whose label contains "Submit".

### Implementation: `AXSelector.swift`

New file: `Sources/SimulatorKit/Accessibility/AXSelector.swift`

```swift
public struct AXSelector {
    public let role: String?       // case-insensitive match against AX role
    public let name: String?       // case-insensitive substring match against label/title
    public let identifier: String? // exact match against accessibilityIdentifier

    public func matches(_ node: TreeNode) -> Bool {
        if let role, node.role.lowercased() != role.lowercased() { return false }
        if let name, !node.label.localizedCaseInsensitiveContains(name) { return false }
        if let identifier, node.identifier != identifier { return false }
        return true
    }
}
```

Extend `TreeSerializer` with `find(matching:maxDepth:) -> [TreeNode]` to walk the tree and return matches.

---

### Tier 1 — High value, implement together

**1. `ui_find`** — Search AX tree by role/name/identifier

```
ios_simulator_cli ui_find [--role ROLE] [--name NAME] [--id ID] [--first] [--json] [--udid UDID]
```

Returns matching nodes with frames. Exit code 0 if matches, 1 if none. `--first` returns only the first match. Foundation for all other selector-based commands.

Example:
```bash
# Find all buttons
ios_simulator_cli ui_find --role button

# Find a specific button by label
ios_simulator_cli ui_find --role button --name "Submit" --first

# Machine-readable for scripting
ios_simulator_cli ui_find --role textField --json
```

**2. `ui_exists`** — Check element existence

```
ios_simulator_cli ui_exists [--role ROLE] [--name NAME] [--id ID] [--udid UDID]
```

Prints `true`/`false`, exit code 0/1. Enables shell conditionals:
```bash
if ios_simulator_cli ui_exists --role button --name Submit; then
  echo "Submit button found"
fi
```

**3. `ui_count`** — Count matching elements

```
ios_simulator_cli ui_count [--role ROLE] [--name NAME] [--id ID] [--udid UDID]
```

Prints integer count. Useful for verifying list lengths, grid sizes, etc.

**4. `ui_text`** — Extract text/value from element

```
ios_simulator_cli ui_text [--role ROLE] [--name NAME] [--id ID] [--udid UDID]
```

Prints label, title, or value of first match. Enables:
```bash
COUNTER=$(ios_simulator_cli ui_text --role staticText --name "Tap count")
echo "Current count: $COUNTER"
```

**5. `ui_tap_element`** — Tap by selector (no coordinates needed)

```
ios_simulator_cli ui_tap_element [--role ROLE] [--name NAME] [--id ID] [--duration D] [--udid UDID]
```

Finds element -> computes center from frame -> sends tap via IndigoHID. Eliminates the "read AX tree, parse coordinates, tap" loop:
```bash
# Before: 3-step process
COORDS=$(ios_simulator_cli ui_find --role button --name Submit --first --json | jq '.x, .y')
ios_simulator_cli ui_tap --x ... --y ...

# After: 1 command
ios_simulator_cli ui_tap_element --role button --name Submit
```

**6. `ui_input`** — Tap field by selector, then type

```
ios_simulator_cli ui_input [--role ROLE] [--name NAME] [--id ID] --text TEXT [--udid UDID]
```

Composes: find element -> tap center -> brief delay -> type text. Replaces the common 3-command pattern:
```bash
# Before
ios_simulator_cli ui_tap --x 222 --y 524
sleep 0.3
ios_simulator_cli ui_type --text "hello"

# After
ios_simulator_cli ui_input --id text_field --text "hello"
```

### Tier 2 — Robustness features

**7. `ui_wait`** — Wait for element to appear

```
ios_simulator_cli ui_wait [--role ROLE] [--name NAME] [--id ID] [--timeout SECS] [--udid UDID]
```

Polls AX tree every 250ms until match or timeout (default 10s). Exit 0=found, 2=timeout. Critical for animations, navigation transitions, and async state changes:
```bash
ios_simulator_cli ui_tap_element --role button --name "Load Data"
ios_simulator_cli ui_wait --role staticText --name "Results" --timeout 15
ios_simulator_cli ui_view --output /tmp/results.png
```

Rodney's `wait` is its most-used command for test scripting — agents constantly need to wait for UI state to settle.

**8. `--depth N` flag on `ui_describe_all`**

Limits AX tree recursion depth. Useful for large UIs where agents only need top-level structure. Rodney's `ax-tree --depth 2` is frequently used to get a quick overview without dumping hundreds of nodes.

### Tier 3 — Nice to have (lower priority)

**9. Exit code semantics** (adopt from rodney)

Rodney distinguishes exit code 1 (check failed, e.g. element not found) from exit code 2 (error, e.g. bad arguments, timeout). This is valuable for shell scripting:
```bash
ios_simulator_cli ui_exists --role button --name Submit
case $? in
  0) echo "Found" ;;
  1) echo "Not found" ;;
  2) echo "Error occurred" ;;
esac
```

We should adopt this convention across all new commands.

## Files to Modify

| File | Change |
|---|---|
| `Sources/SimulatorKit/Accessibility/AXSelector.swift` | **New file** — selector struct + matching logic |
| `Sources/SimulatorKit/Accessibility/TreeSerializer.swift` | Add `find(matching:maxDepth:)` and `flatten()` methods |
| `Sources/ios_simulator_cli/SimulatorMCPCommand.swift` | New `AsyncParsableCommand` structs + MCP tool definitions |

## Implementation Notes

- All new commands follow the existing CLI pattern in `SimulatorMCPCommand.swift` (lines 936-1250): `AsyncParsableCommand` structs with `--verbose`, `--json`, `--udid` flags
- Register new commands in the `subcommands` array (line 839)
- Add corresponding MCP tool definitions and handlers for each command
- `ui_find` is the foundation — `ui_exists`, `ui_count`, `ui_text`, `ui_tap_element`, `ui_input`, and `ui_wait` all compose on top of it
- The `TreeNode` type already has `role`, `label`, and `frame` — we just need to add the filtering/search layer
