#!/bin/bash
# ============================================================
# Measurement Script - Captures Ceph & Kubernetes Storage Data
# ============================================================
# Usage: ./03-measure-storage.sh <label>
#   label: descriptive label for this measurement point
#          e.g. "baseline", "after-100-clones", "drift-1pct"
#
# Outputs:
#   results/summary.csv          - One row per measurement (main output)
#   results/<label>_detail.json  - Combined detail for this measurement
set -euo pipefail
source "$(dirname "$0")/00-config.sh"

LABEL="${1:?Usage: $0 <measurement-label>}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SAFE_LABEL=$(echo "$LABEL" | tr ' /' '-_')

echo "============================================"
echo "  Storage Measurement: $LABEL"
echo "  Timestamp: $TIMESTAMP"
echo "============================================"

# Get toolbox pod
TOOLBOX_POD=$(oc get pod -n "$TOOLBOX_NS" -l "$TOOLBOX_SELECTOR" -o name 2>/dev/null | head -1)
if [[ -z "$TOOLBOX_POD" ]]; then
    echo "ERROR: Ceph toolbox pod not found. Run 01-setup.sh first."
    exit 1
fi

# Verify pool is configured
if [[ -z "$CEPH_POOL" ]]; then
    echo "ERROR: CEPH_POOL is not set. Configure it in 00-config.sh."
    echo "  List pools with: oc get storagepool -n openshift-storage"
    exit 1
fi

echo ""
echo "Using Ceph pool: $CEPH_POOL"

# ── 1. Pool-level measurements (ceph df) ─────────────────
echo ""
echo "[1/3] Capturing pool-level storage..."

CEPH_DF_JSON=$(oc exec -n "$TOOLBOX_NS" "$TOOLBOX_POD" -- \
    ceph df detail --format json 2>/dev/null)

