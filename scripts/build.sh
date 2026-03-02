#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

LOG_DIR="/tmp/iosef"
LOG="$LOG_DIR/build.log"
mkdir -p "$LOG_DIR"
echo "# build.sh — $(date -Iseconds)" > "$LOG"

swift build -c release 2>&1 | tee -a "$LOG"

mkdir -p ~/.local/bin
cp .build/release/iosef ~/.local/bin/
echo "Build succeeded and installed to ~/.local/bin/iosef" | tee -a "$LOG"
