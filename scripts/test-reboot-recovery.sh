#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

LOG_DIR="/tmp/iosef"
LOG="$LOG_DIR/test-reboot-recovery.log"
mkdir -p "$LOG_DIR"
echo "# test-reboot-recovery.sh — $(date -Iseconds)" > "$LOG"

# The RebootTests trait compiles in HIDSessionRecoveryTests (issue #8 regression
# coverage), which creates, reboots, and deletes a throwaway simulator (~2 min).
swift test --traits RebootTests --filter HIDSessionRecoveryTests 2>&1 | tee -a "$LOG"