# Extract key metrics for the target pool
POOL_STORED=$(echo "$CEPH_DF_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for pool in data.get('pools', []):
    if pool['name'] == '$CEPH_POOL':
        stats = pool.get('stats', {})
        print(stats.get('stored', 0))
        break
" 2>/dev/null || echo "0")

POOL_OBJECTS=$(echo "$CEPH_DF_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for pool in data.get('pools', []):
    if pool['name'] == '$CEPH_POOL':
        stats = pool.get('stats', {})
        print(stats.get('objects', 0))
        break
" 2>/dev/null || echo "0")

POOL_USED=$(echo "$CEPH_DF_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for pool in data.get('pools', []):
    if pool['name'] == '$CEPH_POOL':
        stats = pool.get('stats', {})
        print(stats.get('bytes_used', 0))
        break
" 2>/dev/null || echo "0")

COMPRESS_USED=$(echo "$CEPH_DF_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for pool in data.get('pools', []):
    if pool['name'] == '$CEPH_POOL':
        stats = pool.get('stats', {})
        print(stats.get('compress_bytes_used', 0))
        break
" 2>/dev/null || echo "0")

COMPRESS_UNDER=$(echo "$CEPH_DF_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for pool in data.get('pools', []):
    if pool['name'] == '$CEPH_POOL':
        stats = pool.get('stats', {})
        print(stats.get('compress_under_bytes', 0))
        break
" 2>/dev/null || echo "0")

STORED_GB=$(echo "scale=3; $POOL_STORED / 1073741824" | bc 2>/dev/null || echo "N/A")
USED_GB=$(echo "scale=3; $POOL_USED / 1073741824" | bc 2>/dev/null || echo "N/A")
COMPRESS_USED_GB=$(echo "scale=3; $COMPRESS_USED / 1073741824" | bc 2>/dev/null || echo "0")
COMPRESS_UNDER_GB=$(echo "scale=3; $COMPRESS_UNDER / 1073741824" | bc 2>/dev/null || echo "0")
if [[ "$COMPRESS_UNDER" -gt 0 ]]; then
    COMPRESS_SAVED_GB=$(echo "scale=3; ($COMPRESS_UNDER - $COMPRESS_USED) / 1073741824" | bc 2>/dev/null || echo "0")
    COMPRESS_RATIO=$(echo "scale=2; $COMPRESS_USED * 100 / $COMPRESS_UNDER" | bc 2>/dev/null || echo "N/A")
else
    COMPRESS_SAVED_GB="0"
    COMPRESS_RATIO="N/A"
fi

echo "  Data stored (before replication): ${STORED_GB} GB"
echo "  Disk used   (after replication):  ${USED_GB} GB"
echo "  Storage objects: $POOL_OBJECTS"
if [[ "$COMPRESS_UNDER" -gt 0 ]]; then
    echo "  Compression: ${COMPRESS_UNDER_GB} GB → ${COMPRESS_USED_GB} GB (saved ${COMPRESS_SAVED_GB} GB, ${COMPRESS_RATIO}% of original)"
else
    echo "  Compression: no compressed data yet"
fi

# ── 2. Per-image measurements (rbd du) ───────────────────
echo ""
echo "[2/3] Capturing per-disk storage..."

RBD_DU_JSON=$(oc exec -n "$TOOLBOX_NS" "$TOOLBOX_POD" -- \
    rbd du "$CEPH_POOL" --format json 2>/dev/null || echo '{"images":[]}')

IMAGE_COUNT=$(echo "$RBD_DU_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(len(data.get('images', [])))
" 2>/dev/null || echo "0")

echo "  Virtual disks in pool: $IMAGE_COUNT"

# ── 3. PVC count and clone type checks ───────────────────
echo ""
echo "[3/3] Checking VM disks and clone types..."

PVC_COUNT=0
for PVC in $(oc get pvc -n "$TEST_NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    PVC_COUNT=$((PVC_COUNT + 1))
done
echo "  VM disks (PVCs): $PVC_COUNT"

# Only check clone types if there are DataVolumes beyond the golden image
CSI_CLONE_COUNT=0
COPY_CLONE_COUNT=0
DV_LIST=$(oc get dv -n "$TEST_NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
DV_COUNT=$(echo "$DV_LIST" | wc -w)

if [[ $DV_COUNT -gt 1 ]]; then
    for DV in $DV_LIST; do
        CLONE_TYPE=$(oc get dv "$DV" -n "$TEST_NS" \
            -o jsonpath='{.metadata.annotations.cdi\.kubevirt\.io/cloneType}' 2>/dev/null || echo "N/A")
        case "$CLONE_TYPE" in
            "csi-clone") CSI_CLONE_COUNT=$((CSI_CLONE_COUNT + 1)) ;;
            "copy") COPY_CLONE_COUNT=$((COPY_CLONE_COUNT + 1)) ;;
        esac
    done

    echo "  Efficient clones (copy-on-write): $CSI_CLONE_COUNT"
    echo "  Full-copy clones (slow):          $COPY_CLONE_COUNT"
    if [[ $COPY_CLONE_COUNT -gt 0 ]]; then
        echo "  WARNING: Some clones used full copy instead of copy-on-write!"
    fi
fi

# ── Write summary CSV ────────────────────────────────────
SUMMARY_CSV="$RESULTS_DIR/summary.csv"
if [[ ! -f "$SUMMARY_CSV" ]]; then
    echo "timestamp,label,pool_stored_bytes,pool_stored_gb,pool_used_bytes,pool_used_gb,pool_objects,compress_under_bytes,compress_under_gb,compress_used_bytes,compress_used_gb,compress_saved_gb,compress_ratio_pct,pvc_count,image_count,csi_clones,copy_clones" > "$SUMMARY_CSV"
fi
echo "$TIMESTAMP,$LABEL,$POOL_STORED,$STORED_GB,$POOL_USED,$USED_GB,$POOL_OBJECTS,$COMPRESS_UNDER,$COMPRESS_UNDER_GB,$COMPRESS_USED,$COMPRESS_USED_GB,$COMPRESS_SAVED_GB,$COMPRESS_RATIO,$PVC_COUNT,$IMAGE_COUNT,$CSI_CLONE_COUNT,$COPY_CLONE_COUNT" >> "$SUMMARY_CSV"

# ── Write combined detail JSON ───────────────────────────
DETAIL_FILE="$RESULTS_DIR/${SAFE_LABEL}_detail.json"
python3 -c "
import json, sys

# Build a single detail file with explanations
detail = {
    'measurement_label': '$LABEL',
    'timestamp': '$TIMESTAMP',
    'ceph_pool': '$CEPH_POOL',
    'explanation': {
        'pool_stored_gb': 'Actual unique data in the pool before Ceph replicates it. This is the real data footprint.',
        'pool_used_gb': 'Total disk space consumed after Ceph replication (stored x replica count). This is what your physical disks use.',
        'pool_objects': 'Number of small storage chunks (typically 4MB each) that Ceph uses internally to manage the data.',
        'pvc_count': 'Number of virtual machine disks (Persistent Volume Claims) in the test namespace.',
        'image_count': 'Number of block device images in the Ceph pool. Each VM disk becomes one image.',
        'csi_clones': 'Clones created using copy-on-write (efficient). Only the differences from the original are stored.',
        'copy_clones': 'Clones created by full data copy (inefficient). Each clone uses as much space as the original.',
        'compress_under_gb': 'Original (uncompressed) size of data that Ceph compressed. Only data eligible for compression is counted here.',
        'compress_used_gb': 'Size of that data after compression. The difference is disk space saved by compression.',
        'compress_saved_gb': 'Disk space saved by compression (compress_under - compress_used).',
        'compress_ratio_pct': 'Compressed size as a percentage of original. Lower means better compression.',
    },
    'summary': {
        'pool_stored_gb': $STORED_GB,
        'pool_used_gb': $USED_GB,
        'pool_objects': $POOL_OBJECTS,
        'compress_under_gb': $COMPRESS_UNDER_GB,
        'compress_used_gb': $COMPRESS_USED_GB,
        'compress_saved_gb': $COMPRESS_SAVED_GB,
        'compress_ratio_pct': '$COMPRESS_RATIO',
        'pvc_count': $PVC_COUNT,
        'image_count': $IMAGE_COUNT,
        'csi_clones': $CSI_CLONE_COUNT,
        'copy_clones': $COPY_CLONE_COUNT,
    },
    'raw_data': {
        'ceph_df': json.loads('''$(echo "$CEPH_DF_JSON")'''),
        'rbd_du': json.loads('''$(echo "$RBD_DU_JSON")'''),
    }
}

with open('$DETAIL_FILE', 'w') as f:
    json.dump(detail, f, indent=2)
" 2>/dev/null || echo "  (Could not write detail JSON)"

echo ""
echo "============================================"
echo "  Measurement Complete: $LABEL"
echo "============================================"
echo ""
echo "  Data stored:  ${STORED_GB} GB  (unique data before replication)"
echo "  Disk used:    ${USED_GB} GB  (actual disk consumption after replication)"
if [[ "$COMPRESS_UNDER" -gt 0 ]]; then
    echo "  Compression:  ${COMPRESS_SAVED_GB} GB saved  (${COMPRESS_UNDER_GB} GB → ${COMPRESS_USED_GB} GB, ${COMPRESS_RATIO}% of original)"
fi
echo "  Objects:      $POOL_OBJECTS"
echo "  VM disks:     $PVC_COUNT"
echo ""
echo "  Results: $RESULTS_DIR/"
echo "  Summary: $SUMMARY_CSV"
