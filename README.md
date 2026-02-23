# iosef

A fast, native Swift [MCP server](https://modelcontextprotocol.io/) and CLI for controlling the iOS Simulator. Supports tapping, swiping, typing, screenshots, and reading the accessibility tree — all without idb or any companion app.

### Why this exists

- **CLI-first**: Every tool is also a CLI subcommand, so agents can string calls together, pipe and filter outputs, and save context window space vs. multiple MCP round-trips.
- **Performance**: Stays in-process as much as possible rather than shelling out, for faster hot-loop operations like tapping and screenshotting.
- **Screenshots in iOS point space**: Screenshots are resized to match iOS point coordinates, so visual agents can tap where they see — no coordinate translation needed, even without an accessibility tree.
- **Semantic interface**: Accept simulator names instead of UDIDs. Tap by accessibility label instead of just coordinates. Query the AX tree with selectors (`--role`, `--name`, `--identifier`).
- **Scriptable verification**: [Rodney](https://github.com/simonw/rodney)-inspired tools like `wait` and `exists` make it easy to write verifiable interaction replays with [showboat](https://github.com/riwsky/showboat).
- **Simple install**: Single Swift package, no idb, no companion app.

## Acknowledgments

This project draws inspiration from:

- [joshuayoes/ios-simulator-mcp](https://github.com/joshuayoes/ios-simulator-mcp) — the original iOS Simulator MCP server that motivated this rewrite
- [facebook/idb](https://github.com/facebook/idb) — Meta's iOS development bridge, whose approach to simulator interaction informed the design
- [ldomaradzki/xctree](https://github.com/ldomaradzki/xctree) — a useful reference for working with the simulator's accessibility tree
- [simonw/rodney](https://github.com/simonw/rodney) — whose CLI design and goal of usage with showboat for executable demos inspired the scripting-oriented tools

## License

MIT — see [LICENSE](LICENSE) for details.
