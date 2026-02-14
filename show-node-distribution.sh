#!/bin/bash
# ============================================================
# Show Node Distribution - Per-Node & Per-OSD Storage Report
# ============================================================
# Standalone utility (not part of the 01-07 test sequence).
# Queries Ceph via the toolbox pod and prints a colorful
# terminal report showing how data is distributed across
# cluster nodes and OSDs.
#
# Usage:
#   ./show-node-distribution.sh          # Print to terminal
#   ./show-node-distribution.sh --save   # Also save to results/
set -euo pipefail
source "$(dirname "$0")/00-config.sh"

SAVE_TO_FILE=false
if [[ "${1:-}" == "--save" ]]; then
    SAVE_TO_FILE=true
fi

echo "============================================"
echo "  Node Storage Distribution Report"
echo "  Pool: $CEPH_POOL"
echo "============================================"
echo ""

# Get toolbox pod
TOOLBOX_POD=$(oc get pod -n "$TOOLBOX_NS" -l "$TOOLBOX_SELECTOR" -o name 2>/dev/null | head -1)
if [[ -z "$TOOLBOX_POD" ]]; then
    echo "ERROR: Ceph toolbox pod not found."
    echo "  Ensure the rook-ceph-tools pod is running in $TOOLBOX_NS."
    echo "  Run 01-setup.sh or: oc patch OCSInitialization ocsinit -n openshift-storage --type json --patch '[{\"op\":\"replace\",\"path\":\"/spec/enableCephTools\",\"value\":true}]'"
    exit 1
fi

echo "Collecting data from Ceph..."

# Capture all three Ceph queries and export for Python
export OSD_DF_JSON=$(oc exec -n "$TOOLBOX_NS" "$TOOLBOX_POD" -- \
    ceph osd df tree --format json 2>/dev/null)

export POOL_STATS_JSON=$(oc exec -n "$TOOLBOX_NS" "$TOOLBOX_POD" -- \
    ceph osd pool stats "$CEPH_POOL" --format json 2>/dev/null || echo '[]')

export PG_JSON=$(oc exec -n "$TOOLBOX_NS" "$TOOLBOX_POD" -- \
    ceph pg ls-by-pool "$CEPH_POOL" --format json 2>/dev/null || echo '[]')

echo ""

# ── Generate report via Python ────────────────────────────

