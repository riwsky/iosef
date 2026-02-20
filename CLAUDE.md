# ios-simulator-mcp-swift

An attempt at a swift port of joshuayoes/ios-simulator-mcp, with a few goals:

1. ease of installation: the original mcp depends on idb, which itself requires a companion app. It's a lot of moving parts.
2. speed: commands like "ui_tap" or "ui_view" are in the hot loop of agents interacting with the simulator. By staying in one process as much as possible, and directly leveraging the relevant APIs, we should be able to shave a bunch of time off this.
3. bug fixing: sometimes idb returns (0,0) for its accesibility frame dimensions. I don't know what causes this. But even if I did, altering it (especially in a maintainable, upstreamable way) would be harder than altering a dedicated codebase

# Work guidelines

*Exploring git:* You will, reasonably, often want or be directed to compare code against how joshuayoes/ios-simulator-mcp or facebook/idb do it. Do NOT compare by browsing raw.githubcontent or the github web interface - instead, clone the repos locally. Another useful source of comparison is ldomaradzki/xctree.

*CLI mode:* `ios_simulator_cli <tool> [--option value ...]` — runs tools directly as top-level subcommands. Stderr shows timing/diagnostic logs. Use `ios_simulator_cli mcp` to start the MCP server.

*Coordinate math:* agents can navigate the MCP in two ways: via the accessibility tree coordinates, and via their native graphical understanding. To that end, it's important that the pixels of any screenshot tools use the same coordinates and scale as the accessibility tree and the tap tools. Further complicating this is the fact that LLMs have limits on image size. All told, we end up wanting to shrink all of these by a constant, well-behaved scale. If you look through the commit history of joshuayoes/ios-simulator-mcp, you'll see a change that does this resizing; use that as inspiration.

*MCPTestApp Xcode project:* When adding new `.swift` files to MCPTestApp, you must add them to `MCPTestApp.xcodeproj/project.pbxproj` in 4 sections: PBXBuildFile, PBXFileReference, PBXGroup children, and PBXSourcesBuildPhase files. Follow the existing `AA`/`BB` ID convention with the next available number.

*Multiple simulators:* Multiple simulators are often booted. The test app targets a simulator named after the repo dir (`ios-simulator-mcp-swift`). When running smoke tests or CLI commands, pass `--device` explicitly — it accepts either a simulator name or UDID (auto-detected). `--udid` still works as an alias. Example: `--device "ios-simulator-mcp-swift"` or `--device 6C07B68F-...`.

*Selector commands:* `find`, `exists`, `count`, `text`, `tap_element`, `input`, `wait` — search/interact by `--role`, `--name`, `--identifier`. `describe_all --depth N` limits tree depth. These compose with AND logic.

*Demos:* Use `showboat` to create executable demo documents in `demos/`. Build incrementally with `showboat init`, `note`, `exec`, `image`. Verify with `showboat verify`. See existing demos for format. Always `showboat verify` before considering a demo complete.

*Validation:* Use the `mcp-playground-validate` skill to run smoke tests after code changes. Quick: `~/build/tools/skills/mcp-playground-validate/scripts/smoke_test.py --udid <UDID> -v`. Tests tap, swipe, screenshot, text input, AX tree, and coordinate alignment against MCPTestApp.
