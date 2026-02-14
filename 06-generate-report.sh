#!/bin/bash
# ============================================================
# Generate Storage Efficiency Report (Rich HTML)
# ============================================================
# Reads summary.csv and environment-summary.txt to produce a
# self-contained HTML report with interactive charts, tables,
# and plain-language analysis.
set -euo pipefail
source "$(dirname "$0")/00-config.sh"

SUMMARY_CSV="$RESULTS_DIR/summary.csv"
REPORT_FILE="$RESULTS_DIR/storage-efficiency-report.html"

if [[ ! -f "$SUMMARY_CSV" ]]; then
    echo "ERROR: No summary.csv found in $RESULTS_DIR."
    echo "  Run measurements first (03-measure-storage.sh)."
    exit 1
fi

echo "============================================"
echo "  Generating Storage Efficiency Report"
echo "============================================"

python3 - "$SUMMARY_CSV" "$REPORT_FILE" "$RESULTS_DIR" "${GOLDEN_DISK_SIZE:-}" << 'PYEOF'
import csv
import sys
import os
import json
import html
import re
from datetime import datetime, timezone

summary_file = sys.argv[1]
report_file = sys.argv[2]
results_dir = sys.argv[3]
golden_disk_size_raw = sys.argv[4] if len(sys.argv) > 4 else ''

# ── Data Loading ─────────────────────────────────────────