REPORT_OUTPUT=$(python3 - "$CEPH_POOL" <<'PYEOF'
import sys
import json

pool_name = sys.argv[1]

# JSON data is passed via exported environment variables
import os

osd_df_raw = os.environ.get('OSD_DF_JSON', '{}')
pool_stats_raw = os.environ.get('POOL_STATS_JSON', '[]')
pg_raw = os.environ.get('PG_JSON', '[]')

# ── Parse JSON safely ─────────────────────────────────────

def safe_json(raw, fallback):
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return fallback

osd_df = safe_json(osd_df_raw, {})
pool_stats = safe_json(pool_stats_raw, [])
pg_data = safe_json(pg_raw, [])

# ── ANSI Colors ───────────────────────────────────────────

RESET  = "\033[0m"
BOLD   = "\033[1m"
DIM    = "\033[2m"
RED    = "\033[31m"
GREEN  = "\033[32m"
YELLOW = "\033[33m"
BLUE   = "\033[34m"
CYAN   = "\033[36m"
WHITE  = "\033[37m"
BG_GREEN  = "\033[42m"
BG_YELLOW = "\033[43m"
BG_RED    = "\033[41m"

# ── Helpers ───────────────────────────────────────────────

def fmt_size(kb):
    """Format KiB value to human-readable."""
    if kb <= 0:
        return "0 B"
    if kb < 1024:
        return f"{kb:.1f} KiB"
    mb = kb / 1024
    if mb < 1024:
        return f"{mb:.1f} MiB"
    gb = mb / 1024
    if gb < 1024:
        return f"{gb:.1f} GiB"
    tb = gb / 1024
    return f"{tb:.2f} TiB"

def bar_chart(pct, width=30):
    """ASCII bar chart with color based on percentage."""
    filled = int(pct / 100 * width)
    filled = max(0, min(width, filled))
    empty = width - filled
    if pct < 65:
        color = GREEN
    elif pct < 80:
        color = YELLOW
    else:
        color = RED
    return f"{color}{'█' * filled}{DIM}{'░' * empty}{RESET}"

def status_badge(pct):
    """Color-coded status word."""
    if pct < 65:
        return f"{GREEN}{BOLD}OK{RESET}"
    elif pct < 80:
        return f"{YELLOW}{BOLD}WATCH{RESET}"
    else:
        return f"{RED}{BOLD}FULL{RESET}"

# ── Parse OSD tree ────────────────────────────────────────

nodes_by_id = {}
for node in osd_df.get('nodes', []):
    nodes_by_id[node['id']] = node

# Build host -> OSD mapping from the tree structure
hosts = {}  # hostname -> { 'node': node_data, 'osds': [osd_data, ...] }

for node in osd_df.get('nodes', []):
    if node.get('type') == 'host':
        hostname = node.get('name', f"host-{node['id']}")
        osd_list = []
        for child_id in node.get('children', []):
            child = nodes_by_id.get(child_id)
            if child and child.get('type') == 'osd':
                osd_list.append(child)
        hosts[hostname] = {
            'node': node,
            'osds': sorted(osd_list, key=lambda o: o.get('id', 0)),
        }

# If no hosts found, try flat OSD list
if not hosts and osd_df.get('nodes'):
    osds_flat = [n for n in osd_df['nodes'] if n.get('type') == 'osd']
    if osds_flat:
        hosts['unknown-host'] = {
            'node': {'name': 'unknown-host', 'kb': 0, 'kb_used': 0, 'kb_avail': 0},
            'osds': osds_flat,
        }
        # Sum up from OSDs
        total_kb = sum(o.get('kb', 0) for o in osds_flat)
        total_used = sum(o.get('kb_used', 0) for o in osds_flat)
        hosts['unknown-host']['node']['kb'] = total_kb
        hosts['unknown-host']['node']['kb_used'] = total_used
        hosts['unknown-host']['node']['kb_avail'] = total_kb - total_used

# ── Parse PG distribution ─────────────────────────────────

# pg_data can be a list of PGs or a dict with a 'pg_stats' key
pg_list = []
if isinstance(pg_data, list):
    pg_list = pg_data
elif isinstance(pg_data, dict):
    pg_list = pg_data.get('pg_stats', [])

osd_pg_count = {}  # osd_id -> count of PGs
for pg in pg_list:
    acting = pg.get('acting', [])
    for osd_id in acting:
        osd_pg_count[osd_id] = osd_pg_count.get(osd_id, 0) + 1

# ── Parse pool stats ──────────────────────────────────────

target_pool_stats = {}
if isinstance(pool_stats, list):
    for ps in pool_stats:
        if ps.get('pool_name') == pool_name:
            target_pool_stats = ps
            break
elif isinstance(pool_stats, dict):
    if pool_stats.get('pool_name') == pool_name:
        target_pool_stats = pool_stats

# ── Output ────────────────────────────────────────────────

lines = []

def out(text=""):
    lines.append(text)

# ── Section 1: Per-Node Summary ───────────────────────────

out(f"{BOLD}{CYAN}{'═' * 60}{RESET}")
out(f"{BOLD}{CYAN}  1. PER-NODE STORAGE SUMMARY{RESET}")
out(f"{BOLD}{CYAN}{'═' * 60}{RESET}")
out()

node_pcts = []
total_kb = 0
total_used = 0

if not hosts:
    out(f"  {YELLOW}No host/OSD data available.{RESET}")
    out()
else:
    # Header
    out(f"  {BOLD}{'Host':<25} {'Capacity':>10} {'Used':>10} {'%Used':>6}  {'OSDs':>4}  {'Bar':<32} {'Status'}{RESET}")
    out(f"  {'─' * 25} {'─' * 10} {'─' * 10} {'─' * 6}  {'─' * 4}  {'─' * 30}  {'─' * 6}")
    for hostname in sorted(hosts.keys()):
        h = hosts[hostname]
        node = h['node']
        osd_count = len(h['osds'])

        # Use node-level aggregates if available, else sum OSDs
        kb_total = node.get('kb', 0)
        kb_used = node.get('kb_used', 0)

        if kb_total <= 0 and h['osds']:
            kb_total = sum(o.get('kb', 0) for o in h['osds'])
            kb_used = sum(o.get('kb_used', 0) for o in h['osds'])

        pct = (kb_used / kb_total * 100) if kb_total > 0 else 0
        node_pcts.append(pct)

        cap_str = fmt_size(kb_total)
        used_str = fmt_size(kb_used)
        bar = bar_chart(pct)
        badge = status_badge(pct)

        out(f"  {hostname:<25} {cap_str:>10} {used_str:>10} {pct:>5.1f}%  {osd_count:>4}  {bar}  {badge}")

    out()
    total_kb = sum(hosts[h]['node'].get('kb', 0) or sum(o.get('kb', 0) for o in hosts[h]['osds']) for h in hosts)
    total_used = sum(hosts[h]['node'].get('kb_used', 0) or sum(o.get('kb_used', 0) for o in hosts[h]['osds']) for h in hosts)
    total_pct = (total_used / total_kb * 100) if total_kb > 0 else 0
    total_osds = sum(len(hosts[h]['osds']) for h in hosts)
    out(f"  {BOLD}{'TOTAL':<25} {fmt_size(total_kb):>10} {fmt_size(total_used):>10} {total_pct:>5.1f}%  {total_osds:>4}{RESET}")
    out()

# ── Section 2: Per-OSD Breakdown ──────────────────────────

out(f"{BOLD}{CYAN}{'═' * 60}{RESET}")
out(f"{BOLD}{CYAN}  2. PER-OSD BREAKDOWN{RESET}")
out(f"{BOLD}{CYAN}{'═' * 60}{RESET}")
out()

if not hosts:
    out(f"  {YELLOW}No OSD data available.{RESET}")
    out()
else:
    for hostname in sorted(hosts.keys()):
        h = hosts[hostname]
        out(f"  {BOLD}{BLUE}{hostname}{RESET}")

        if not h['osds']:
            out(f"    {DIM}(no OSDs){RESET}")
            out()
            continue

        for osd in h['osds']:
            osd_id = osd.get('id', '?')
            osd_name = osd.get('name', f'osd.{osd_id}')
            kb_total = osd.get('kb', 0)
            kb_used = osd.get('kb_used', 0)
            pct = (kb_used / kb_total * 100) if kb_total > 0 else 0
            bar = bar_chart(pct, width=20)
            pg_count = osd_pg_count.get(osd_id, 0)

            pg_str = f"  {DIM}PGs: {pg_count}{RESET}" if pg_count > 0 else ""

            out(f"    ├─ {osd_name:<10} {fmt_size(kb_total):>10} {fmt_size(kb_used):>10} {pct:>5.1f}%  {bar}{pg_str}")

        out()

# ── Section 3: Balance Assessment ─────────────────────────

out(f"{BOLD}{CYAN}{'═' * 60}{RESET}")
out(f"{BOLD}{CYAN}  3. BALANCE ASSESSMENT{RESET}")
out(f"{BOLD}{CYAN}{'═' * 60}{RESET}")
out()

if len(node_pcts) >= 2:
    max_pct = max(node_pcts)
    min_pct = min(node_pcts)
    spread = max_pct - min_pct

    out(f"  Highest node utilization:  {max_pct:.1f}%")
    out(f"  Lowest  node utilization:  {min_pct:.1f}%")
    out(f"  Spread:                    {spread:.1f} percentage points")
    out()

    if spread < 5:
        out(f"  {BG_GREEN}{BOLD} WELL BALANCED {RESET}")
        out(f"  {GREEN}Data is evenly distributed across all nodes.{RESET}")
        out(f"  {GREEN}No action needed.{RESET}")
    elif spread < 15:
        out(f"  {BG_YELLOW}{BOLD} SLIGHTLY UNEVEN {RESET}")
        out(f"  {YELLOW}Minor imbalance detected. This is usually acceptable.{RESET}")
        out(f"  {YELLOW}Ceph will gradually rebalance as new data is written.{RESET}")
    else:
        out(f"  {BG_RED}{BOLD} UNBALANCED {RESET}")
        out(f"  {RED}Significant storage imbalance across nodes.{RESET}")
        out(f"  {RED}Consider investigating:{RESET}")
        out(f"  {RED}  - Check OSD weights: ceph osd tree{RESET}")
        out(f"  {RED}  - Check CRUSH map: ceph osd crush dump{RESET}")
        out(f"  {RED}  - Trigger rebalance if needed: ceph osd reweight-by-utilization{RESET}")
elif hosts:
    if len(hosts) == 1:
        name = list(hosts.keys())[0]
        out(f"  {YELLOW}Single-node cluster detected ({name}).{RESET}")
        out(f"  {YELLOW}Balance assessment requires multiple nodes.{RESET}")
    else:
        out(f"  {YELLOW}Insufficient data for balance assessment.{RESET}")
else:
    out(f"  {YELLOW}No node data available.{RESET}")

out()

# ── Section 4: Pool PG Distribution ──────────────────────

out(f"{BOLD}{CYAN}{'═' * 60}{RESET}")
out(f"{BOLD}{CYAN}  4. POOL PG DISTRIBUTION (pool: {pool_name}){RESET}")
out(f"{BOLD}{CYAN}{'═' * 60}{RESET}")
out()

if osd_pg_count:
    max_pg = max(osd_pg_count.values()) if osd_pg_count else 1

    out(f"  {BOLD}{'OSD':<10} {'PGs':>6}  {'Distribution'}{RESET}")
    out(f"  {'─' * 10} {'─' * 6}  {'─' * 30}")

    for osd_id in sorted(osd_pg_count.keys()):
        count = osd_pg_count[osd_id]
        bar_len = int(count / max_pg * 25) if max_pg > 0 else 0
        bar_len = max(1, bar_len)
        out(f"  {'osd.' + str(osd_id):<10} {count:>6}  {BLUE}{'█' * bar_len}{RESET}")

    total_pgs = sum(osd_pg_count.values())
    avg_pgs = total_pgs / len(osd_pg_count) if osd_pg_count else 0
    out()
    out(f"  Total PGs across OSDs: {total_pgs}  (each PG is replicated, so counted per replica)")
    out(f"  Average PGs per OSD:   {avg_pgs:.1f}")

    if len(osd_pg_count) > 1:
        pg_min = min(osd_pg_count.values())
        pg_max = max(osd_pg_count.values())
        if avg_pgs > 0:
            pg_spread_pct = ((pg_max - pg_min) / avg_pgs) * 100
            if pg_spread_pct < 20:
                out(f"  PG spread:             {GREEN}Even ({pg_spread_pct:.0f}% variance){RESET}")
            elif pg_spread_pct < 50:
                out(f"  PG spread:             {YELLOW}Moderate ({pg_spread_pct:.0f}% variance){RESET}")
            else:
                out(f"  PG spread:             {RED}Uneven ({pg_spread_pct:.0f}% variance){RESET}")
else:
    out(f"  {YELLOW}No placement group data available for pool '{pool_name}'.{RESET}")
    out(f"  {DIM}This may mean the pool is empty or PG query is not supported.{RESET}")

out()

# ── Section 5: Pool Activity ─────────────────────────────

out(f"{BOLD}{CYAN}{'═' * 60}{RESET}")
out(f"{BOLD}{CYAN}  5. POOL ACTIVITY (pool: {pool_name}){RESET}")
out(f"{BOLD}{CYAN}{'═' * 60}{RESET}")
out()

client_io = target_pool_stats.get('client_io_rate', {})
recovery = target_pool_stats.get('recovery_rate', {})

read_ops = client_io.get('read_bytes_sec', 0)
write_ops = client_io.get('write_bytes_sec', 0)
read_op_s = client_io.get('read_op_per_sec', 0)
write_op_s = client_io.get('write_op_per_sec', 0)

if any([read_ops, write_ops, read_op_s, write_op_s]):
    out(f"  Client I/O:")
    out(f"    Read:  {fmt_size(read_ops / 1024)}/s  ({read_op_s} ops/s)")
    out(f"    Write: {fmt_size(write_ops / 1024)}/s  ({write_op_s} ops/s)")
else:
    out(f"  Client I/O: {DIM}No active I/O{RESET}")

recovery_bytes = recovery.get('recovering_bytes_per_sec', 0)
recovery_keys = recovery.get('recovering_keys_per_sec', 0)
recovery_objects = recovery.get('recovering_objects_per_sec', 0)

if any([recovery_bytes, recovery_keys, recovery_objects]):
    out(f"  Recovery:")
    out(f"    {YELLOW}Recovery in progress: {fmt_size(recovery_bytes / 1024)}/s, {recovery_objects} objects/s{RESET}")
else:
    out(f"  Recovery:  {GREEN}None (cluster is clean){RESET}")

out()

# ── Section 6: What Does This Mean? ──────────────────────

out(f"{BOLD}{CYAN}{'═' * 60}{RESET}")
out(f"{BOLD}{CYAN}  6. WHAT DOES THIS MEAN?{RESET}")
out(f"{BOLD}{CYAN}{'═' * 60}{RESET}")
out()

node_count = len(hosts)
total_osd_count = sum(len(hosts[h]['osds']) for h in hosts)

# Balance summary
if len(node_pcts) >= 2:
    spread = max(node_pcts) - min(node_pcts)
    if spread < 5:
        out(f"  {GREEN}✓ Balance:{RESET}  Storage is well balanced across your {node_count} nodes.")
        out(f"              Each node is carrying a similar share of the data.")
    elif spread < 15:
        out(f"  {YELLOW}~ Balance:{RESET}  Slight imbalance ({spread:.1f}pt spread) across {node_count} nodes.")
        out(f"              This is normal and Ceph will self-correct over time.")
    else:
        out(f"  {RED}✗ Balance:{RESET}  Significant imbalance ({spread:.1f}pt spread) across {node_count} nodes.")
        out(f"              Some nodes are working harder than others. Consider rebalancing.")
elif node_count == 1:
    out(f"  {YELLOW}~ Balance:{RESET}  Single-node cluster — all data is on one node.")
    out(f"              This is expected for single-node setups but offers no redundancy.")
else:
    out(f"  {DIM}  Balance: Unable to assess (insufficient data).{RESET}")

out()

# Hotspot check
if osd_pg_count and len(osd_pg_count) > 1:
    pg_vals = list(osd_pg_count.values())
    pg_avg = sum(pg_vals) / len(pg_vals)
    pg_max_id = max(osd_pg_count, key=osd_pg_count.get)
    pg_max_val = osd_pg_count[pg_max_id]

    if pg_avg > 0 and (pg_max_val / pg_avg) > 1.5:
        out(f"  {YELLOW}~ Hotspots:{RESET} OSD {pg_max_id} has {pg_max_val} PGs (avg {pg_avg:.0f}). It may be a hotspot.")
        out(f"              Monitor I/O latency on this OSD.")
    else:
        out(f"  {GREEN}✓ Hotspots:{RESET} No hotspots detected. PG distribution is even across OSDs.")
else:
    out(f"  {DIM}  Hotspots: Unable to assess (no PG data or single OSD).{RESET}")

out()

# Capacity headroom
if total_kb > 0:
    total_pct_used = (total_used / total_kb * 100)
    avail_tb = (total_kb - total_used) / 1024 / 1024 / 1024
    if total_pct_used < 65:
        out(f"  {GREEN}✓ Capacity:{RESET} {total_pct_used:.1f}% used — plenty of headroom.")
        out(f"              {fmt_size(total_kb - total_used)} available across the cluster.")
    elif total_pct_used < 75:
        out(f"  {YELLOW}~ Capacity:{RESET} {total_pct_used:.1f}% used — approaching the 75% planning threshold.")
        out(f"              Start planning for expansion. {fmt_size(total_kb - total_used)} remaining.")
    elif total_pct_used < 80:
        out(f"  {YELLOW}~ Capacity:{RESET} {total_pct_used:.1f}% used — past the 75% planning threshold.")
        out(f"              Expansion recommended soon. Ceph slows down above 80%.")
    elif total_pct_used < 85:
        out(f"  {RED}✗ Capacity:{RESET} {total_pct_used:.1f}% used — approaching critical levels!")
        out(f"              Ceph starts throttling writes near 85%. Expand storage urgently.")
    else:
        out(f"  {RED}✗ Capacity:{RESET} {total_pct_used:.1f}% used — CRITICAL!")
        out(f"              Ceph may be throttling I/O. Immediate action required!")
else:
    out(f"  {DIM}  Capacity: Unable to assess (no capacity data).{RESET}")

out()

# Pool health
if any([recovery_bytes, recovery_keys, recovery_objects]):
    out(f"  {YELLOW}~ Pool:{RESET}     Recovery is in progress for pool '{pool_name}'.")
    out(f"              I/O performance may be reduced until recovery completes.")
elif target_pool_stats:
    out(f"  {GREEN}✓ Pool:{RESET}     Pool '{pool_name}' is healthy with no active recovery.")
else:
    out(f"  {DIM}  Pool:     No pool activity data available for '{pool_name}'.{RESET}")

out()

# Final note
out(f"  {DIM}Tip: Run this script periodically during testing to track")
out(f"  how cloning and drift affect distribution across nodes.{RESET}")
out()

# ── Print all output ──────────────────────────────────────

print('\n'.join(lines))
PYEOF
)

# Handle --save flag
if [[ "$SAVE_TO_FILE" == "true" ]]; then
    TIMESTAMP=$(date -u +"%Y%m%d-%H%M%S")
    SAVE_FILE="$RESULTS_DIR/node-distribution-${TIMESTAMP}.txt"

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
