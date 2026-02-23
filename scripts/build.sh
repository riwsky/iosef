#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

mkdir -p ~/.local/bin
cp .build/release/iosef ~/.local/bin/

echo "Build succeeded and installed to ~/.local/bin/iosef"