def load_measurements():
    measurements = []
    with open(summary_file, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            measurements.append(row)
    return measurements

def load_environment():
    env_file = os.path.join(results_dir, 'environment-summary.txt')
    if os.path.exists(env_file):
        with open(env_file, 'r') as f:
            return f.read()
    return None

def load_chartjs():
    chartjs_file = os.path.join(results_dir, 'chart.min.js')
    if os.path.exists(chartjs_file):
        with open(chartjs_file, 'r') as f:
            return f.read()
    return None

def find_baseline(measurements):
    for m in measurements:
        if 'baseline' in m.get('label', '').lower():
            return m
    return measurements[0] if measurements else None

# ── Analysis Computation ─────────────────────────────────

def safe_float(val, default=0.0):
    try:
        return float(val)
    except (ValueError, TypeError):
        return default

def safe_int(val, default=0):
    try:
        return int(float(val))
    except (ValueError, TypeError):
        return default

def parse_disk_size_gb(raw):
    """Convert Kubernetes size string (e.g. '20Gi') to float GB. Returns None on failure."""
    if not raw or not raw.strip():
        return None
    raw = raw.strip()
    try:
        if raw.endswith('Gi'):
            return float(raw[:-2])
        elif raw.endswith('Ti'):
            return float(raw[:-2]) * 1024
        elif raw.endswith('Mi'):
            return float(raw[:-2]) / 1024
        else:
            return float(raw)
    except (ValueError, TypeError):
        return None

disk_size_gb = parse_disk_size_gb(golden_disk_size_raw)

def compute_analysis(measurements, baseline):
    baseline_stored = safe_float(baseline.get('pool_stored_gb'))

    # Pre-scan: find the post-clone stored value (last clone measurement)
    post_clone_stored = baseline_stored
    for m in measurements:
        if 'clone' in m.get('label', '').lower():
            post_clone_stored = safe_float(m.get('pool_stored_gb'))

    results = []
    for m in measurements:
        stored = safe_float(m.get('pool_stored_gb'))
        used = safe_float(m.get('pool_used_gb'))
        pvc_count = safe_int(m.get('pvc_count'))
        compress_under = safe_float(m.get('compress_under_gb'))
        compress_used = safe_float(m.get('compress_used_gb'))
        compress_saved = safe_float(m.get('compress_saved_gb'))
        csi_clones = safe_int(m.get('csi_clones'))
        copy_clones = safe_int(m.get('copy_clones'))

        # Classify phase (must be before full_clone_cost calculation)
        label_lower = m.get('label', '').lower()
        if 'baseline' in label_lower:
            phase_type = 'baseline'
        elif 'clone' in label_lower:
            phase_type = 'clone'
        elif 'drift' in label_lower:
            phase_type = 'drift'
        else:
            phase_type = 'other'

        delta = stored - baseline_stored
        if phase_type == 'drift':
            drift_total = max(stored - post_clone_stored, 0)
            full_clone_cost = pvc_count * baseline_stored + drift_total
        else:
            full_clone_cost = pvc_count * baseline_stored if pvc_count > 0 else stored
        efficiency = full_clone_cost / stored if stored > 0 and pvc_count > 1 else 0
        savings = full_clone_cost - stored if pvc_count > 1 else 0

        results.append({
            'label': m.get('label', ''),
            'timestamp': m.get('timestamp', ''),
            'stored_gb': stored,
            'used_gb': used,
            'delta_gb': delta,
            'pvc_count': pvc_count,
            'full_clone_cost': full_clone_cost,
            'efficiency': efficiency,
            'savings': savings,
            'compress_under': compress_under,
            'compress_used': compress_used,
            'compress_saved': compress_saved,
            'csi_clones': csi_clones,
            'copy_clones': copy_clones,
            'phase_type': phase_type,
        })
    return results

def parse_env_summary(env_text):
    """Extract key facts from environment-summary.txt via regex."""
    facts = {}
    if not env_text:
        return facts
    patterns = {
        'odf_version': r'ODF Version:\s*(.*)',
        'ceph_version': r'Ceph Version:\s*(.*)',
        'cluster_health': r'Cluster Health:\s*(.*)',
        'osd_count': r'Physical Disks \(OSDs\):\s*(\d+)',
        'raw_capacity': r'Total Raw Capacity:\s*(.*)',
        'usable_capacity': r'Usable Capacity:\s*(.*)',
        'failure_domain': r'Failure Domain:\s*(.*)',
        'replication': r'Replication:\s*(.*)',
        'compression': r'Compression:\s*(.*)',
        'pool_name': r'Storage Pool:\s*(.*)',
        'storage_class': r'StorageClass:\s*(.*)\)',
    }
    for key, pattern in patterns.items():
        match = re.search(pattern, env_text)
        if match:
            facts[key] = match.group(1).strip()
    return facts

# ── HTML Building ────────────────────────────────────────

def esc(text):
    return html.escape(str(text))

def build_css():
    return """
    :root {
      --bg: #f8f9fa; --card-bg: #ffffff; --text: #1a1a2e;
      --text-muted: #6c757d; --border: #dee2e6; --primary: #0d6efd;
      --success: #198754; --warning: #ffc107; --danger: #dc3545;
      --info: #0dcaf0; --accent: #6f42c1;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      background: var(--bg); color: var(--text); line-height: 1.6;
      max-width: 1100px; margin: 0 auto; padding: 20px 30px;
    }
    h1 { font-size: 1.8rem; margin-bottom: 0.3rem; color: var(--text); }
    h2 {
      font-size: 1.35rem; margin: 2rem 0 1rem; padding-bottom: 0.4rem;
      border-bottom: 2px solid var(--primary); color: var(--primary);
    }
    h3 { font-size: 1.1rem; margin: 1.2rem 0 0.6rem; color: var(--text); }
    p, li { margin-bottom: 0.5rem; }
    .subtitle { color: var(--text-muted); font-size: 0.95rem; margin-bottom: 1.5rem; }

    /* Metric cards */
    .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; margin: 1rem 0; }
    .card {
      background: var(--card-bg); border: 1px solid var(--border); border-radius: 10px;
      padding: 18px 20px; text-align: center; box-shadow: 0 1px 3px rgba(0,0,0,0.06);
    }
    .card .value { font-size: 2rem; font-weight: 700; line-height: 1.2; }
    .card .label { font-size: 0.82rem; color: var(--text-muted); margin-top: 4px; text-transform: uppercase; letter-spacing: 0.5px; }
    .card.green .value { color: var(--success); }
    .card.blue .value { color: var(--primary); }
    .card.purple .value { color: var(--accent); }
    .card.orange .value { color: #e67e22; }

    /* Tables */
    table {
      width: 100%; border-collapse: collapse; margin: 1rem 0;
      background: var(--card-bg); border-radius: 8px; overflow: hidden;
      box-shadow: 0 1px 3px rgba(0,0,0,0.06);
    }
    th, td { padding: 10px 14px; text-align: left; border-bottom: 1px solid var(--border); }
    th { background: #f1f3f5; font-weight: 600; font-size: 0.85rem; text-transform: uppercase; letter-spacing: 0.3px; color: var(--text-muted); }
    td { font-size: 0.92rem; }
    tr:last-child td { border-bottom: none; }
    tr.phase-baseline { background: #e8f5e9; }
    tr.phase-clone { background: #e3f2fd; }
    tr.phase-drift { background: #fff3e0; }
    th.num, td.num { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; width: 1%; }

    /* Charts */
    .chart-container { background: var(--card-bg); border: 1px solid var(--border); border-radius: 10px; padding: 20px; margin: 1rem 0; box-shadow: 0 1px 3px rgba(0,0,0,0.06); }
    .chart-container canvas { max-height: 350px; }
    .chart-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
    @media (max-width: 800px) { .chart-grid { grid-template-columns: 1fr; } }
    .no-charts { background: #fff3cd; border: 1px solid #ffc107; border-radius: 8px; padding: 16px; color: #856404; margin: 1rem 0; }

    /* Key findings */
    .findings { background: var(--card-bg); border: 1px solid var(--border); border-radius: 10px; padding: 18px 22px; margin: 1rem 0; box-shadow: 0 1px 3px rgba(0,0,0,0.06); }
    .findings li { margin-bottom: 0.4rem; }

    /* Environment section */
    .env-facts table { margin: 0.5rem 0; }
    details { margin: 1rem 0; }
    summary { cursor: pointer; font-weight: 600; color: var(--primary); padding: 6px 0; }
    pre.env-raw { background: #f1f3f5; padding: 16px; border-radius: 8px; overflow-x: auto; font-size: 0.82rem; line-height: 1.5; white-space: pre-wrap; word-wrap: break-word; max-height: 400px; overflow-y: auto; }

    /* Methodology steps */
    .steps { display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 16px; margin: 1rem 0; }
    .step {
      background: var(--card-bg); border: 1px solid var(--border); border-radius: 10px;
      padding: 18px; box-shadow: 0 1px 3px rgba(0,0,0,0.06);
    }
    .step .step-num { display: inline-block; background: var(--primary); color: white; width: 28px; height: 28px; border-radius: 50%; text-align: center; line-height: 28px; font-weight: 700; font-size: 0.85rem; margin-bottom: 8px; }
    .step h4 { margin-bottom: 6px; }

    /* Glossary */
    dl { margin: 0.5rem 0; }
    dt { font-weight: 700; margin-top: 0.8rem; color: var(--primary); }
    dd { margin-left: 1.2rem; color: var(--text); }

    /* Comparison table */
    .comparison td:first-child { font-weight: 600; white-space: nowrap; }

    /* Print styles */
    @media print {
      body { max-width: 100%; padding: 10px; }
      .chart-grid { grid-template-columns: 1fr 1fr; }
      .card { break-inside: avoid; }
      h2 { break-after: avoid; }
      table { break-inside: avoid; }
    }
    """

def build_executive_summary(analysis, baseline_stored, disk_size_gb=None):
    clone_phases = [a for a in analysis if a['phase_type'] == 'clone']
    drift_phases = [a for a in analysis if a['phase_type'] == 'drift']

    # Determine headline metrics
    if clone_phases:
        peak_clone = clone_phases[-1]
        efficiency_val = f"{peak_clone['efficiency']:.0f}x"
        savings_val = f"{peak_clone['savings']:.1f} GB"
        clone_method = "CSI Clone (CoW)" if peak_clone['csi_clones'] > 0 else "Full Copy"
        clone_method_ok = peak_clone['csi_clones'] > 0 and peak_clone['copy_clones'] == 0
    else:
        efficiency_val = "N/A"
        savings_val = "N/A"
        clone_method = "No clones yet"
        clone_method_ok = False

    # Compression
    last = analysis[-1] if analysis else None
    if last and last['compress_saved'] > 0:
        ratio = (last['compress_saved'] / last['stored_gb'] * 100) if last['stored_gb'] > 0 else 0
        compress_val = f"{ratio:.1f}%"
        compress_label = "Compression Savings"
    else:
        compress_val = "Off"
        compress_label = "Compression"

    eff_label = "Storage Efficiency (at clone time)" if drift_phases else "Storage Efficiency"
    savings_label = "Space Saved (at clone time)" if drift_phases else "Space Saved vs Full Copies"

    cards_html = '<div class="cards">'
    cards_html += f'<div class="card green"><div class="value">{esc(efficiency_val)}</div><div class="label">{esc(eff_label)}</div></div>'
    cards_html += f'<div class="card blue"><div class="value">{esc(savings_val)}</div><div class="label">{esc(savings_label)}</div></div>'
    cards_html += f'<div class="card purple"><div class="value">{esc(clone_method)}</div><div class="label">Clone Method</div></div>'
    cards_html += f'<div class="card orange"><div class="value">{esc(compress_val)}</div><div class="label">{esc(compress_label)}</div></div>'
    cards_html += '</div>'

    # Key findings bullets
    findings = []
    if clone_phases:
        p = clone_phases[-1]
        if disk_size_gb is not None:
            findings.append(f"<strong>{p['pvc_count']} VM disks</strong> ({disk_size_gb:.0f} GB each) were cloned from a <strong>{baseline_stored:.1f} GB</strong> golden image.")
        else:
            findings.append(f"<strong>{p['pvc_count']} VM disks</strong> were cloned from a <strong>{baseline_stored:.1f} GB</strong> golden image.")
        findings.append(f"Cloning added only <strong>{p['delta_gb']:.2f} GB</strong> of additional storage — "
                        f"just <strong>{(p['delta_gb'] / baseline_stored * 100):.1f}%</strong> overhead." if baseline_stored > 0 else "")
        findings.append(f"Without copy-on-write, full copies would have consumed <strong>{p['full_clone_cost']:.0f} GB</strong>. "
                        f"ODF used just <strong>{p['stored_gb']:.1f} GB</strong>.")
        if not clone_method_ok:
            findings.append(f"<span style='color:var(--danger)'>WARNING: {p['copy_clones']} clone(s) used full copy instead of CoW. Results may overstate storage usage.</span>")

    if drift_phases:
        last_drift = drift_phases[-1]
        findings.append(f"At the highest tested drift level ({esc(last_drift['label'])}), efficiency is still "
                        f"<strong>{last_drift['efficiency']:.1f}x</strong> better than full copies.")

    if last and last['compress_saved'] > 0 and last['stored_gb'] > 0:
        compress_pct = last['compress_saved'] / last['stored_gb'] * 100
        findings.append(f"Ceph compression saved an additional <strong>{last['compress_saved']:.1f} GB</strong> "
                        f"(<strong>{compress_pct:.1f}%</strong> of stored data) of physical disk space.")

    if disk_size_gb is not None and clone_phases:
        p = clone_phases[-1]
        provisioned_total = p['pvc_count'] * disk_size_gb
        findings.append(
            f"Thin provisioning saves the most: {p['pvc_count']} VMs with {disk_size_gb:.0f} GB disks "
            f"would provision <strong>{provisioned_total:,.0f} GB</strong>, but only "
            f"<strong>{p['stored_gb']:.0f} GB</strong> is actually stored."
        )

    findings_html = ""
    findings = [f for f in findings if f]
    if findings:
        findings_html = '<div class="findings"><h3>Key Findings</h3><ul>'
        for f in findings:
            findings_html += f'<li>{f}</li>'
        findings_html += '</ul></div>'

    return cards_html + findings_html

def build_environment_section(env_text, facts):
    if not env_text and not facts:
        return '<p>Environment summary not available. Run <code>01-setup.sh</code> to capture it.</p>'

    s = '<div class="env-facts">'
    if facts:
        s += '<table><tbody>'
        display_facts = [
            ('ODF Version', facts.get('odf_version', 'N/A')),
            ('Ceph Version', facts.get('ceph_version', 'N/A')),
            ('Cluster Health', facts.get('cluster_health', 'N/A')),
            ('Physical Disks (OSDs)', facts.get('osd_count', 'N/A')),
            ('Raw Capacity', facts.get('raw_capacity', 'N/A')),
            ('Usable Capacity', facts.get('usable_capacity', 'N/A')),
            ('Failure Domain', facts.get('failure_domain', 'N/A')),
            ('Storage Pool', facts.get('pool_name', 'N/A')),
            ('Replication', facts.get('replication', 'N/A')),
            ('Compression', facts.get('compression', 'N/A')),
        ]
        for label, value in display_facts:
            s += f'<tr><td><strong>{esc(label)}</strong></td><td>{esc(value)}</td></tr>'
        s += '</tbody></table>'

    if env_text:
        s += '<details><summary>Full Environment Details</summary>'
        s += f'<pre class="env-raw">{esc(env_text)}</pre>'
        s += '</details>'

    s += '</div>'
    return s

def build_methodology_section():
    return """
    <p>This test measures how efficiently OpenShift Data Foundation (ODF) stores VM disks
    when cloning at scale, using Ceph's copy-on-write capabilities.</p>
    <div class="steps">
      <div class="step">
        <div class="step-num">1</div>
        <h4>Create Golden Image</h4>
        <p>A single "golden" VM template is created with a full OS installation and ~5 GB of
        test data on a 20 GB virtual disk. This becomes the baseline — the one master copy
        all clones will share.</p>
      </div>
      <div class="step">
        <div class="step-num">2</div>
        <h4>Clone VMs</h4>
        <p>Multiple VMs are cloned from the golden image using Ceph's copy-on-write (CoW)
        mechanism. Each clone initially uses near-zero additional storage because it shares
        the golden image data and only records differences.</p>
      </div>
      <div class="step">
        <div class="step-num">3</div>
        <h4>Simulate Drift</h4>
        <p>Each clone writes new, unique files filled with random (incompressible) data to
        simulate real-world divergence. Drift levels are cumulative and additive — at each
        level, a new file is written alongside previous ones, so storage grows with every
        phase. Measurements are taken at 1%, 5%, 10%, and 25% of disk size.</p>
      </div>
    </div>
    <p><strong>Note on test data:</strong> Both the golden image payload and all drift data are written
    using <code>/dev/urandom</code> (random, incompressible data). This represents a worst case for
    Ceph compression — real VM workloads containing logs, databases, and application data would see
    significantly better compression ratios. The random data isolates copy-on-write efficiency without
    compression masking the results.</p>
    <p>Storage is measured at each stage using Ceph pool-level metrics. The key question:
    <strong>how much less storage does ODF use compared to making full copies of every VM?</strong></p>
    """

def build_measurements_table(analysis):
    s = '<table><thead><tr>'
    s += '<th>Phase</th><th class="num">Data Stored (GB)</th><th class="num">Disk Used (GB)</th>'
    s += '<th class="num">Delta (GB)</th><th class="num">VM Disks</th>'
    s += '<th class="num">Efficiency</th>'
    s += '<th class="num">Compress Saved (GB)</th>'
    s += '</tr></thead><tbody>'

    for a in analysis:
        row_class = f'phase-{a["phase_type"]}'
        eff_str = f'{a["efficiency"]:.1f}x' if a['efficiency'] > 0 else '—'
        delta_str = f'{a["delta_gb"]:+.3f}' if a['phase_type'] != 'baseline' else '—'
        compress_str = f'{a["compress_saved"]:.2f}' if a['compress_saved'] > 0 else '—'

        s += f'<tr class="{row_class}">'
        s += f'<td>{esc(a["label"])}</td>'
        s += f'<td class="num">{a["stored_gb"]:.3f}</td>'
        s += f'<td class="num">{a["used_gb"]:.3f}</td>'
        s += f'<td class="num">{delta_str}</td>'
        s += f'<td class="num">{a["pvc_count"]}</td>'
        s += f'<td class="num">{eff_str}</td>'
        s += f'<td class="num">{compress_str}</td>'
        s += '</tr>'

    s += '</tbody></table>'

    # Color legend
    s += '<p style="font-size:0.82rem;color:var(--text-muted);margin-top:0.3rem;">'
    s += '<span style="display:inline-block;width:12px;height:12px;background:#e8f5e9;border:1px solid #ccc;margin-right:3px;vertical-align:middle;"></span> Baseline '
    s += '<span style="display:inline-block;width:12px;height:12px;background:#e3f2fd;border:1px solid #ccc;margin-right:3px;margin-left:12px;vertical-align:middle;"></span> Clone '
    s += '<span style="display:inline-block;width:12px;height:12px;background:#fff3e0;border:1px solid #ccc;margin-right:3px;margin-left:12px;vertical-align:middle;"></span> Drift'
    s += '</p>'
    return s

def build_charts_section(analysis, has_chartjs):
    if len(analysis) < 2:
        return '<p>Not enough measurements to generate charts. Run clone and drift phases first.</p>'

    labels_json = json.dumps([a['label'] for a in analysis])
    stored_json = json.dumps([round(a['stored_gb'], 3) for a in analysis])
    full_cost_json = json.dumps([round(a['full_clone_cost'], 1) for a in analysis])
    efficiency_json = json.dumps([round(a['efficiency'], 2) for a in analysis])
    savings_json = json.dumps([round(a['savings'], 1) for a in analysis])
    compress_saved_json = json.dumps([round(a['compress_saved'], 2) for a in analysis])

    s = ''
    if not has_chartjs:
        s += '<div class="no-charts">Chart.js was not available when this report was generated. '
        s += 'All data is shown in the tables above. To enable charts, run <code>01-setup.sh</code> '
        s += 'to download Chart.js, then re-run <code>06-generate-report.sh</code>.</div>'
        return s

    s += '<div class="chart-grid">'

    # Chart 1: Actual vs Full Copy Cost
    s += '<div class="chart-container">'
    s += '<h3>Actual Storage vs Full-Copy Cost</h3>'
    s += '<p style="font-size:0.85rem;color:var(--text-muted);">Shows how much storage CoW cloning actually used (green) versus what full copies would require (gray). The gap is your savings.</p>'
    s += '<canvas id="chart-actual-vs-full"></canvas>'
    s += '</div>'

    # Chart 2: Efficiency Over Time
    s += '<div class="chart-container">'
    s += '<h3>Storage Efficiency Over Time</h3>'
    s += '<p style="font-size:0.85rem;color:var(--text-muted);">Efficiency ratio at each phase. Higher means ODF is using proportionally less storage than full copies would.</p>'
    s += '<canvas id="chart-efficiency"></canvas>'
    s += '</div>'

    # Chart 3: Savings Breakdown
    s += '<div class="chart-container">'
    s += '<h3>Storage Savings Breakdown</h3>'
    s += '<p style="font-size:0.85rem;color:var(--text-muted);">At each phase: the green portion is actual storage used, the blue portion is space saved by CoW cloning.</p>'
    s += '<canvas id="chart-savings"></canvas>'
    s += '</div>'

    # Chart 4: Compression Impact
    s += '<div class="chart-container">'
    s += '<h3>Compression Impact</h3>'
    s += '<p style="font-size:0.85rem;color:var(--text-muted);">Total data stored (green) vs space saved by compression (orange). The combined height shows what storage would be without compression.</p>'
    s += '<canvas id="chart-compression"></canvas>'
    s += '</div>'

    s += '</div>'  # end chart-grid

    # Chart.js initialization script
    s += f"""
    <script>
    document.addEventListener('DOMContentLoaded', function() {{
      if (typeof Chart === 'undefined') return;

      var labels = {labels_json};
      var stored = {stored_json};
      var fullCost = {full_cost_json};
      var efficiency = {efficiency_json};
      var savings = {savings_json};
      var compSaved = {compress_saved_json};

      var fontColor = '#1a1a2e';
      var gridColor = '#dee2e6';
      Chart.defaults.color = fontColor;
      Chart.defaults.borderColor = gridColor;

      // Chart 1: Actual vs Full Copy
      new Chart(document.getElementById('chart-actual-vs-full'), {{
        type: 'bar',
        data: {{
          labels: labels,
          datasets: [
            {{ label: 'Actual Storage (GB)', data: stored, backgroundColor: 'rgba(25,135,84,0.7)', borderColor: 'rgba(25,135,84,1)', borderWidth: 1 }},
            {{ label: 'Full-Copy Cost (GB)', data: fullCost, backgroundColor: 'rgba(173,181,189,0.5)', borderColor: 'rgba(173,181,189,1)', borderWidth: 1 }}
          ]
        }},
        options: {{
          responsive: true,
          plugins: {{
            tooltip: {{ callbacks: {{ label: function(c) {{ return c.dataset.label + ': ' + c.parsed.y.toFixed(1) + ' GB'; }} }} }}
          }},
          scales: {{ y: {{ beginAtZero: true, title: {{ display: true, text: 'Storage (GB)' }} }} }}
        }}
      }});

      // Chart 2: Efficiency
      new Chart(document.getElementById('chart-efficiency'), {{
        type: 'line',
        data: {{
          labels: labels,
          datasets: [{{
            label: 'Efficiency Ratio',
            data: efficiency,
            borderColor: 'rgba(13,110,253,1)',
            backgroundColor: 'rgba(13,110,253,0.1)',
            fill: true,
            tension: 0.3,
            pointRadius: 5,
            pointHoverRadius: 8
          }}]
        }},
        options: {{
          responsive: true,
          plugins: {{
            tooltip: {{ callbacks: {{ label: function(c) {{ return c.parsed.y.toFixed(1) + 'x efficiency'; }} }} }}
          }},
          scales: {{ y: {{ beginAtZero: true, title: {{ display: true, text: 'Efficiency (x times)' }} }} }}
        }}
      }});

      // Chart 3: Savings
      new Chart(document.getElementById('chart-savings'), {{
        type: 'bar',
        data: {{
          labels: labels,
          datasets: [
            {{ label: 'Actual Used (GB)', data: stored, backgroundColor: 'rgba(25,135,84,0.7)', borderColor: 'rgba(25,135,84,1)', borderWidth: 1 }},
            {{ label: 'Space Saved (GB)', data: savings, backgroundColor: 'rgba(13,110,253,0.5)', borderColor: 'rgba(13,110,253,1)', borderWidth: 1 }}
          ]
        }},
        options: {{
          responsive: true,
          plugins: {{
            tooltip: {{ callbacks: {{ label: function(c) {{ return c.dataset.label + ': ' + c.parsed.y.toFixed(1) + ' GB'; }} }} }}
          }},
          scales: {{ x: {{ stacked: true }}, y: {{ stacked: true, beginAtZero: true, title: {{ display: true, text: 'Storage (GB)' }} }} }}
        }}
      }});

      // Chart 4: Compression
      new Chart(document.getElementById('chart-compression'), {{
        type: 'bar',
        data: {{
          labels: labels,
          datasets: [
            {{ label: 'Stored Data (GB)', data: stored, backgroundColor: 'rgba(25,135,84,0.7)', borderColor: 'rgba(25,135,84,1)', borderWidth: 1 }},
            {{ label: 'Compression Savings (GB)', data: compSaved, backgroundColor: 'rgba(230,126,34,0.6)', borderColor: 'rgba(230,126,34,1)', borderWidth: 1 }}
          ]
        }},
        options: {{
          responsive: true,
          plugins: {{
            tooltip: {{ callbacks: {{ label: function(c) {{ return c.dataset.label + ': ' + c.parsed.y.toFixed(1) + ' GB'; }} }} }}
          }},
          scales: {{ x: {{ stacked: true }}, y: {{ stacked: true, beginAtZero: true, title: {{ display: true, text: 'Storage (GB)' }} }} }}
        }}
      }});
    }});
    </script>
    """
    return s

def build_analysis_section(analysis, baseline_stored, disk_size_gb=None):
    clone_phases = [a for a in analysis if a['phase_type'] == 'clone']
    drift_phases = [a for a in analysis if a['phase_type'] == 'drift']

    s = ''

    # Thin provisioning context (shown first — largest savings layer)
    if disk_size_gb is not None and clone_phases:
        p = clone_phases[-1]
        provisioned_total = p['pvc_count'] * disk_size_gb
        utilisation_pct = (p['stored_gb'] / provisioned_total * 100) if provisioned_total > 0 else 0
        thin_savings = provisioned_total - p['stored_gb']

        s += '<h3>Thin Provisioning</h3>'
        s += f'<p>Each VM is provisioned with a <strong>{disk_size_gb:.0f} GB</strong> virtual disk, '
        s += f'but only blocks the VM has actually written consume storage. '
        s += f'With <strong>{p["pvc_count"]} VMs</strong>, the total provisioned capacity is '
        s += f'<strong>{provisioned_total:,.0f} GB</strong>, yet only '
        s += f'<strong>{p["stored_gb"]:.1f} GB</strong> is actually stored — '
        s += f'a <strong>{utilisation_pct:.1f}%</strong> utilisation rate.</p>'
        s += f'<p>Thin provisioning alone saves <strong>{thin_savings:,.0f} GB</strong>. '
        s += f'Copy-on-write cloning and Ceph compression provide <em>additional</em> reductions '
        s += f'on top of this.</p>'

    if clone_phases:
        p = clone_phases[-1]
        overhead_pct = (p['delta_gb'] / baseline_stored * 100) if baseline_stored > 0 else 0

        s += '<h3>Clone Overhead</h3>'
        s += f'<p>After cloning <strong>{p["pvc_count"]} VMs</strong> from the golden image, '
        s += f'the storage pool grew by just <strong>{p["delta_gb"]:.2f} GB</strong> — '
        s += f'that\'s only <strong>{overhead_pct:.1f}%</strong> overhead on top of the original '
        s += f'{baseline_stored:.1f} GB golden image.</p>'
        s += f'<p>If every clone were a full, independent copy of the {baseline_stored:.1f} GB disk, '
        s += f'the total would be <strong>{p["full_clone_cost"]:.0f} GB</strong>. Instead, ODF\'s '
        s += f'copy-on-write cloning brought the actual usage to just <strong>{p["stored_gb"]:.1f} GB</strong>, '
        s += f'saving <strong>{p["savings"]:.0f} GB</strong> of storage.</p>'

        if p['csi_clones'] > 0 or p['copy_clones'] > 0:
            s += '<p><strong>Clone method breakdown:</strong> '
            s += f'{p["csi_clones"]} used efficient CoW cloning'
            if p['copy_clones'] > 0:
                s += f', {p["copy_clones"]} used full copy (inefficient)'
            s += '.</p>'

    if drift_phases:
        s += '<h3>Drift Impact</h3>'
        s += '<p>As VMs run, each drift level writes a new file of random data to every clone — previous '
        s += 'files are kept, so storage grows cumulatively. (For example, after the 5% level each clone '
        s += 'holds both a 200 MB file and an 824 MB file.) The table below shows how efficiency '
        s += 'decreases as data accumulates:</p>'
        s += '<table><thead><tr><th>Drift Level</th><th class="num">New Data Added (GB)</th>'
        s += '<th class="num">Total Stored (GB)</th><th class="num">Efficiency</th></tr></thead><tbody>'

        prev_stored = clone_phases[-1]['stored_gb'] if clone_phases else baseline_stored
        for d in drift_phases:
            new_data = d['stored_gb'] - prev_stored
            s += f'<tr><td>{esc(d["label"])}</td>'
            s += f'<td class="num">{new_data:.2f}</td>'
            s += f'<td class="num">{d["stored_gb"]:.2f}</td>'
            s += f'<td class="num">{d["efficiency"]:.1f}x</td></tr>'
            prev_stored = d['stored_gb']
        s += '</tbody></table>'
        s += '<p>Even with significant drift, ODF still uses substantially less storage than full copies would require, '
        s += 'because the majority of each VM\'s data (the OS, base packages, etc.) remains shared with the golden image.</p>'

    # Compression analysis
    last = analysis[-1] if analysis else None
    if last and last['compress_saved'] > 0:
        s += '<h3>Compression Impact</h3>'
        ratio = (last['compress_saved'] / last['stored_gb'] * 100) if last['stored_gb'] > 0 else 0
        s += f'<p>Ceph inline compression saved <strong>{last["compress_saved"]:.1f} GB</strong>, '
        s += f'reducing overall storage by <strong>{ratio:.1f}%</strong> on top of the CoW savings. '
        s += f'(Of the {last["stored_gb"]:.1f} GB stored, {last["compress_under"]:.1f} GB was eligible for '
        s += f'compression and was reduced to {last["compress_used"]:.1f} GB.)</p>'
        s += '<p><em>Note: This test uses random data (<code>/dev/urandom</code>), which is incompressible '
        s += 'by design — a worst-case scenario for compression. Production VMs with real application data '
        s += '(logs, databases, documents) would see substantially higher compression savings.</em></p>'

    if not clone_phases and not drift_phases:
        s += '<p>Only baseline measurements are available. Run clone and drift phases to see efficiency analysis.</p>'

    return s

def build_vmware_comparison(analysis, baseline_stored):
    clone_phases = [a for a in analysis if a['phase_type'] == 'clone']
    drift_phases = [a for a in analysis if a['phase_type'] == 'drift']

    s = '<p>Organizations migrating from VMware often use <strong>linked clones</strong> to save storage. '
    s += 'ODF\'s Ceph RBD copy-on-write cloning provides an equivalent capability. Here\'s how they compare:</p>'

    s += '<table class="comparison"><thead><tr><th>Feature</th><th>VMware Linked Clones</th><th>ODF / Ceph CoW Clones</th></tr></thead><tbody>'
    rows = [
        ('Mechanism', 'VMDK redo logs (delta disks)', 'Ceph RBD layered images (CoW snapshots)'),
        ('Initial clone cost', 'Near-zero (pointer to parent)', 'Near-zero (metadata reference to parent image)'),
        ('Write behavior', 'New writes go to delta disk', 'New writes go to child image; reads fall through to parent'),
        ('Dependency', 'Clone depends on parent snapshot', 'Clone depends on parent image (can be flattened later)'),
        ('Replication', 'VMFS/vSAN handles replication', 'Ceph replicates across OSDs and failure domains'),
        ('Compression', 'Depends on vSAN/datastore config', 'Inline compression at pool level (configurable)'),
        ('Scale', 'Typically per-host or per-datastore', 'Cluster-wide, scales with OSD count'),
    ]
    for feature, vmware, odf in rows:
        s += f'<tr><td>{esc(feature)}</td><td>{esc(vmware)}</td><td>{esc(odf)}</td></tr>'
    s += '</tbody></table>'

    if clone_phases:
        p = clone_phases[-1]
        s += f'<p><strong>Bottom line:</strong> In this test, ODF achieved <strong>{p["efficiency"]:.0f}x</strong> '
        s += f'storage efficiency when cloning {p["pvc_count"]} VMs — comparable to what VMware linked clones provide. '

    if drift_phases:
        last = drift_phases[-1]
        s += f'After maximum drift, efficiency remained at <strong>{last["efficiency"]:.1f}x</strong>. '

    if clone_phases or drift_phases:
        s += 'Both approaches fundamentally work the same way: clones share a common base and only store differences.</p>'

    return s

def build_glossary(disk_size_gb=None):
    terms = [
        ('Copy-on-Write (CoW)', 'A cloning technique where new VMs share the original disk data and only store bytes that change. This is why 100 clones don\'t take 100x the storage — they all point back to the same golden image.'),
        ('Golden Image', 'The original VM template that all clones are based on. It contains the OS, base packages, and test data. Clones reference this image rather than copying it.'),
        ('OSD (Object Storage Device)', 'A storage daemon in Ceph, each typically managing one physical disk. More OSDs = more capacity and performance.'),
        ('Ceph Pool', 'A logical partition of the Ceph cluster where data is stored. Each pool has its own replication and compression settings.'),
        ('Data Stored', 'The amount of actual unique data in the pool, measured before Ceph replicates it. This is the real footprint of your VMs\' data.'),
        ('Disk Used', 'Total physical disk space consumed, including all replicas. For a 2x replicated pool, this is roughly 2x Data Stored.'),
        ('Replication Factor', 'How many copies of each data block Ceph maintains for redundancy. A factor of 2 means every byte exists on 2 different disks. If one disk fails, no data is lost.'),
        ('Efficiency Ratio', 'Full-clone cost divided by actual storage. Full-clone cost is what storage would be if every clone were a complete, independent copy — including any drift data, which would exist regardless of cloning strategy. Higher ratio = more savings from CoW.'),
        ('PVC (Persistent Volume Claim)', 'A Kubernetes request for storage. Each VM gets one PVC, which maps to one Ceph RBD image (virtual disk).'),
        ('RBD (RADOS Block Device)', 'Ceph\'s block storage system. Each VM disk is an RBD image — a virtual block device backed by the distributed Ceph cluster.'),
        ('CSI Clone', 'A clone created through the Container Storage Interface using Ceph\'s native CoW. This is the efficient method that shows as "csi-clone" in annotations.'),
        ('Drift', 'New files written to a clone after it was created to simulate real-world divergence. Each drift level adds a separate file of random data — previous levels are kept, so storage grows cumulatively. More drift = more storage consumed.'),
        ('Inline Compression', 'Ceph can compress data before writing it to disk. "Aggressive" mode compresses everything; "passive" only compresses data with a hint. Saves physical disk space.'),
        ('Thin Provisioning', 'A storage technique where a virtual disk (e.g. 20 GB) only consumes space for blocks the VM has actually written. Unwritten regions cost zero storage. This is the default for Ceph RBD images and is the largest source of storage savings when VMs use only a fraction of their provisioned capacity.'),
        ('Failure Domain', 'The boundary within which Ceph places replicas. If the failure domain is "rack", each replica goes to a different rack, so losing an entire rack doesn\'t cause data loss.'),
        ('DataVolume', 'A CDI (Containerized Data Importer) resource that creates and populates a PVC. Used to import the golden image and create clones.'),
    ]
    s = '<dl>'
    for term, definition in terms:
        s += f'<dt>{esc(term)}</dt><dd>{esc(definition)}</dd>'
    s += '</dl>'
    return s

def build_html(analysis, baseline_stored, env_text, facts, chartjs_code, disk_size_gb=None):
    has_chartjs = chartjs_code is not None
    generated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

    parts = []
    parts.append('<!DOCTYPE html>')
    parts.append('<html lang="en">')
    parts.append('<head>')
    parts.append('<meta charset="UTF-8">')
    parts.append('<meta name="viewport" content="width=device-width, initial-scale=1.0">')
    parts.append('<title>ODF Storage Efficiency Report</title>')
    parts.append(f'<style>{build_css()}</style>')
    if has_chartjs:
        parts.append(f'<script>{chartjs_code}</script>')
    parts.append('</head>')
    parts.append('<body>')

    # Header
    parts.append('<h1>ODF Storage Efficiency Report</h1>')
    parts.append(f'<p class="subtitle">Generated {esc(generated)}</p>')

    # Executive Summary
    parts.append('<h2>Executive Summary</h2>')
    parts.append(build_executive_summary(analysis, baseline_stored, disk_size_gb=disk_size_gb))

    # Storage Environment
    parts.append('<h2>Storage Environment</h2>')
    parts.append(build_environment_section(env_text, facts))

    # Test Methodology
    parts.append('<h2>Test Methodology</h2>')
    parts.append(build_methodology_section())

    # Measurements Table
    parts.append('<h2>Measurements</h2>')
    parts.append('<p>Each row represents a measurement taken at a specific point in the test. '
                 '"Data Stored" is the actual unique data; "Disk Used" includes replication overhead.</p>')
    parts.append(build_measurements_table(analysis))

    # Charts
    parts.append('<h2>Charts</h2>')
    parts.append(build_charts_section(analysis, has_chartjs))

    # Analysis
    parts.append('<h2>Analysis</h2>')
    parts.append(build_analysis_section(analysis, baseline_stored, disk_size_gb=disk_size_gb))

    # VMware Comparison
    parts.append('<h2>VMware Comparison</h2>')
    parts.append(build_vmware_comparison(analysis, baseline_stored))

    # Glossary
    parts.append('<h2>Glossary</h2>')
    parts.append('<p>Plain-language definitions of storage terms used in this report.</p>')
    parts.append(build_glossary(disk_size_gb=disk_size_gb))

    # Footer
    parts.append(f'<hr style="margin-top:2rem;border:none;border-top:1px solid var(--border);">')
    parts.append(f'<p style="font-size:0.8rem;color:var(--text-muted);text-align:center;margin-top:1rem;">')
    parts.append(f'Generated by ODF Storage Efficiency Test Harness &middot; {esc(generated)}')
    parts.append(f'</p>')

    parts.append('</body>')
    parts.append('</html>')
    return '\n'.join(parts)

# ── Main ─────────────────────────────────────────────────

def main():
    measurements = load_measurements()
    if not measurements:
        print("No measurements found in summary.csv")
        sys.exit(1)

    baseline = find_baseline(measurements)
    if not baseline:
        print("No baseline measurement found")
        sys.exit(1)

    baseline_stored = safe_float(baseline.get('pool_stored_gb'))
    env_text = load_environment()
    facts = parse_env_summary(env_text)
    chartjs_code = load_chartjs()

    analysis = compute_analysis(measurements, baseline)
    report_html = build_html(analysis, baseline_stored, env_text, facts, chartjs_code, disk_size_gb=disk_size_gb)

    with open(report_file, 'w') as f:
        f.write(report_html)

    print(f"Report generated: {report_file}")
    print(f"  Sections: Executive Summary, Environment, Methodology, Measurements, Charts, Analysis, VMware Comparison, Glossary")
    if chartjs_code:
        print(f"  Charts: 4 interactive charts (Chart.js embedded)")
    else:
        print(f"  Charts: Skipped (chart.min.js not found — run 01-setup.sh to download)")
    print(f"  Open in any browser or print to PDF")

main()
PYEOF

echo ""
echo "Done. Report saved to:"
echo "  $REPORT_FILE"
echo ""

# Open in default browser (works on macOS and Linux)
if command -v open &>/dev/null; then
    open "$REPORT_FILE"
elif command -v xdg-open &>/dev/null; then
    xdg-open "$REPORT_FILE"
else
    echo "Open it in a browser, or print to PDF from the browser."
fi
