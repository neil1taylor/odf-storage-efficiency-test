#!/bin/bash
# ============================================================
# Phase 0: Setup - Prerequisites, Ceph Toolbox & Environment Summary
# ============================================================
set -euo pipefail
source "$(dirname "$0")/00-config.sh"

echo "============================================"
echo "  ODF Storage Test - Prerequisites Check"
echo "============================================"

# ── 1. Check oc is logged in ─────────────────────────────
echo ""
echo "[1/5] Verifying OpenShift login..."
if ! oc whoami &>/dev/null; then
    echo "ERROR: Not logged into OpenShift. Run 'oc login' first."
    exit 1
fi
echo "  Logged in as: $(oc whoami)"

# ── 2. Check ODF operator ────────────────────────────────
echo ""
echo "[2/5] Checking ODF operator..."
ODF_CSV=$(oc get csv -n openshift-storage 2>/dev/null || true)
if ! echo "$ODF_CSV" | grep -q "ocs-operator"; then
    echo "ERROR: ODF operator not found in openshift-storage namespace."
    echo "  Install the OpenShift Data Foundation operator first."
    exit 1
fi
echo "  ODF operator found."

# ── 3. Check StorageClass ────────────────────────────────
echo ""
echo "[3/5] Verifying StorageClass: $STORAGE_CLASS"
if ! oc get storageclass "$STORAGE_CLASS" &>/dev/null; then
    echo "ERROR: StorageClass '$STORAGE_CLASS' not found."
    echo "  Available StorageClasses:"
    oc get storageclass -o custom-columns=NAME:.metadata.name,PROVISIONER:.provisioner
    exit 1
fi
echo "  StorageClass exists."

# Verify it's Ceph RBD
PROVISIONER=$(oc get storageclass "$STORAGE_CLASS" -o jsonpath='{.provisioner}')
if [[ "$PROVISIONER" != *"rbd"* ]]; then
    echo "WARNING: StorageClass provisioner is '$PROVISIONER' - expected 'rbd'."
    echo "  Cloning behavior may differ."
fi

# ── 4. Check OpenShift Virtualization ─────────────────────
echo ""
echo "[4/5] Checking OpenShift Virtualization..."
CNV_CSV=$(oc get csv -n openshift-cnv 2>/dev/null || true)
if ! echo "$CNV_CSV" | grep -q "kubevirt-hyperconverged"; then
    echo "ERROR: OpenShift Virtualization operator not found."
    echo "  Install the OpenShift Virtualization operator first."
    exit 1
fi
echo "  OpenShift Virtualization found."

# ── 5. Enable & verify Ceph toolbox ──────────────────────
echo ""
echo "[5/5] Enabling Ceph toolbox pod..."

# Check if already running
TOOLBOX_POD=$(oc get pod -n "$TOOLBOX_NS" -l "$TOOLBOX_SELECTOR" -o name 2>/dev/null || true)
if [[ -n "$TOOLBOX_POD" ]]; then
    echo "  Toolbox pod already exists: $TOOLBOX_POD"
else
    echo "  Patching StorageCluster to enable Ceph tools..."
    oc patch storagecluster ocs-storagecluster -n "$TOOLBOX_NS" \
        --type merge --patch '{"spec":{"enableCephTools": true}}'

    echo "  Waiting for toolbox pod to appear (up to 120s)..."
    WAIT_ELAPSED=0
    while [[ -z "$(oc get pod -n "$TOOLBOX_NS" -l "$TOOLBOX_SELECTOR" -o name 2>/dev/null)" ]]; do
        sleep 5
        WAIT_ELAPSED=$((WAIT_ELAPSED + 5))
        if [[ $WAIT_ELAPSED -ge 120 ]]; then
            echo "ERROR: Toolbox pod never appeared."
            exit 1
        fi
        echo "    Waiting... (${WAIT_ELAPSED}s)"
    done
    echo "  Toolbox pod found. Waiting for Ready state..."
    if ! oc wait --for=condition=Ready pod -l "$TOOLBOX_SELECTOR" \
        -n "$TOOLBOX_NS" --timeout=120s; then
        echo "ERROR: Toolbox pod did not become ready."
        exit 1
    fi
fi

# Test Ceph access
echo "  Testing Ceph access..."
TOOLBOX_POD=$(oc get pod -n "$TOOLBOX_NS" -l "$TOOLBOX_SELECTOR" -o name | head -1)
oc exec -n "$TOOLBOX_NS" "$TOOLBOX_POD" -- ceph status 2>/dev/null | head -5
echo ""

# ── 6. Create test namespace ─────────────────────────────
echo "Creating test namespace: $TEST_NS"
oc create namespace "$TEST_NS" --dry-run=client -o yaml | oc apply -f -
echo ""

