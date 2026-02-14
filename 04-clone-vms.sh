#!/bin/bash
# ============================================================
# Phase 2: Clone VMs at Scale
# ============================================================
# Creates CLONE_COUNT VMs from the golden image using
# CDI smart cloning (CSI -> RBD CoW clones).
# VMs are NOT booted - this measures pure clone overhead.
set -euo pipefail
source "$(dirname "$0")/00-config.sh"

CLONE_TOTAL="${1:-$CLONE_COUNT}"
BATCH="${2:-$CLONE_BATCH_SIZE}"

echo "============================================"
echo "  Phase 2: Cloning $CLONE_TOTAL VMs"
echo "  Batch size: $BATCH"
echo "============================================"

# Verify golden image PVC exists
if ! oc get pvc "$GOLDEN_DV_NAME" -n "$TEST_NS" &>/dev/null; then
    echo "ERROR: Golden image PVC '$GOLDEN_DV_NAME' not found in namespace '$TEST_NS'."
    echo "  Run 02-create-golden-image.sh first."
    exit 1
fi

# Track timing
START_TIME=$(date +%s)
CREATED=0
BATCH_NUM=0

while [[ $CREATED -lt $CLONE_TOTAL ]]; do
    BATCH_NUM=$((BATCH_NUM + 1))
    BATCH_END=$((CREATED + BATCH))
    if [[ $BATCH_END -gt $CLONE_TOTAL ]]; then
        BATCH_END=$CLONE_TOTAL
    fi

    echo ""
    echo "── Batch $BATCH_NUM: Creating clones $((CREATED + 1)) to $BATCH_END ──"

    for i in $(seq $((CREATED + 1)) "$BATCH_END"); do
        CLONE_NAME=$(printf "${CLONE_PREFIX}-%03d" "$i")
        DV_NAME="${CLONE_NAME}-disk"

        cat <<EOF | oc apply -f - &>/dev/null
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${CLONE_NAME}
  namespace: ${TEST_NS}
  labels:
    app: storage-test
    role: clone
    batch: "batch-${BATCH_NUM}"
spec:
  runStrategy: Halted
  dataVolumeTemplates:
    - metadata:
        name: ${DV_NAME}
      spec:
        source:
          pvc:
            namespace: ${TEST_NS}
            name: ${GOLDEN_DV_NAME}
        storage:
          storageClassName: ${STORAGE_CLASS}
          accessModes:
            - ReadWriteMany
          resources:
            requests:
              storage: ${GOLDEN_DISK_SIZE}
  template:
    metadata:
      labels:
        app: storage-test
        role: clone
    spec:
      domain:
        resources:
          requests:
            memory: 512Mi
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
        machine:
          type: q35
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          dataVolume:
            name: ${DV_NAME}
EOF
        echo -n "."
    done
    echo ""

    CREATED=$BATCH_END

    # Wait for this batch's DataVolumes to succeed
    echo "  Waiting for batch $BATCH_NUM DataVolumes to complete..."
    WAIT_START=$(date +%s)
    TIMEOUT=600  # 10 minutes per batch

    while true; do
        DV_PHASES=$(oc get dv -n "$TEST_NS" \
            -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null || true)
        SUCCEEDED=$(echo "$DV_PHASES" | grep -c "Succeeded" || true)
        PENDING=$(echo "$DV_PHASES" | grep -c -v "Succeeded" || true)
        PENDING=$((PENDING - 1))  # subtract golden image which is always Succeeded

        ELAPSED=$(( $(date +%s) - WAIT_START ))
        echo "    Succeeded: $SUCCEEDED / $CREATED | Pending: $PENDING | Elapsed: ${ELAPSED}s"

        if [[ $SUCCEEDED -ge $CREATED ]]; then
            break
        fi

        FAILED=$(echo "$DV_PHASES" | grep -c "Failed" || true)
        if [[ $FAILED -gt 0 ]]; then
            echo "  WARNING: $FAILED DataVolumes failed. Check:"
            oc get dv -n "$TEST_NS" | grep Failed | head -5
        fi

        if [[ $ELAPSED -gt $TIMEOUT ]]; then
            echo "  WARNING: Batch timeout ($TIMEOUT s). Proceeding to next batch."
            break
        fi

        sleep 15
    done
done

END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))

echo ""
echo "============================================"
echo "  Cloning Complete"
echo "============================================"
echo ""
echo "  Total VMs created: $CLONE_TOTAL"
echo "  Total time: ${TOTAL_TIME}s ($(echo "scale=1; $TOTAL_TIME / 60" | bc)m)"
echo "  Average per clone: $(echo "scale=1; $TOTAL_TIME / $CLONE_TOTAL" | bc)s"

# Verify CDI clone types
echo ""
echo "Checking clone types..."
CSI_COUNT=$(oc get dv -n "$TEST_NS" -o json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
count = 0
for item in data.get('items', []):
    ann = item.get('metadata', {}).get('annotations', {})
    if ann.get('cdi.kubevirt.io/cloneType') == 'csi-clone':
        count += 1
print(count)
" 2>/dev/null || echo "?")

COPY_COUNT=$(oc get dv -n "$TEST_NS" -o json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
count = 0
for item in data.get('items', []):
    ann = item.get('metadata', {}).get('annotations', {})
    if ann.get('cdi.kubevirt.io/cloneType') == 'copy':
        count += 1
print(count)
" 2>/dev/null || echo "?")

echo "  CSI clones (CoW): $CSI_COUNT"
echo "  Host-assisted copies: $COPY_COUNT"

if [[ "$COPY_COUNT" != "0" && "$COPY_COUNT" != "?" ]]; then
    echo ""
    echo "  *** WARNING ***"
    echo "  Some clones used host-assisted copying (full data copy)."
    echo "  This means CDI smart cloning is not working. Check:"
    echo "    - Source and target are in the same namespace"
    echo "    - Same StorageClass is used"
    echo "    - CSI driver supports cloning"
    echo "    - VolumeSnapshotClass exists for the CSI driver"
fi

echo ""
echo "Taking post-clone measurement..."
bash "$(dirname "$0")/03-measure-storage.sh" "after-${CLONE_TOTAL}-clones"

echo ""
echo "Next step: ./05-simulate-drift.sh"
