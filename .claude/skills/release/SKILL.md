---
name: release
description: Release a new version of iosef. Use when the user asks to release, publish, tag a version, or push to PyPI. Handles version bumping, building, tagging, and pushing. Do NOT use for regular development pushes to main (use jj-just-push-main for that).
---

# Release Workflow

## Versioning

We are **pre-1.0**. Always use `v0.x.y` versions. Do not tag `v1.*` until explicitly decided.

- **Patch** (`v0.x.Y`): bug fixes, minor tweaks
- **Minor** (`v0.X.0`): new features, new MCP tools, behavioral changes

## Steps

1. **Bump `serverVersion`** in `Sources/iosef/Utilities.swift` to the target semver.

2. **Build and verify:**
   ```bash
   swift build -c release
   .build/release/iosef --version   # should print new version
   ```

3. **Push to main** (if not already there). Use `/jj-just-push-main` or equivalent.

4. **Choose the version** — check existing tags:
   ```bash
   git --git-dir=$(jj git root) tag -l 'v*'
   ```

5. **Tag and push the tag:**
   ```bash
   # In a jj repo, use git directly for tagging:
   git --git-dir=$(jj git root) tag v{VERSION} {COMMIT_HASH}
   git --git-dir=$(jj git root) push origin v{VERSION}
   # Then fetch so jj sees the tag:
   jj git fetch
   ```
   If tagging the current jj working copy, find its git commit with `jj log -r @ --no-graph -T commit_id`.

6. **Monitor CI:** The `v*` tag triggers `.github/workflows/release.yaml`, which builds arm64 and x86_64 binaries separately via SwiftPM, combines them with `lipo` into a universal2 binary, and publishes the wheel to PyPI.

7. **Verify on PyPI** once the workflow completes:
   ```bash
   pip index versions iosef
   ```

## Checklist

- [ ] `serverVersion` bumped in `Sources/iosef/Utilities.swift`
- [ ] `swift build -c release` succeeds
- [ ] `iosef --version` prints new version
- [ ] Changes pushed to main
- [ ] Version is `v0.x.y` (pre-1.0!)
- [ ] Tag points to the correct commit
- [ ] Tag pushed to origin
- [ ] `jj git fetch` run after tag push
- [ ] GitHub Actions workflow running/passed
- [ ] PyPI shows the new version

## Gotchas

- The `serverVersion` constant is used by both `iosef --version` and the MCP server's version field. Always bump it.
- In jj repos, `jj` doesn't manage git tags — use `git --git-dir=$(jj git root)` for tag operations.
- CI builds each arch separately via SwiftPM (`swift build -c release`), **not** `--arch` flags (which trigger Xcode's build system and break on CI).
