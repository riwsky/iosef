---
name: release
description: Release a new version of iosef. Use when the user asks to release, publish, tag a version, or push to PyPI. Handles version bumping, building, tagging, and pushing. Do NOT use for regular development pushes to main (use jj-just-push-main for that).
---

# Release

## Checklist

1. **Bump `serverVersion`** in `Sources/iosef/SimulatorMCPCommand.swift` to the target semver.

2. **Build and verify:**
   ```bash
   swift build -c release
   .build/release/iosef --version   # should print new version
   ```

3. **Push to main** (if not already there). Use `/jj-just-push-main` or equivalent.

4. **Tag and push the tag:**
   ```bash
   # In a jj repo, use git directly for tagging:
   git --git-dir=$(jj git root) tag v{VERSION} {COMMIT_HASH}
   git --git-dir=$(jj git root) push origin v{VERSION}
   # Then fetch so jj sees the tag:
   jj git fetch
   ```

5. **Verify CI:** The `v*` tag triggers `.github/workflows/release.yaml`, which builds a universal2 binary (arm64 + x86_64 via lipo) and publishes to PyPI.

## Gotchas

- The `serverVersion` constant is used by both `iosef --version` and the MCP server's version field. Always bump it.
- In jj repos, `jj` doesn't manage git tags — use `git --git-dir=$(jj git root)` for tag operations.
- CI builds each arch separately via SwiftPM (`swift build -c release`), **not** `--arch` flags (which trigger Xcode's build system and break on CI).
