---
name: release
description: Release a new version of iosef to PyPI. Use when tagging a release, bumping the version, or publishing to PyPI.
---

# Release Workflow

## Versioning

We are **pre-1.0**. Always use `v0.x.y` versions. Do not tag `v1.*` until explicitly decided.

- **Patch** (`v0.x.Y`): bug fixes, minor tweaks
- **Minor** (`v0.X.0`): new features, new MCP tools, behavioral changes

## Steps

1. **Verify the build compiles**
   ```bash
   swift build -c release
   ```

2. **Choose the version bump** — check existing tags:
   ```bash
   git --git-dir=$(jj git root) tag -l 'v*'
   ```

3. **Tag the release** (jj worktree-aware):
   ```bash
   git --git-dir=$(jj git root) tag v0.x.y <commit>
   ```
   If tagging the current jj working copy, find its git commit with `jj log -r @ --no-graph -T commit_id`.

4. **Push the tag**:
   ```bash
   git --git-dir=$(jj git root) push origin v0.x.y
   ```

5. **Monitor the workflow**: pushing a `v*` tag triggers `.github/workflows/release.yaml`, which:
   - Builds arm64 and x86_64 binaries separately via SwiftPM
   - Combines them with `lipo` into a universal2 binary
   - Packages and publishes the wheel to PyPI

6. **Verify on PyPI** once the workflow completes:
   ```bash
   pip index versions iosef
   ```

## Checklist

- [ ] `swift build -c release` succeeds
- [ ] Version is `v0.x.y` (pre-1.0!)
- [ ] Tag points to the correct commit
- [ ] Tag pushed to origin
- [ ] GitHub Actions workflow running/passed
- [ ] PyPI shows the new version
