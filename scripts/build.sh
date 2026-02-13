#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

mkdir -p ~/.local/bin
cp .build/release/ios_simulator_cli ~/.local/bin/

echo "Build succeeded and installed to ~/.local/bin/ios_simulator_cli"
