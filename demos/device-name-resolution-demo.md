# Device Name Resolution

*2026-02-20T05:44:35Z by Showboat 0.6.0*
<!-- showboat-id: 166736f9-cacd-4cf5-9b0b-b857a126af49 -->

The `--device` flag (and MCP `udid` parameter) now accepts either a simulator name or a UUID. Names are auto-detected by format — UUIDs match 8-4-4-4-12 hex, everything else is treated as a name. Error messages are actionable: shutdown sims get boot commands, nonexistent sims get create commands.

## 1. Happy path — target by name

Instead of looking up a UDID, just pass the simulator name:

```bash
.build/release/iosef describe_all --device "ios-simulator-mcp-swift" 2>/dev/null | head -4
```

```output
AXApplication " " (197±197, 426±426)
  AXButton "Maps" (106±81, 170±92) value="Widget"
  AXButton "Calendar" (287±81, 170±92) value="Widget, Stack"
  AXButton "Calendar" (61±36, 317±43) value="Friday, February 20"
```

```bash
.build/release/iosef view --device "ios-simulator-mcp-swift" --output /tmp/device-name-demo.png 2>/dev/null
```

```output
Screenshot saved to /tmp/device-name-demo.png
```

```bash {image}
/tmp/device-name-demo.png
```

![0ee8f6cb-2026-02-20](0ee8f6cb-2026-02-20.png)

## 2. Happy path — target by UUID

UUIDs still work exactly as before — they're detected by their 8-4-4-4-12 hex format:

```bash
.build/release/iosef describe_all --device 6C07B68F-054D-434D-B5D7-6C52DCE7D78B 2>/dev/null | head -4
```

```output
AXApplication " " (197±197, 426±426)
  AXButton "Maps" (106±81, 170±92) value="Widget"
  AXButton "Calendar" (287±81, 170±92) value="Widget, Stack"
  AXButton "Calendar" (61±36, 317±43) value="Friday, February 20"
```

## 3. Backwards compat — `--udid` alias

The old `--udid` flag still works as a hidden alias:

```bash
.build/release/iosef describe_all --udid 6C07B68F-054D-434D-B5D7-6C52DCE7D78B 2>/dev/null | head -4
```

```output
AXApplication " " (197±197, 426±426)
  AXButton "Maps" (106±81, 170±92) value="Widget"
  AXButton "Calendar" (287±81, 170±92) value="Widget, Stack"
  AXButton "Calendar" (61±36, 317±43) value="Friday, February 20"
```

## 4. Unhappy path — shutdown simulator

When targeting a simulator that exists but is shutdown, the error includes the exact boot commands:

```bash
.build/release/iosef view --device "bandwith" 2>&1 || true
```

```output
Tool returned error
Error: Simulator "bandwith" (77B19D8C-A775-4E42-96E0-46563815B313) is shutdown. Boot it with:
  xcrun simctl boot "bandwith" && open -a Simulator
```

Same error with a UUID pointing to a shutdown sim:

```bash
.build/release/iosef view --device 77B19D8C-A775-4E42-96E0-46563815B313 2>&1 || true
```

```output
Tool returned error
Error: Simulator "bandwith" (77B19D8C-A775-4E42-96E0-46563815B313) is shutdown. Boot it with:
  xcrun simctl boot "bandwith" && open -a Simulator
```

## 5. Unhappy path — nonexistent simulator

When the name doesn't match any simulator, the error suggests how to create one:

```bash
.build/release/iosef view --device "my-cool-project" 2>&1 || true
```

```output
Tool returned error
Error: No simulator found with name "my-cool-project". Create one with: xcrun simctl create "my-cool-project" "iPhone 16"
```

## 6. CLI help — updated flag

The help text reflects the new `--device` flag:

```bash
.build/release/iosef view --help 2>&1 | grep -A1 "\-\-device"
```

```output
USAGE: iosef view [--verbose] [--json] [--device <device>] [--output <output>] [--type <type>]

--
  --device, --udid <device>
                          Simulator name or UDID (auto-detected if omitted)
```
