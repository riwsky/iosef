# iosef

A fast, native Swift CLI and [MCP server](https://modelcontextprotocol.io/) for controlling iOS Simulator — tap, swipe, type, screenshot, and read the accessibility tree, all without idb or any companion app.

## Architecture

```
iosef start --local --device "X"   →  creates/boots simulator, saves state to .iosef/state.json
iosef tap / type / view             →  reads state.json, performs action, exits
iosef mcp                          →  long-running MCP server (stdio), same capabilities
iosef stop                         →  shuts down simulator, deletes device, cleans up state
```

Each CLI invocation is a short-lived process. The simulator runs independently and persists between commands.

## Installation

This Swift tool can be installed directly [from PyPI](https://pypi.org/project/iosef/) using `pip` or `uv`.

You can run it without installing it first using `uvx`:

```bash
uvx iosef --help
```

Or install it, then run `iosef --help`:

```bash
uv tool install iosef
# or
pip install iosef
```

You can also build from source:

```bash
swift build -c release
# or
./scripts/build.sh   # builds + installs to ~/.local/bin/iosef
```

Compiled binaries are available [on the releases page](https://github.com/riwsky/iosef/releases).

Building from source requires Swift 6.1+, macOS 13+, and Xcode with an iOS simulator runtime installed.

## Usage

### Start/stop the simulator

```bash
iosef start --local --device "my-sim"     # Create + boot simulator, local session
iosef start --device "iPhone 16 Pro" --device-type "iPhone 16 Pro" --runtime "iOS 18.4"
iosef connect "iPhone 16" --local         # Associate with an existing simulator
iosef status                              # Show simulator name, UDID, state, session info
iosef status --json                       # Machine-readable output
iosef stop                                # Shut down, delete device, remove session
```

### Inspect the UI

```bash
iosef describe_all                        # Dump the full accessibility tree
iosef describe_all --depth 2              # Limit tree depth
iosef describe_all --json | jq '.. | objects | select(.role == "button")'

iosef describe_point --x 200 --y 400     # What's at this coordinate?
iosef describe_point --x 200 --y 400 --json | jq '.content[0].text'

iosef view                                # Screenshot to temp file (prints path)
iosef view --output /tmp/screen.png       # Screenshot to specific file
iosef view --output /tmp/screen.jpg --type jpeg
```

### Interact

```bash
iosef tap --name "Sign In"                    # Find element + tap (preferred)
iosef tap --role AXButton --name "Submit"
iosef tap --name "Menu" --duration 0.5        # Long-press by selector

iosef tap_point --x 200 --y 400              # Tap at coordinates
iosef tap_point --x 100 --y 300 --duration 0.5 # Long-press at coordinates

iosef type --text "Hello World"               # Type into the focused field
iosef type --name "Search" --text "query"     # Find + tap + type in one step
iosef type --role AXTextField --text "hello"

iosef swipe --x-start 200 --y-start 600 --x-end 200 --y-end 200
iosef swipe --x-start 200 --y-start 600 --x-end 200 --y-end 200 --duration 0.3
```

### Selector commands

Search and query by `--role`, `--name`, and `--identifier`. Multiple criteria combine with AND logic.

```bash
iosef find --role AXButton                    # All buttons
iosef find --name "Sign In"                   # Elements matching label (substring, case-insensitive)
iosef find --role AXStaticText --name "count"  # Combine selectors

iosef exists --name "Sign In"                 # Prints "true"/"false", exit 0/1
iosef count --role AXButton                   # How many buttons?
iosef text --name "Tap count"                 # Extract text content from first match

iosef wait --name "Welcome"                   # Poll until element appears (default 10s)
iosef wait --role AXButton --name "Continue" --timeout 5
```

### App management

```bash
iosef install_app --app-path /path/to/MyApp.app   # Install .app or .ipa bundle
iosef launch_app --bundle-id com.apple.mobilesafari
iosef launch_app --bundle-id com.example.myapp --terminate-running
```

### Logging

```bash
iosef log_show --process SpringBoard --last 5s
iosef log_show --predicate 'subsystem == "com.apple.UIKit"' --last 3s
iosef log_show --level debug --last 1m

iosef log_stream --process SpringBoard --duration 3
iosef log_stream --predicate 'process == "MyApp"' --duration 10
```

### MCP server

```bash
iosef mcp    # Start MCP server on stdio
```

Every CLI subcommand is also available as an MCP tool. Configure in your MCP client:

```json
{
  "mcpServers": {
    "iosef": {
      "command": "iosef",
      "args": ["mcp"]
    }
  }
}
```

## Coordinate system

All commands use iOS points. Screenshots are coordinate-aligned: 1 pixel = 1 iOS point.

The accessibility tree reports positions as `(center±half-size)` — the center value is the tap target. For example, an element at `(195±39, 420±22)` has its center at (195, 420) and spans from x=156 to x=234 and y=398 to y=442. Use the center values directly with `tap_point --x 195 --y 420`.

This means visual agents can tap exactly where they see elements in screenshots, with no coordinate translation layer.

## Directory-scoped sessions

By default, iosef stores state globally in `~/.iosef/`. You can instead create a session scoped to the current directory with `--local`:

```bash
iosef start --local --device "my-sim"   # State stored in ./.iosef/state.json
iosef tap --name "Sign In"              # Auto-detects local session
iosef stop                              # Cleans up local session
```

**Auto-detection:** When neither `--local` nor `--global` is specified, iosef checks for `./.iosef/state.json` in the current directory. If found, it uses the local session; otherwise it falls back to the global `~/.iosef/` session.

```bash
# Force global even when a local session exists
iosef --global tap_point --x 200 --y 400

# Force local
iosef --local status
```

**Device resolution** (when `--device` is omitted):

1. `state.json` device field (local session, then global)
2. VCS root directory name (git or jj)
3. Any booted simulator

Add `.iosef/` to your `.gitignore` to keep session state out of version control.

## Exit codes

| Exit code | Meaning |
|---|---|
| `0` | Success |
| `1` | Check failed (`exists` returned false) or tool error |
| `2` | Bad arguments or usage error |

This makes it easy to distinguish "the check didn't pass" from "the command couldn't run" in scripts.

## Shell scripting examples

```bash
#!/bin/bash
set -euo pipefail

FAIL=0

check() {
    if ! "$@"; then
        echo "FAIL: $*"
        FAIL=1
    fi
}

# Boot and launch
iosef start --local --device "test-sim"
iosef install_app --app-path ./build/MyApp.app
iosef launch_app --bundle-id com.example.myapp

# Wait for the app to load
iosef wait --name "Welcome" --timeout 15

# Log in
iosef type --name "Email" --text "user@example.com"
iosef type --name "Password" --text "hunter2"
iosef tap --name "Sign In"

# Verify we landed on the dashboard
iosef wait --name "Dashboard" --timeout 10
check iosef exists --name "Dashboard"
check iosef exists --role AXButton --name "Settings"

# Take a screenshot for the record
iosef view --output /tmp/dashboard.png

iosef stop

if [ "$FAIL" -ne 0 ]; then
    echo "Some checks failed"
    exit 1
fi
echo "All checks passed"
```

## Configuration

| Environment Variable | Default | Description |
|---|---|---|
| `IOSEF_DEFAULT_OUTPUT_DIR` | `~/Downloads` | Default directory for screenshots |
| `IOSEF_TIMEOUT` | — | Override default timeout (seconds) |
| `IOSEF_FILTERED_TOOLS` | (none) | Comma-separated MCP tool names to hide |

State is stored in `~/.iosef/state.json` (global) or `./.iosef/state.json` (local). See [Directory-scoped sessions](#directory-scoped-sessions).

## Commands reference

| Command | Arguments | Description |
|---|---|---|
| `start` | `[--device N] [--device-type T] [--runtime R] [--local\|--global]` | Create/boot simulator, set up session |
| `stop` | | Shut down, delete simulator, remove session |
| `connect` | `<name-or-udid> [--local\|--global]` | Associate with an existing simulator |
| `status` | | Show simulator and session status |
| `install_app` | `--app-path <path>` | Install .app or .ipa bundle |
| `launch_app` | `--bundle-id <id> [--terminate-running]` | Launch app by bundle identifier |
| `describe_all` | `[--depth N]` | Dump full accessibility tree |
| `describe_point` | `--x X --y Y` | Get accessibility element at coordinates |
| `view` | `[--output <path>] [--type png\|jpeg\|tiff\|bmp\|gif]` | Capture screenshot |
| `tap` | `[--role R] [--name N] [--identifier I] [--duration S]` | Find element by selector + tap |
| `tap_point` | `--x X --y Y [--duration S]` | Tap at coordinates (long-press with duration) |
| `type` | `--text <text> [--role R] [--name N] [--identifier I]` | Type text; with selectors: find + tap + type |
| `swipe` | `--x-start X --y-start Y --x-end X --y-end Y [--delta N] [--duration S]` | Swipe between two points |
| `find` | `[--role R] [--name N] [--identifier I]` | Find elements by selector |
| `exists` | `[--role R] [--name N] [--identifier I]` | Check if element exists (exit 1 if not) |
| `count` | `[--role R] [--name N] [--identifier I]` | Count matching elements |
| `text` | `[--role R] [--name N] [--identifier I]` | Extract text from first match |
| `wait` | `[--role R] [--name N] [--identifier I] [--timeout S]` | Wait for element to appear |
| `log_show` | `[--last T] [--process P\|--predicate P] [--style S] [--level L]` | Show recent log entries |
| `log_stream` | `[--duration S] [--process P\|--predicate P] [--style S] [--level L]` | Stream live log entries |
| `mcp` | | Start MCP server (stdio transport) |

### Global flags

| Flag | Description |
|---|---|
| `--device <name-or-udid>` | Target simulator (auto-detected if omitted) |
| `--local` | Use directory-scoped session (`./.iosef/`) |
| `--global` | Use global session (`~/.iosef/`) |
| `--verbose` | Enable diagnostic logging to stderr |
| `--json` | Output results as JSON |
| `--version` | Print version and exit |
| `-h`, `--help` | Show help |

## Acknowledgments

This project draws inspiration from:

- [facebook/idb](https://github.com/facebook/idb) — Meta's iOS simulator CLI, where most of the simulator implementation ideas came from. In comparison, iosef trades off performance for a simpler interface (scaling screenshots to match iOS point space; targeting taps via accessibility labels) and deployment model (no companion process).
- [simonw/rodney](https://github.com/simonw/rodney) — Simon Willison's Chrome interaction CLI, where most of the interface ideas came from (subcommand names, session model, documentation structure). Iosef is arguably just "rodney, but for iOS".
- [joshuayoes/ios-simulator-mcp](https://github.com/joshuayoes/ios-simulator-mcp) — the original iOS Simulator MCP server. Got me interested in this space — iosef actually started out as an attempt to port this to swift for performance. Modern agents have a better time using CLI tools, though, leading to a shift in focus.
- [ldomaradzki/xctree](https://github.com/ldomaradzki/xctree) — another useful reference for working with the simulator's accessibility tree.

## License

MIT — see [LICENSE](LICENSE) for details.
