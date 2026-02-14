# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a **test harness** for benchmarking OpenShift Data Foundation (ODF/Ceph RBD) storage efficiency when cloning VMs at scale, comparing against VMware linked clones. It consists of numbered shell scripts (`00`-`07`) that run sequentially on an OpenShift cluster.

## Script Execution Order

Scripts must be run in order from an environment with `oc` CLI authenticated to an OpenShift cluster:

```
./01-setup.sh                      # Phase 0: Prerequisites, Ceph toolbox & environment summary
./02-create-golden-image.sh        # Phase 1: Create golden VM template with ~5GB test data
./03-measure-storage.sh <label>    # Measurement: capture Ceph/K8s storage metrics
./04-clone-vms.sh [count] [batch]  # Phase 2: Clone VMs (default 100, batches of 20)
./05-simulate-drift.sh [mb]       # Phase 3: Boot clones, write unique data per drift level
./06-generate-report.sh           # Analysis: generate storage efficiency report
./07-cleanup.sh                    # Teardown: delete all test resources (interactive confirmation)
```

Scripts `02`, `04`, and `05` automatically call `03-measure-storage.sh` at key points. You can also invoke it independently with a descriptive label.

## Architecture

- **`00-config.sh`** - Central configuration sourced by all scripts. All tunables live here: namespace (`vm-storage-test`), StorageClass, image URL, clone count/batch size, drift levels, Ceph pool, and results directory. Never hard-code values that belong in config.
- **`03-measure-storage.sh`** - The core measurement engine, invoked by other scripts at measurement points. Captures five data categories: pool-level `ceph df`, per-image `rbd du`, PVC-to-RBD mapping, clone parent relationships, and CDI clone type annotations. Appends to `results/summary.csv`.
- **`06-generate-report.sh`** - Writes a Python script to `results/_report_gen.py` and executes it. The Python code reads `summary.csv` and calculates efficiency ratios (actual storage vs. full-clone cost). Note: the inline heredoc Python (lines 23-145) is dead code due to a `RESULTS_DIR_PLACEHOLDER` that can't be substituted via `sed` on stdin; the actual report runs from the temp file written at line 152.
- **Results** - All output goes to `./results/`: per-measurement JSON (`*_ceph-df.json`, `*_rbd-du.json`), CSV mappings (`*_pvc-map.csv`), clone info text files, and the aggregated `summary.csv`.

## Key Dependencies

- `oc` CLI (OpenShift) - all cluster operations
- ODF operator with Ceph RBD StorageClass
- OpenShift Virtualization (CNV) operator with `kubevirt.io/v1` API
- CDI (Containerized Data Importer) for DataVolume cloning
- Ceph toolbox pod in `openshift-storage` namespace
- `python3` and `bc` for report generation and arithmetic

## Important Patterns

- All scripts use `set -euo pipefail` and `source 00-config.sh`
- Cloning uses CDI DataVolume `source.pvc` which triggers CSI-level RBD CoW clones (not host-assisted copies). If `cdi.kubevirt.io/cloneType` annotation shows `copy` instead of `csi-clone`, the test results are invalid.
- VMs are created with `running: false` during cloning (Phase 2) to measure pure clone overhead without boot writes.
- Drift simulation (Phase 3) writes incremental unique data at cumulative levels defined in `DRIFT_LEVELS_MB` (default: 200, 1024, 2048, 5120 MB = 1%, 5%, 10%, 25% of 20GB disk).
- Batch operations use `CLONE_BATCH_SIZE` (default 20) with background processes and `wait` to avoid API pressure.
- The cleanup script (`07`) requires interactive `yes` confirmation and preserves the `results/` directory.
- All test data (golden image payload and drift writes) uses `/dev/urandom` — random, incompressible data. This is intentional: it creates a worst-case scenario for compression so the test isolates CoW cloning efficiency. Real workloads would see much better compression.
