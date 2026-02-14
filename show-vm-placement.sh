#!/bin/bash
# ============================================================
# Show VM Placement - Trace a Single VM's Data Path
# ============================================================
# Standalone utility (not part of the 01-07 test sequence).
# Picks one VM disk, traces its Ceph data path from PVC down
# to physical OSD/node placement, and prints a colorful
# educational report.
#
# Usage:
#   ./show-vm-placement.sh                # auto-pick first clone (or golden image)
#   ./show-vm-placement.sh clone-vm-005   # trace a specific VM
#   ./show-vm-placement.sh --save         # also save to results/
#   ./show-vm-placement.sh clone-vm-005 --save
set -euo pipefail
source "$(dirname "$0")/00-config.sh"

# ── Parse arguments ──────────────────────────────────────
VM_NAME=""
SAVE_TO_FILE=false

for arg in "$@"; do
    if [[ "$arg" == "--save" ]]; then
        SAVE_TO_FILE=true
    elif [[ -z "$VM_NAME" ]]; then
        VM_NAME="$arg"
    fi
done

echo "============================================"
echo "  VM Data Placement Trace"
echo "  Pool: $CEPH_POOL"
echo "============================================"
echo ""

# ── Get toolbox pod ──────────────────────────────────────
TOOLBOX_POD=$(oc get pod -n "$TOOLBOX_NS" -l "$TOOLBOX_SELECTOR" -o name 2>/dev/null | head -1)
if [[ -z "$TOOLBOX_POD" ]]; then
    echo "ERROR: Ceph toolbox pod not found."
    echo "  Ensure the rook-ceph-tools pod is running in $TOOLBOX_NS."
    echo "  Run 01-setup.sh or: oc patch OCSInitialization ocsinit -n openshift-storage --type json --patch '[{\"op\":\"replace\",\"path\":\"/spec/enableCephTools\",\"value\":true}]'"
    exit 1
fi

# ── Find VM and its PVC ─────────────────────────────────
if [[ -z "$VM_NAME" ]]; then
    # Auto-pick: first clone, or golden image if no clones
    FIRST_CLONE=$(oc get vm -n "$TEST_NS" -l "role=clone" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "$FIRST_CLONE" ]]; then
        VM_NAME="$FIRST_CLONE"
    else
        VM_NAME="$GOLDEN_VM_NAME"
    fi
    echo "Auto-selected VM: $VM_NAME"
fi