# ── 7. Verify Ceph pool ──────────────────────────────────
if [[ -z "$CEPH_POOL" ]]; then
    echo "ERROR: CEPH_POOL is not set. Configure it in 00-config.sh."
    echo "  List pools with: oc get storagepool -n openshift-storage"
    exit 1
fi
echo "Using Ceph pool: $CEPH_POOL"

# ── 8. Reset results directory ────────────────────────────
echo "[8] Clearing previous results..."
rm -rf "$RESULTS_DIR"
mkdir -p "$RESULTS_DIR"

# ── 9. Capture storage environment summary ───────────────
echo "[9] Capturing storage environment summary..."

# Gather data from cluster and Ceph
ODF_VER=$(oc get csv -n openshift-storage 2>/dev/null \
    | grep -E "ocs-operator|odf-operator" \
    | awk '{print $1}' | head -1 \
    | sed 's/.*\.v//')
CEPH_VER_RAW=$(oc exec -n "$TOOLBOX_NS" "$TOOLBOX_POD" -- ceph version 2>/dev/null)
CEPH_VER_NUM=$(echo "$CEPH_VER_RAW" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
# ceph version output: "ceph version 19.2.1 (ba02d589...) squid (stable)"
# The codename (e.g. "squid") is the word between ") " and " (stable)"
CEPH_VER_NAME=$(echo "$CEPH_VER_RAW" | sed -n 's/.*) \([a-z]*\) .*/\1/p')
CEPH_HEALTH=$(oc exec -n "$TOOLBOX_NS" "$TOOLBOX_POD" -- ceph health 2>/dev/null | awk '{print $1}')
OSD_COUNT=$(oc exec -n "$TOOLBOX_NS" "$TOOLBOX_POD" -- ceph osd stat 2>/dev/null \
    | grep -oE '^[0-9]+')
CEPH_DF_OUT=$(oc exec -n "$TOOLBOX_NS" "$TOOLBOX_POD" -- ceph df 2>/dev/null)
RAW_CAPACITY=$(echo "$CEPH_DF_OUT" | awk '/CLASS/{found=1; next} found{print $2, $3; exit}')
REPLICA_SIZE=$(oc exec -n "$TOOLBOX_NS" "$TOOLBOX_POD" -- \
    ceph osd pool get "$CEPH_POOL" size 2>/dev/null | awk '{print $2}')
COMPRESSION_MODE=$(oc exec -n "$TOOLBOX_NS" "$TOOLBOX_POD" -- \
    ceph osd pool get "$CEPH_POOL" compression_mode 2>/dev/null | awk '{print $2}')
SC_PARAMS=$(oc get storageclass "$STORAGE_CLASS" -o jsonpath='{.parameters}' 2>/dev/null)

# Failure domain and OSD topology
CRUSH_RULE_NAME=$(oc exec -n "$TOOLBOX_NS" "$TOOLBOX_POD" -- \
    ceph osd pool get "$CEPH_POOL" crush_rule 2>/dev/null | awk '{print $2}')
# The chooseleaf step's "type" field holds the failure domain (e.g. "rack", "host")
# JSON looks like: {"op": "chooseleaf_firstn", "num": 0, "type": "rack"}
FAILURE_DOMAIN=$(oc exec -n "$TOOLBOX_NS" "$TOOLBOX_POD" -- \
    ceph osd crush rule dump "$CRUSH_RULE_NAME" 2>/dev/null \
    | awk -F'"' '/chooseleaf/,/\}/' | awk -F'"' '/"type"/{print $4}')
OSD_TREE=$(oc exec -n "$TOOLBOX_NS" "$TOOLBOX_POD" -- ceph osd tree 2>/dev/null)

# Count racks and hosts from OSD tree (non-OSD lines have TYPE in column 3)
RACK_COUNT=$(echo "$OSD_TREE" | awk '$3 == "rack"' | wc -l | tr -d ' ')
HOST_COUNT=$(echo "$OSD_TREE" | awk '$3 == "host"' | wc -l | tr -d ' ')

# Derive usable capacity estimate
RAW_NUM=$(echo "$RAW_CAPACITY" | awk '{print $1}')
RAW_UNIT=$(echo "$RAW_CAPACITY" | awk '{print $2}')
if [[ -n "$RAW_NUM" && -n "$REPLICA_SIZE" && "$REPLICA_SIZE" -gt 0 ]]; then
    USABLE_CAPACITY=$(echo "scale=0; $RAW_NUM / $REPLICA_SIZE" | bc 2>/dev/null || echo "?")
else
    USABLE_CAPACITY="?"
fi

# Format health for display
case "$CEPH_HEALTH" in
    HEALTH_OK)   HEALTH_DISPLAY="HEALTHY" ;;
    HEALTH_WARN) HEALTH_DISPLAY="WARNING" ;;
    HEALTH_ERR)  HEALTH_DISPLAY="ERROR" ;;
    *)           HEALTH_DISPLAY="$CEPH_HEALTH" ;;
