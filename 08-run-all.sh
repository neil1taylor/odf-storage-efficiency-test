#!/bin/bash
# ============================================================
# Run All: Execute the full test pipeline end-to-end
# ============================================================
# Runs scripts 01-06 in order. Skips 07 (cleanup) since you
# likely want to review results before tearing down.
set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"
START_TIME=$(date +%s)

echo "============================================"
echo "  ODF Storage Efficiency Test - Full Run"
echo "  Started: $(date)"
echo "============================================"
echo ""

run_phase() {
    local script="$1"
    shift
    echo "────────────────────────────────────────────"
    echo "  Running: $script $*"
    echo "────────────────────────────────────────────"
    bash "$SCRIPT_DIR/$script" "$@"
    echo ""
}

run_phase 01-setup.sh
run_phase 02-create-golden-image.sh
run_phase 04-clone-vms.sh
run_phase 05-simulate-drift.sh
run_phase 06-generate-report.sh

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
MINS=$(( ELAPSED / 60 ))
SECS=$(( ELAPSED % 60 ))

echo "============================================"
echo "  Full Run Complete"
echo "  Total time: ${MINS}m ${SECS}s"
echo "============================================"
echo ""
echo "To clean up test resources: ./07-cleanup.sh"
