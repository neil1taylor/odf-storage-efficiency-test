#!/bin/bash
# ============================================================
# Phase 1: Create the Golden VM Image (Template)
# ============================================================
# Creates a VM with a known amount of test data on disk.
# This is the equivalent of a VMware VM template.
set -euo pipefail
source "$(dirname "$0")/00-config.sh"

echo "============================================"
echo "  Phase 1: Creating Golden VM Image"
echo "============================================"

# ── 0. Record baseline (empty pool) ──────────────────────
echo ""
echo "[0/4] Recording baseline storage measurements (before golden image)..."
bash "$(dirname "$0")/03-measure-storage.sh" baseline

# ── 1. Create the golden image DataVolume ─────────────────
echo ""
echo "[1/4] Creating golden image DataVolume from source image..."

cat <<EOF | oc apply -f -
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ${GOLDEN_DV_NAME}
  namespace: ${TEST_NS}
  annotations:
    cdi.kubevirt.io/storage.usePopulator: "true"
spec:
  source:
    http:
      url: "${SOURCE_IMAGE_URL}"
  storage:
    storageClassName: ${STORAGE_CLASS}
    accessModes:
      - ReadWriteMany
    resources:
      requests:
        storage: ${GOLDEN_DISK_SIZE}
EOF

echo "  Waiting for DataVolume import to complete..."
echo "  (This may take several minutes depending on network speed)"

# Wait for DV to succeed
while true; do
    PHASE=$(oc get dv "$GOLDEN_DV_NAME" -n "$TEST_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    PROGRESS=$(oc get dv "$GOLDEN_DV_NAME" -n "$TEST_NS" -o jsonpath='{.status.progress}' 2>/dev/null || echo "N/A")
    echo "    Phase: $PHASE | Progress: $PROGRESS"
    if [[ "$PHASE" == "Succeeded" ]]; then
        break
    elif [[ "$PHASE" == "Failed" ]]; then
        echo "ERROR: DataVolume import failed."
        oc describe dv "$GOLDEN_DV_NAME" -n "$TEST_NS" | tail -20
        exit 1
    fi
    sleep 10
done
echo "  Golden image DataVolume ready."

# ── 2. Create the golden VM ──────────────────────────────
echo ""
echo "[2/4] Creating golden template VM..."

cat <<EOF | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${GOLDEN_VM_NAME}
  namespace: ${TEST_NS}
  labels:
    app: storage-test
    role: golden-template
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        app: storage-test
        role: golden-template
    spec:
      domain:
        resources:
          requests:
            memory: 1Gi
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: cloudinitdisk
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
            name: ${GOLDEN_DV_NAME}
        - name: cloudinitdisk
          cloudInitNoCloud:
            userData: |
              #cloud-config
              user: ${VM_SSH_USER}
              password: testpass123
              chpasswd:
                expire: false
              ssh_authorized_keys:
                - ${SSH_PUB_KEY}
              runcmd:
                # Write ~5GB of known test data to simulate a used VM disk
                - dd if=/dev/urandom of=/var/tmp/testdata-1 bs=1M count=2048 status=progress
                - dd if=/dev/urandom of=/var/tmp/testdata-2 bs=1M count=2048 status=progress
                - dd if=/dev/urandom of=/var/tmp/testdata-3 bs=1M count=1024 status=progress
                - sync
                - echo "GOLDEN_IMAGE_DATA_WRITTEN" > /var/tmp/golden-ready
EOF

echo "  Waiting for VM to boot and write test data..."
echo "  (This writes ~5GB of test data via cloud-init)"

# Wait for VM to be running
oc wait --for=jsonpath='{.status.ready}'=true vm/"$GOLDEN_VM_NAME" \
    -n "$TEST_NS" --timeout=300s 2>/dev/null || true

echo "  VM is running. Waiting for cloud-init data write to complete..."
echo "  Checking for completion marker (may take 5-10 minutes)..."

# Poll for the completion marker
for i in $(seq 1 60); do
    RESULT=$(virtctl ssh --command "cat /var/tmp/golden-ready" \
        -i "$SSH_KEY_PATH" --username "$VM_SSH_USER" \
        -t "-oStrictHostKeyChecking=no" \
        -n "$TEST_NS" "vmi/$GOLDEN_VM_NAME" 2>/dev/null || echo "")
    if [[ "$RESULT" == *"GOLDEN_IMAGE_DATA_WRITTEN"* ]]; then
        echo "  Test data write complete."
        break
    fi
    if [[ $i -eq 60 ]]; then
        echo "  WARNING: Timed out waiting for data write. Proceeding anyway."
        echo "  You can check manually: virtctl ssh $GOLDEN_VM_NAME -n $TEST_NS"
    fi
    sleep 10
done

# ── 3. Stop the VM ───────────────────────────────────────
echo ""
echo "[3/4] Stopping the golden VM (preserving disk)..."
oc patch vm "$GOLDEN_VM_NAME" -n "$TEST_NS" \
    --type merge --patch '{"spec":{"runStrategy": "Halted"}}'

# Wait for VMI to disappear
echo "  Waiting for VM to fully stop..."
while oc get vmi "$GOLDEN_VM_NAME" -n "$TEST_NS" &>/dev/null; do
    sleep 5
done
echo "  VM stopped."

# ── 4. Record golden image measurements ──────────────────
echo ""
echo "[4/4] Recording storage measurements after golden image..."
bash "$(dirname "$0")/03-measure-storage.sh" after-golden-image

echo ""
echo "============================================"
echo "  Golden Image Ready"
echo "============================================"
echo ""
echo "Golden image PVC: $GOLDEN_DV_NAME"
echo "Disk size: $GOLDEN_DISK_SIZE (with ~5GB test data)"
echo ""
echo "Next step: ./04-clone-vms.sh"