# Get PVC name from the VM's volume spec
PVC_NAME=$(oc get vm "$VM_NAME" -n "$TEST_NS" -o json 2>/dev/null | python3 -c "
import sys, json
vm = json.load(sys.stdin)
spec = vm.get('spec', {})
# Check dataVolumeTemplates first (clone VMs)
for dvt in spec.get('dataVolumeTemplates', []):
    print(dvt['metadata']['name'])
    sys.exit(0)
# Check volumes for direct dataVolume or PVC references
for vol in spec.get('template', {}).get('spec', {}).get('volumes', []):
    if 'dataVolume' in vol:
        print(vol['dataVolume']['name'])
        sys.exit(0)
    if 'persistentVolumeClaim' in vol:
        print(vol['persistentVolumeClaim']['claimName'])
        sys.exit(0)
print('')
" 2>/dev/null || true)

if [[ -z "$PVC_NAME" ]]; then
    echo "ERROR: Could not find a disk PVC for VM '$VM_NAME' in namespace '$TEST_NS'."
    echo "  Available VMs:"
    oc get vm -n "$TEST_NS" -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null || true
    exit 1
fi

# ── Map PVC → PV → RBD image ────────────────────────────
PV_NAME=$(oc get pvc "$PVC_NAME" -n "$TEST_NS" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)
if [[ -z "$PV_NAME" ]]; then
    echo "ERROR: PVC '$PVC_NAME' has no bound PV. Is the disk still provisioning?"
    exit 1
fi

RBD_IMAGE=$(oc get pv "$PV_NAME" -o jsonpath='{.spec.csi.volumeAttributes.imageName}' 2>/dev/null || true)
if [[ -z "$RBD_IMAGE" ]]; then
    echo "ERROR: PV '$PV_NAME' has no RBD image name. Is this a Ceph RBD volume?"
    exit 1
fi

echo "Tracing: $VM_NAME → $PVC_NAME → $PV_NAME → $CEPH_POOL/$RBD_IMAGE"
echo ""

# ── Collect Ceph data ────────────────────────────────────
echo "Collecting data from Ceph..."

# 1. RBD image info
export RBD_INFO_JSON=$(oc exec -n "$TOOLBOX_NS" "$TOOLBOX_POD" -- \
    rbd info "$CEPH_POOL/$RBD_IMAGE" --format json 2>/dev/null || echo '{}')

# 2. OSD tree topology
export OSD_DF_JSON=$(oc exec -n "$TOOLBOX_NS" "$TOOLBOX_POD" -- \
    ceph osd df tree --format json 2>/dev/null)

# 3. Parse image info to build object names for sampling
read -r BLOCK_PREFIX OBJ_SIZE IMG_SIZE < <(echo "$RBD_INFO_JSON" | python3 -c "
import sys, json
info = json.load(sys.stdin)
prefix = info.get('block_name_prefix', '')
obj_size = info.get('order', 22)  # log2 of object size, default 4MiB
img_size = info.get('size', 0)
print(prefix, 2**obj_size, img_size)
" 2>/dev/null || echo "")

if [[ -z "$BLOCK_PREFIX" || "$BLOCK_PREFIX" == "None" ]]; then
    echo "ERROR: Could not read RBD image metadata for '$CEPH_POOL/$RBD_IMAGE'."
    echo "  The image may not exist or may not be accessible."
    exit 1
fi

# 4. Sample ~20 object placements in a single oc exec call
TOTAL_OBJECTS=$(( IMG_SIZE / OBJ_SIZE ))
if [[ $TOTAL_OBJECTS -eq 0 ]]; then
    TOTAL_OBJECTS=1
fi

SAMPLE_COUNT=20
if [[ $TOTAL_OBJECTS -lt $SAMPLE_COUNT ]]; then
    SAMPLE_COUNT=$TOTAL_OBJECTS
fi

# Build the list of object names to probe
OBJECT_NAMES=$(python3 -c "
total = $TOTAL_OBJECTS
sample = $SAMPLE_COUNT
prefix = '$BLOCK_PREFIX'
step = max(1, total // sample)
names = []
for i in range(0, total, step):
    names.append(f'{prefix}.{i:016x}')
    if len(names) >= sample:
        break
for n in names:
    print(n)
" 2>/dev/null)

# Build a bash one-liner to run all ceph osd map calls inside the toolbox
OSD_MAP_SCRIPT=""
while IFS= read -r obj_name; do
    OSD_MAP_SCRIPT+="ceph osd map $CEPH_POOL $obj_name 2>/dev/null; "
done <<< "$OBJECT_NAMES"

export OSD_MAP_OUTPUT=$(oc exec -n "$TOOLBOX_NS" "$TOOLBOX_POD" -- \
    bash -c "$OSD_MAP_SCRIPT" 2>/dev/null || echo "")

# 5. Check for parent (clone lineage)
export PARENT_INFO=$(oc exec -n "$TOOLBOX_NS" "$TOOLBOX_POD" -- \
    rbd info "$CEPH_POOL/$RBD_IMAGE" --format json 2>/dev/null | \
    python3 -c "
import sys, json
info = json.load(sys.stdin)
parent = info.get('parent', {})
if parent:
    pool = parent.get('pool_name', parent.get('pool', ''))
    image = parent.get('image', '')
    snap = parent.get('snapshot', parent.get('snap', ''))
    print(f'{pool}/{image}@{snap}')
else:
    print('')
" 2>/dev/null || echo "")

# 6. Get actual storage used by this image (rbd du for the specific image)
export RBD_DU_JSON=$(oc exec -n "$TOOLBOX_NS" "$TOOLBOX_POD" -- \
    rbd du "$CEPH_POOL/$RBD_IMAGE" --format json 2>/dev/null || echo '{"images":[]}')

echo ""

# ── Export remaining vars for Python ─────────────────────
export VM_NAME PVC_NAME PV_NAME RBD_IMAGE CEPH_POOL
export BLOCK_PREFIX OBJ_SIZE IMG_SIZE TOTAL_OBJECTS SAMPLE_COUNT

# ── Generate report via Python ───────────────────────────

REPORT_OUTPUT=$(python3 - <<'PYEOF'
import os
import sys
import json
import re

# ── Load environment ─────────────────────────────────────

vm_name = os.environ.get('VM_NAME', '')
pvc_name = os.environ.get('PVC_NAME', '')
pv_name = os.environ.get('PV_NAME', '')
rbd_image = os.environ.get('RBD_IMAGE', '')
ceph_pool = os.environ.get('CEPH_POOL', '')
block_prefix = os.environ.get('BLOCK_PREFIX', '')
obj_size = int(os.environ.get('OBJ_SIZE', 4194304))
img_size = int(os.environ.get('IMG_SIZE', 0))
total_objects = int(os.environ.get('TOTAL_OBJECTS', 0))
sample_count = int(os.environ.get('SAMPLE_COUNT', 0))

def safe_json(raw, fallback):
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return fallback

rbd_info = safe_json(os.environ.get('RBD_INFO_JSON', '{}'), {})
osd_df = safe_json(os.environ.get('OSD_DF_JSON', '{}'), {})
rbd_du = safe_json(os.environ.get('RBD_DU_JSON', '{}'), {})
osd_map_output = os.environ.get('OSD_MAP_OUTPUT', '')
parent_info = os.environ.get('PARENT_INFO', '')

# ── ANSI Colors ──────────────────────────────────────────

RESET  = "\033[0m"
BOLD   = "\033[1m"
DIM    = "\033[2m"
RED    = "\033[31m"
GREEN  = "\033[32m"
YELLOW = "\033[33m"
BLUE   = "\033[34m"
MAGENTA = "\033[35m"
CYAN   = "\033[36m"
WHITE  = "\033[37m"

# ── Helpers ──────────────────────────────────────────────

def fmt_size(bytes_val):
    """Format bytes to human-readable."""
    if bytes_val <= 0:
        return "0 B"
    kb = bytes_val / 1024
    if kb < 1:
        return f"{bytes_val} B"
    mb = kb / 1024
    if mb < 1:
        return f"{kb:.1f} KiB"
    gb = mb / 1024
    if gb < 1:
        return f"{mb:.1f} MiB"
    tb = gb / 1024
    if tb < 1:
        return f"{gb:.2f} GiB"
    return f"{tb:.2f} TiB"

def bar_chart(count, max_count, width=30, color=BLUE):
    """ASCII bar chart."""
    if max_count <= 0:
        return ""
    filled = int(count / max_count * width)
    filled = max(0, min(width, filled))
    empty = width - filled
    return f"{color}{'█' * filled}{DIM}{'░' * empty}{RESET}"

# ── Build OSD → host mapping ────────────────────────────

nodes_by_id = {}
for node in osd_df.get('nodes', []):
    nodes_by_id[node['id']] = node

osd_to_host = {}  # osd_id -> hostname
host_osds = {}    # hostname -> [osd_ids]

for node in osd_df.get('nodes', []):
    if node.get('type') == 'host':
        hostname = node.get('name', f"host-{node['id']}")
        for child_id in node.get('children', []):
            child = nodes_by_id.get(child_id)
            if child and child.get('type') == 'osd':
                osd_to_host[child['id']] = hostname
                host_osds.setdefault(hostname, []).append(child['id'])

# ── Parse ceph osd map output ───────────────────────────
# Format: osdmap eN pool 'name' (id) object 'obj' -> pg X.Y (X.Z) -> up ([a,b,c], pN) acting ([a,b,c], pN)

placements = []

for line in osd_map_output.strip().split('\n'):
    if not line.strip():
        continue
    # Extract object name
    obj_match = re.search(r"object '([^']+)'", line)
    # Extract PG
    pg_match = re.search(r"-> pg (\S+)", line)
    # Extract acting set (the OSDs that actually store the data)
    acting_match = re.search(r"acting \(\[([^\]]*)\]", line)

    if obj_match and pg_match and acting_match:
        obj_name = obj_match.group(1)
        pg = pg_match.group(1)
        osd_ids = [int(x.strip()) for x in acting_match.group(1).split(',') if x.strip().lstrip('-').isdigit()]
        placements.append({
            'object': obj_name,
            'pg': pg,
            'primary_osd': osd_ids[0] if osd_ids else -1,
            'replica_osds': osd_ids[1:] if len(osd_ids) > 1 else [],
            'all_osds': osd_ids,
        })

# ── Get actual disk usage ────────────────────────────────

used_bytes = 0
provisioned_bytes = 0
for img in rbd_du.get('images', []):
    if img.get('name') == rbd_image:
        used_bytes = img.get('used_size', 0)
        provisioned_bytes = img.get('provisioned_size', img_size)
        break

# ── Output ───────────────────────────────────────────────

lines = []

def out(text=""):
    lines.append(text)

# ── Section 1: VM Identity ───────────────────────────────

out(f"{BOLD}{CYAN}{'═' * 62}{RESET}")
out(f"{BOLD}{CYAN}  1. VM IDENTITY — TRACING THE DATA PATH{RESET}")
out(f"{BOLD}{CYAN}{'═' * 62}{RESET}")
out()
out(f"  This section shows how Kubernetes maps a VM's disk all the")
out(f"  way down to a Ceph block device. Each arrow is a layer of")
out(f"  abstraction that OpenShift manages for you.")
out()
out(f"  {BOLD}VM{RESET}                 {GREEN}{vm_name}{RESET}")
out(f"   └─ {BOLD}PVC{RESET}             {GREEN}{pvc_name}{RESET}")
out(f"       └─ {BOLD}PV{RESET}           {GREEN}{pv_name}{RESET}")
out(f"           └─ {BOLD}RBD Image{RESET}   {GREEN}{ceph_pool}/{rbd_image}{RESET}")
out()
out(f"  {BOLD}Disk size:{RESET}        {fmt_size(img_size)}")
out(f"  {BOLD}Object size:{RESET}      {fmt_size(obj_size)}  (each RADOS object)")
out(f"  {BOLD}Total objects:{RESET}    {total_objects:,}")
out(f"  {BOLD}Actual usage:{RESET}     {fmt_size(used_bytes)}")
out()
if img_size > 0 and used_bytes > 0:
    usage_pct = used_bytes / img_size * 100
    out(f"  {DIM}This disk is {fmt_size(img_size)} in size but only uses")
    out(f"  {fmt_size(used_bytes)} ({usage_pct:.1f}%) of actual storage.{RESET}")
elif img_size > 0 and used_bytes == 0:
    out(f"  {DIM}Actual usage data not available (rbd du may still be computing).{RESET}")
out()

# ── Section 2: Clone Lineage ────────────────────────────

out(f"{BOLD}{CYAN}{'═' * 62}{RESET}")
out(f"{BOLD}{CYAN}  2. CLONE LINEAGE{RESET}")
out(f"{BOLD}{CYAN}{'═' * 62}{RESET}")
out()

if parent_info:
    out(f"  This image is a {BOLD}copy-on-write (CoW) clone{RESET}. It shares")
    out(f"  data blocks with the parent until written to.")
    out()
    out(f"  {BOLD}{MAGENTA}Parent image:{RESET}  {parent_info}")
    out(f"       │")
    out(f"       ▼  {DIM}(CoW snapshot){RESET}")
    out(f"  {BOLD}{GREEN}This clone:{RESET}    {ceph_pool}/{rbd_image}")
    out()
    out(f"  {DIM}How CoW works: The clone starts by sharing 100% of the")
    out(f"  parent's data. When the VM writes to a block, only that")
    out(f"  {fmt_size(obj_size)} chunk is copied and becomes unique to this clone.")
    out(f"  Unmodified chunks are never duplicated — they are shared{RESET}")
    out(f"  {DIM}pointers to the parent's data.{RESET}")
else:
    out(f"  This is a {BOLD}root image{RESET} (not a clone).")
    out(f"  All of its data is stored independently.")
    out()
    if 'golden' in vm_name.lower() or 'template' in vm_name.lower():
        out(f"  {DIM}As the golden template, this image is the parent that all")
        out(f"  clones reference. Its data blocks are shared (read-only)")
        out(f"  with every clone created from it.{RESET}")
    else:
        out(f"  {DIM}This image has no parent snapshot. Its data is fully")
        out(f"  independent — not shared with any other image.{RESET}")
out()

# ── Section 3: Data Anatomy ─────────────────────────────

out(f"{BOLD}{CYAN}{'═' * 62}{RESET}")
out(f"{BOLD}{CYAN}  3. DATA ANATOMY — HOW THE DISK IS SLICED{RESET}")
out(f"{BOLD}{CYAN}{'═' * 62}{RESET}")
out()
out(f"  Ceph doesn't store your {fmt_size(img_size)} disk as one big file.")
out(f"  Instead, it splits it into {BOLD}{total_objects:,} objects{RESET} of")
out(f"  {fmt_size(obj_size)} each. Each object is an independent unit")
out(f"  that can be placed on any OSD in the cluster.")
out()
out(f"  {BOLD}Object naming:{RESET}")
out(f"    Prefix:  {YELLOW}{block_prefix}{RESET}")
out(f"    Pattern: {YELLOW}{block_prefix}{RESET}.{DIM}<16-hex-digit offset>{RESET}")
out()
out(f"  {BOLD}Examples:{RESET}")
out(f"    {YELLOW}{block_prefix}.{'0' * 16}{RESET}  ← first {fmt_size(obj_size)} of disk")
if total_objects > 2:
    mid = total_objects // 2
    out(f"    {YELLOW}{block_prefix}.{mid:016x}{RESET}  ← middle of disk")
out(f"    {YELLOW}{block_prefix}.{(total_objects - 1):016x}{RESET}  ← last chunk of disk")
out()
out(f"  {DIM}Each object is independently replicated (typically 3 copies)")
out(f"  and placed on different OSDs/nodes by Ceph's CRUSH algorithm.{RESET}")
out()

# ── Section 4: Sample Placement Trace ───────────────────

out(f"{BOLD}{CYAN}{'═' * 62}{RESET}")
out(f"{BOLD}{CYAN}  4. SAMPLE PLACEMENT TRACE{RESET}")
out(f"{BOLD}{CYAN}{'═' * 62}{RESET}")
out()

if placements:
    out(f"  Sampled {len(placements)} of {total_objects:,} objects to show where data lands.")
    out(f"  Each row shows one {fmt_size(obj_size)} chunk and its physical location.")
    out()

    # Determine column widths
    obj_width = max(len(p['object']) for p in placements)
    obj_width = max(obj_width, 12)
    # Truncate long object names for display
    if obj_width > 32:
        obj_display_width = 32
    else:
        obj_display_width = obj_width

    out(f"  {BOLD}{'Object':<{obj_display_width}}  {'PG':<12} {'Primary':<10} {'Replicas':<16} {'Node'}{RESET}")
    out(f"  {'─' * obj_display_width}  {'─' * 12} {'─' * 10} {'─' * 16} {'─' * 16}")

    for p in placements:
        obj_display = p['object']
        if len(obj_display) > obj_display_width:
            obj_display = obj_display[:obj_display_width - 2] + '..'

        primary = f"osd.{p['primary_osd']}" if p['primary_osd'] >= 0 else "?"
        replicas = ', '.join(f"osd.{o}" for o in p['replica_osds']) if p['replica_osds'] else "none"
        host = osd_to_host.get(p['primary_osd'], '?')

        out(f"  {YELLOW}{obj_display:<{obj_display_width}}{RESET}  {p['pg']:<12} {GREEN}{primary:<10}{RESET} {DIM}{replicas:<16}{RESET} {BLUE}{host}{RESET}")

    out()
else:
    out(f"  {YELLOW}Could not retrieve placement data.{RESET}")
    out(f"  {DIM}The ceph osd map command may not be available or the image is empty.{RESET}")
    out()

# ── Section 5: Node Coverage Heatmap ────────────────────

out(f"{BOLD}{CYAN}{'═' * 62}{RESET}")
out(f"{BOLD}{CYAN}  5. NODE COVERAGE — WHERE THIS VM'S DATA LIVES{RESET}")
out(f"{BOLD}{CYAN}{'═' * 62}{RESET}")
out()

if placements:
    # Count how many sampled objects land on each node (as primary)
    node_primary_count = {}
    # Count total OSD appearances (primary + replica) per node
    node_total_count = {}

    for p in placements:
        for osd_id in p['all_osds']:
            host = osd_to_host.get(osd_id, 'unknown')
            node_total_count[host] = node_total_count.get(host, 0) + 1
        if p['primary_osd'] >= 0:
            host = osd_to_host.get(p['primary_osd'], 'unknown')
            node_primary_count[host] = node_primary_count.get(host, 0) + 1

    max_count = max(node_total_count.values()) if node_total_count else 1
    total_placements = sum(node_total_count.values())
    all_hosts = sorted(host_osds.keys())
    node_count = len(all_hosts)
    nodes_with_data = len([h for h in all_hosts if node_total_count.get(h, 0) > 0])

    name_width = max((len(h) for h in all_hosts), default=10)
    name_width = max(name_width, 8)

    out(f"  {BOLD}{'Node':<{name_width}}  {'Primary':>8} {'+ Replica':>10} {'Total':>6}  {'Distribution'}{RESET}")
    out(f"  {'─' * name_width}  {'─' * 8} {'─' * 10} {'─' * 6}  {'─' * 32}")

    colors = [GREEN, BLUE, MAGENTA, YELLOW, CYAN, RED]

    for i, host in enumerate(all_hosts):
        primary = node_primary_count.get(host, 0)
        total = node_total_count.get(host, 0)
        replica = total - primary
        color = colors[i % len(colors)]
        bar = bar_chart(total, max_count, width=28, color=color)
        out(f"  {BOLD}{host:<{name_width}}{RESET}  {primary:>8} {replica:>10} {total:>6}  {bar}")

    out()

    if nodes_with_data == node_count and node_count > 1:
        out(f"  {GREEN}{BOLD}→ This VM's data touches ALL {node_count} nodes in the cluster.{RESET}")
    elif nodes_with_data > 1:
        out(f"  {YELLOW}→ This VM's data is spread across {nodes_with_data} of {node_count} nodes.{RESET}")
    elif node_count == 1:
        out(f"  {YELLOW}→ Single-node cluster: all data is on one node.{RESET}")
    else:
        out(f"  {YELLOW}→ Data placement could not be fully determined.{RESET}")

    # Show unique PGs
    unique_pgs = set(p['pg'] for p in placements)
    unique_osds = set()
    for p in placements:
        for osd_id in p['all_osds']:
            unique_osds.add(osd_id)
    total_osds = sum(len(osds) for osds in host_osds.values())

    out(f"  {DIM}Unique PGs in sample: {len(unique_pgs)} | OSDs touched: {len(unique_osds)} of {total_osds}{RESET}")
else:
    out(f"  {YELLOW}No placement data available.{RESET}")
out()

# ── Section 6: What This Means ──────────────────────────

out(f"{BOLD}{CYAN}{'═' * 62}{RESET}")
out(f"{BOLD}{CYAN}  6. WHAT THIS MEANS{RESET}")
out(f"{BOLD}{CYAN}{'═' * 62}{RESET}")
out()

# Data distribution summary
if placements and node_count > 0:
    out(f"  {GREEN}✓ Spreading:{RESET}  Your VM's {fmt_size(img_size)} disk is split into {total_objects:,} chunks")
    out(f"               spread across {nodes_with_data} node{'s' if nodes_with_data != 1 else ''}.")
    out()

# Resilience
if placements and node_count >= 3:
    out(f"  {GREEN}✓ Resilience:{RESET} Every chunk has replicas on different nodes.")
    out(f"               No single node failure would lose your data.")
    out()
elif placements and node_count == 2:
    out(f"  {YELLOW}~ Resilience:{RESET} Data is replicated across 2 nodes.")
    out(f"               Losing one node is survivable, but there's no margin.")
    out()
elif placements and node_count == 1:
    out(f"  {RED}✗ Resilience:{RESET} Single-node cluster — no redundancy across nodes.")
    out(f"               A node failure would cause data unavailability.")
    out()

# Clone efficiency
if parent_info:
    out(f"  {GREEN}✓ Efficiency:{RESET} This is a CoW clone. It shares most of its data")
    out(f"               with the golden image parent.")
    if used_bytes > 0 and img_size > 0:
        unique_pct = used_bytes / img_size * 100
        out(f"               Only {fmt_size(used_bytes)} ({unique_pct:.1f}%) is unique to this VM.")
        out(f"               The other {100 - unique_pct:.1f}% is shared — zero extra storage cost.")
    else:
        out(f"               Only the chunks this VM has written to consume")
        out(f"               additional storage. Unmodified chunks are free.")
    out()
elif used_bytes > 0 and img_size > 0:
    out(f"  {BOLD}Capacity:{RESET}     This disk is {fmt_size(img_size)} but uses {fmt_size(used_bytes)}")
    out(f"               of actual storage (thin provisioning).")
    out()

# VMware comparison
if parent_info:
    out(f"  {DIM}VMware comparison: This is like a VMware linked clone. The golden")
    out(f"  image is the base disk, and each clone only stores its differences.")
    out(f"  Unlike VMware, Ceph also spreads each VM's data across all nodes,")
    out(f"  so there's no single-datastore bottleneck.{RESET}")
else:
    out(f"  {DIM}VMware comparison: This root image is like a VMware template VMDK.")
    out(f"  Unlike VMware (which stores the whole VMDK on one or two datastores),")
    out(f"  Ceph splits it into {total_objects:,} chunks spread across every node —")
    out(f"  giving you parallel I/O and automatic fault tolerance.{RESET}")
out()

# ── Print all output ─────────────────────────────────────

print('\n'.join(lines))
PYEOF
)

# ── Handle output ────────────────────────────────────────
if [[ "$SAVE_TO_FILE" == "true" ]]; then
    TIMESTAMP=$(date -u +"%Y%m%d-%H%M%S")
    SAVE_FILE="$RESULTS_DIR/vm-placement-${VM_NAME}-${TIMESTAMP}.txt"

    # Strip ANSI escape codes and write to file (perl works on both macOS and Linux)
    echo "$REPORT_OUTPUT" | perl -pe 's/\e\[[0-9;]*m//g' > "$SAVE_FILE"

    # Print colored version to terminal
    echo "$REPORT_OUTPUT"

    echo ""
    echo "============================================"
    echo "  Report saved to: $SAVE_FILE"
    echo "============================================"
else
    echo "$REPORT_OUTPUT"
fi