esac

# Format compression
if [[ "$COMPRESSION_MODE" == "aggressive" || "$COMPRESSION_MODE" == "force" ]]; then
    COMPRESSION_DISPLAY="Enabled ($COMPRESSION_MODE mode)"
elif [[ "$COMPRESSION_MODE" == "passive" ]]; then
    COMPRESSION_DISPLAY="Enabled (passive - only hinted writes)"
else
    COMPRESSION_DISPLAY="Disabled"
fi

# Write the summary file
ENV_SUMMARY="$RESULTS_DIR/environment-summary.txt"
cat > "$ENV_SUMMARY" << ENVEOF
STORAGE ENVIRONMENT SUMMARY
======================================================================
Captured: $(date '+%Y-%m-%d %H:%M:%S %Z')

OpenShift Data Foundation (ODF)
  ODF Version:    $ODF_VER
  Ceph Version:   $CEPH_VER_NUM ($CEPH_VER_NAME)
  Cluster Health: $HEALTH_DISPLAY

  ODF is the storage platform running on this OpenShift cluster.
  It uses Ceph, an open-source distributed storage system, to
  manage data across multiple disks.

Cluster Capacity
  Physical Disks (OSDs):  $OSD_COUNT
  Total Raw Capacity:     $RAW_CAPACITY
  Usable Capacity:        ~${USABLE_CAPACITY} ${RAW_UNIT}  (raw / $REPLICA_SIZE replicas)

  The cluster has $OSD_COUNT storage devices (called OSDs). The raw capacity
  is divided by the replication factor to give usable space.

Failure Domain & Topology
  Failure Domain:  $FAILURE_DOMAIN
  CRUSH Rule:      $CRUSH_RULE_NAME

  The failure domain determines how Ceph spreads replicas. With
  "$FAILURE_DOMAIN" as the failure domain, each copy of data is
  placed in a different $FAILURE_DOMAIN. This means losing an entire
  $FAILURE_DOMAIN will not cause data loss.

  OSD Tree (which disks are in which ${FAILURE_DOMAIN}s):
$(echo "$OSD_TREE" | sed 's/^/    /')

Storage Pool: $CEPH_POOL
  Replication:  $REPLICA_SIZE copies of every data block
  Compression:  $COMPRESSION_DISPLAY

  "$REPLICA_SIZE replicas" means every piece of data is stored on $REPLICA_SIZE different
  disks for redundancy. If one disk fails, no data is lost.
  Compression squeezes data before writing to save physical space.

VM Disk Storage (StorageClass: $STORAGE_CLASS)
  Type:          Ceph RBD (block storage)
  Clone Method:  Copy-on-write via CSI

  Ceph RBD provides virtual block devices - each VM gets a disk
  backed by the Ceph pool above. Cloning uses copy-on-write,
  meaning new VMs share the original data and only store their
  differences (similar to VMware linked clones).

StorageClass Parameters
  $SC_PARAMS
======================================================================
ENVEOF

echo "  Saved to: $ENV_SUMMARY"
echo ""

# ── 9. Download Chart.js for HTML reports ────────────────
echo "[9] Downloading Chart.js for report charts..."
CHARTJS_URL="https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js"
CHARTJS_FILE="$RESULTS_DIR/chart.min.js"
if curl -sSL --connect-timeout 10 --max-time 30 "$CHARTJS_URL" -o "$CHARTJS_FILE" 2>/dev/null; then
    echo "  Saved to: $CHARTJS_FILE ($(wc -c < "$CHARTJS_FILE" | tr -d ' ') bytes)"
else
    echo "  WARNING: Could not download Chart.js (no internet access?)."
    echo "  Reports will still generate with data tables, but without interactive charts."
    rm -f "$CHARTJS_FILE"
fi
echo ""

# Print condensed summary to console
echo "  Storage Environment"
echo "  -------------------"
echo "  ODF:              $ODF_VER"
echo "  Ceph:             $CEPH_VER_NUM ($CEPH_VER_NAME)"
echo "  Health:           $HEALTH_DISPLAY"
echo "  Raw Capacity:     $RAW_CAPACITY"
echo "  Topology:         ${RACK_COUNT} racks, ${HOST_COUNT} nodes, ${OSD_COUNT} OSDs"
echo "  Failure Domain:   $FAILURE_DOMAIN"
echo "  Pool:             $CEPH_POOL (${REPLICA_SIZE}x replication)"
echo "  Compression:      $COMPRESSION_MODE"

echo ""
echo "============================================"
echo "  Prerequisites OK. Ready to proceed."
echo "============================================"
echo ""
echo "Next steps:"
echo "  1. Run: ./02-create-golden-image.sh  (captures baseline + golden image measurements automatically)"
