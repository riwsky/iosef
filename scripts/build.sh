#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

echo "Build succeeded: .build/release/ios-simulator-mcp"
