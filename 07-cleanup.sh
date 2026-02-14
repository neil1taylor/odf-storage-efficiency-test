#!/bin/bash
# ============================================================
# Cleanup: Remove All Test Resources
# ============================================================
# Deletes all VMs, DataVolumes, PVCs, and the test namespace.
# Run this after testing is complete.
set -euo pipefail
source "$(dirname "$0")/00-config.sh"

echo "============================================"
echo "  Cleanup: Removing Test Resources"
echo "============================================"
echo ""
echo "WARNING: This will delete ALL resources in namespace '$TEST_NS'."
echo "  - All VMs (golden + clones)"
echo "  - All DataVolumes and PVCs"
echo "  - The namespace itself"
echo ""
read -p "Type 'yes' to confirm: " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted."
    exit 0
fi

# ── 1. Stop all running VMs ──────────────────────────────
echo ""
echo "[1/5] Stopping running VMs..."
for VM in $(oc get vm -n "$TEST_NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    oc patch vm "$VM" -n "$TEST_NS" \
        --type merge --patch '{"spec":{"runStrategy": "Halted"}}' &>/dev/null || true
done

echo "  Waiting for VMIs to terminate..."
TIMEOUT=120
ELAPSED=0
while oc get vmi -n "$TEST_NS" --no-headers 2>/dev/null | grep -q .; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if [[ $ELAPSED -gt $TIMEOUT ]]; then
        echo "  Timeout waiting for VMIs. Force deleting..."
        oc delete vmi --all -n "$TEST_NS" --force --grace-period=0 2>/dev/null || true
        break
    fi
done
echo "  VMs stopped."

# ── 2. Delete VMs (triggers DV/PVC cleanup) ──────────────
echo ""
echo "[2/5] Deleting VMs..."
oc delete vm --all -n "$TEST_NS" --timeout=120s 2>/dev/null || true
echo "  VMs deleted."

# ── 3. Clean up any remaining DataVolumes ─────────────────
echo ""
echo "[3/5] Cleaning up DataVolumes..."
oc delete dv --all -n "$TEST_NS" --timeout=120s 2>/dev/null || true

# ── 4. Clean up any remaining PVCs ───────────────────────
echo ""
echo "[4/5] Cleaning up PVCs..."
REMAINING_PVCS=$(oc get pvc -n "$TEST_NS" --no-headers 2>/dev/null | wc -l || echo "0")
if [[ $REMAINING_PVCS -gt 0 ]]; then
    echo "  Found $REMAINING_PVCS remaining PVCs. Deleting..."
    oc delete pvc --all -n "$TEST_NS" --timeout=120s 2>/dev/null || true
fi
echo "  PVCs cleaned."

# ── 5. Delete namespace ──────────────────────────────────
echo ""
echo "[5/5] Deleting namespace..."
oc delete namespace "$TEST_NS" --timeout=300s 2>/dev/null || true
echo "  Namespace deleted."

# ── Verify Ceph cleanup ──────────────────────────────────
echo ""
echo "Verifying Ceph cleanup..."
TOOLBOX_POD=$(oc get pod -n "$TOOLBOX_NS" -l "$TOOLBOX_SELECTOR" -o name 2>/dev/null | head -1)
if [[ -n "$TOOLBOX_POD" ]]; then
    if [[ -n "$CEPH_POOL" ]]; then
        ORPHANS=$(oc exec -n "$TOOLBOX_NS" "$TOOLBOX_POD" -- \
            rbd ls "$CEPH_POOL" 2>/dev/null | wc -l || echo "?")
        TRASH=$(oc exec -n "$TOOLBOX_NS" "$TOOLBOX_POD" -- \
            rbd trash ls "$CEPH_POOL" 2>/dev/null | wc -l || echo "?")
        echo "  RBD images remaining in pool: $ORPHANS"
        echo "  RBD trash entries: $TRASH"
    fi
else
    echo "  Toolbox pod not available for verification."
fi

echo ""
echo "============================================"
echo "  Cleanup Complete"
echo "============================================"
echo ""
echo "  Results data preserved in: $RESULTS_DIR/"
echo "  To remove results too: rm -rf $RESULTS_DIR"
