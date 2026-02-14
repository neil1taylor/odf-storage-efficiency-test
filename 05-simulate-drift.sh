#!/bin/bash
# ============================================================
# Phase 3: Simulate Workload Drift
# ============================================================
# Boots cloned VMs and writes unique data to each to simulate
# how VMs diverge from the golden image over time.
# Takes storage measurements at each drift level.
set -euo pipefail
source "$(dirname "$0")/00-config.sh"

DRIFT_MB="${1:-}"  # Optionally specify a single drift level in MB

if [[ -n "$DRIFT_MB" ]]; then
    LEVELS="$DRIFT_MB"
else
    LEVELS="$DRIFT_LEVELS_MB"
fi

echo "============================================"
echo "  Phase 3: Simulating Workload Drift"
echo "  Drift levels (MB): $LEVELS"
echo "============================================"

# ── 1. Boot all cloned VMs ───────────────────────────────
echo ""
echo "[1/3] Booting cloned VMs..."

# Start VMs in batches
VM_LIST=$(oc get vm -n "$TEST_NS" -l role=clone -o jsonpath='{.items[*].metadata.name}')
VM_COUNT=$(echo "$VM_LIST" | wc -w | tr -d ' ')

echo "  Starting $VM_COUNT VMs..."
BATCH=0
for VM in $VM_LIST; do
    oc patch vm "$VM" -n "$TEST_NS" \
        --type merge --patch '{"spec":{"runStrategy": "Always"}}' &>/dev/null &
    BATCH=$((BATCH + 1))
    if [[ $((BATCH % CLONE_BATCH_SIZE)) -eq 0 ]]; then
        echo "    Started $BATCH / $VM_COUNT"
        wait  # wait for patch commands to complete
        sleep 5  # brief pause between batches
    fi
done
wait
if [[ $((BATCH % CLONE_BATCH_SIZE)) -ne 0 ]]; then
    echo "    Started $BATCH / $VM_COUNT"
fi

# Wait for VMs to be running
echo "  Waiting for VMs to reach Running state..."
TIMEOUT=600
WAIT_START=$(date +%s)

while true; do
    RUNNING=$(oc get vmi -n "$TEST_NS" -l role=clone \
        --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    ELAPSED=$(( $(date +%s) - WAIT_START ))
    echo "    Running: $RUNNING / $VM_COUNT | Elapsed: ${ELAPSED}s"

    if [[ $RUNNING -ge $VM_COUNT ]]; then
        break
    fi
    if [[ $ELAPSED -gt $TIMEOUT ]]; then
        echo "  WARNING: Timeout waiting for all VMs. Proceeding with $RUNNING running VMs."
        break
    fi
    sleep 15
done

# Give VMs a moment to fully initialize
echo "  Waiting 30s for VMs to fully initialize..."
sleep 30

# ── 2. Run drift simulation at each level ────────────────
echo ""
echo "[2/3] Running drift simulation..."

CUMULATIVE_MB=0
for DRIFT in $LEVELS; do
    INCREMENTAL_MB=$((DRIFT - CUMULATIVE_MB))
    if [[ $INCREMENTAL_MB -le 0 ]]; then
        echo "  Skipping $DRIFT MB (already at $CUMULATIVE_MB MB cumulative)"
        continue
    fi

    DISK_PCT=$(echo "scale=1; $DRIFT * 100 / 20480" | bc 2>/dev/null || echo "?")
    echo ""
    echo "  ── Drift level: ${DRIFT} MB (${DISK_PCT}% of 20GB) ──"
    echo "  Writing ${INCREMENTAL_MB} MB of unique data to each VM..."

    DRIFT_START=$(date +%s)
    COMPLETED=0

    for VM in $VM_LIST; do
        # Write unique random data inside the VM
        # Using a unique filename per drift level to avoid overwriting
        virtctl ssh --command "dd if=/dev/urandom of=/var/tmp/drift-${DRIFT}mb bs=1M count=${INCREMENTAL_MB} status=none 2>/dev/null && sync" \
            -i "$SSH_KEY_PATH" --username "$VM_SSH_USER" \
            -t "-oStrictHostKeyChecking=no" \
            -n "$TEST_NS" "vmi/$VM" &>/dev/null &

        COMPLETED=$((COMPLETED + 1))
        if [[ $((COMPLETED % CLONE_BATCH_SIZE)) -eq 0 ]]; then
            echo "    Submitted $COMPLETED / $VM_COUNT"
            wait
        fi
    done
    wait

    DRIFT_TIME=$(( $(date +%s) - DRIFT_START ))
    echo "    All VMs written. Time: ${DRIFT_TIME}s"

    # Wait for Ceph to settle (allow writes to propagate and stats to update)
    echo "    Waiting 30s for Ceph stats to stabilize..."
    sleep 30

    # Take measurement
    LABEL="drift-${DRIFT}mb-${DISK_PCT}pct"
    echo "    Taking measurement: $LABEL"
    bash "$(dirname "$0")/03-measure-storage.sh" "$LABEL"

    CUMULATIVE_MB=$DRIFT
done

# ── 3. Stop all VMs ──────────────────────────────────────
echo ""
echo "[3/3] Stopping all cloned VMs..."

for VM in $VM_LIST; do
    oc patch vm "$VM" -n "$TEST_NS" \
        --type merge --patch '{"spec":{"runStrategy": "Halted"}}' &>/dev/null &
done
wait

echo "  VMs stopped."

echo ""
echo "============================================"
echo "  Drift Simulation Complete"
echo "============================================"
echo ""
echo "  Review results in: $RESULTS_DIR/summary.csv"
echo ""
echo "  To visualize, run: ./06-generate-report.sh"
