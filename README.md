# ODF Storage Efficiency Test

Benchmark how OpenShift Data Foundation (ODF / Ceph RBD) handles VM disk cloning at scale and compare the storage efficiency against VMware linked clones. The harness creates a golden VM image, clones it to hundreds or thousands of VMs, simulates real-world workload drift, and reports actual-vs-theoretical storage consumption at every stage.

## How It Works

ODF with Ceph RBD supports **copy-on-write (CoW) clones** at the block-storage layer via CDI CSI-level cloning. When a DataVolume is cloned from an existing PVC, Ceph creates an RBD snapshot and a CoW child image rather than copying every block. This means:

- **Clone creation is near-instant** regardless of disk size.
- **Storage cost is zero** until the clone writes unique data.
- **Drift is additive** -- each drift level writes new files (random data) to every clone; previous drift data is kept, so storage grows cumulatively.

This test harness quantifies that efficiency by measuring Ceph pool usage, per-image `rbd du`, and PVC-to-RBD mappings at each phase of a clone lifecycle.

## Background

Not all storage platforms implement clones the same way. Some deliver true copy-on-write efficiency; others create full copies behind the scenes. For a detailed comparison of how VMware linked clones, ODF/Ceph RBD CoW clones, and IBM Cloud storage each approach the problem, see [Linked Clones Across Platforms](docs/clone-comparison.md).

To see what this looks like in practice — how data fans out across nodes, OSDs, and placement groups — see [Understanding Storage Distribution](docs/storage-distribution.md).

If you are coming from a VMware vSAN background and want to understand how ODF organizes storage — StorageClusters, pools, StorageClasses, replicas vs erasure coding, and how these map to vSAN concepts like disk groups, storage policies, and FTT/FTM — see [ODF Storage Concepts for vSAN Administrators](docs/odf-storage-concepts.md).

For a detailed look at how Ceph inline compression affects storage in this test — including why only 4% of data was compressible and what that means for real workloads — see [Compression Analysis](docs/compression-analysis.md).

## Prerequisites

| Requirement | Notes |
|---|---|
| `oc` CLI | Authenticated to the target OpenShift cluster |
| ODF operator | With a Ceph RBD-backed StorageClass |
| OpenShift Virtualization (CNV) | `kubevirt.io/v1` API available |
| CDI (Containerized Data Importer) | Included with CNV |
| Ceph toolbox pod | Running in `openshift-storage` namespace |
| `python3` | For report generation |
| `bc` | For shell arithmetic |

## Quick Start

```bash
# 1. Clone the repo
git clone https://github.com/neil1taylor/odf-storage-efficiency-test.git
cd odf-storage-efficiency-test

# 2. Edit configuration to match your cluster
vi 00-config.sh   # StorageClass, Ceph pool, image URL, clone count, etc.

# 3. Run the scripts in order
./01-setup.sh
./02-create-golden-image.sh
./04-clone-vms.sh
./05-simulate-drift.sh
./06-generate-report.sh

# 4. Review results
ls results/
cat results/storage_efficiency_report.txt

# 5. Clean up when done
./07-cleanup.sh
```

## Script Reference

| Script | Purpose | Usage |
|---|---|---|
| `00-config.sh` | Central configuration sourced by all scripts | Edit before first run |
| `01-setup.sh` | Verify prerequisites, deploy Ceph toolbox, print environment summary | `./01-setup.sh` |
| `02-create-golden-image.sh` | Create golden VM template with ~5 GB of test data | `./02-create-golden-image.sh` |
| `03-measure-storage.sh` | Capture Ceph/K8s storage metrics at a point in time | `./03-measure-storage.sh <label>` |
| `04-clone-vms.sh` | Clone the golden image to N VMs in batches | `./04-clone-vms.sh [count] [batch]` (default 100, batches of 20) |
| `05-simulate-drift.sh` | Boot clones and write unique data at each drift level | `./05-simulate-drift.sh [mb]` |
| `06-generate-report.sh` | Generate a storage efficiency report from collected data | `./06-generate-report.sh` |
| `07-cleanup.sh` | Delete all test resources (interactive confirmation) | `./07-cleanup.sh` |

Scripts `02`, `04`, and `05` automatically call `03-measure-storage.sh` at the appropriate measurement points. You can also invoke `03` independently with a descriptive label.

## Configuration

All tunables live in `00-config.sh`. Key settings:

| Variable | Default | Description |
|---|---|---|
| `TEST_NS` | `vm-storage-test` | Kubernetes namespace for all test resources |
| `STORAGE_CLASS` | `nrt-2-rbd` | ODF RBD StorageClass name |
| `CEPH_POOL` | `nrt-2` | Ceph pool backing the StorageClass |
| `CLONE_COUNT` | `100` | Number of VMs to clone |
| `CLONE_BATCH_SIZE` | `20` | Clones created per batch (avoids API pressure) |
| `DRIFT_LEVELS_MB` | `200 1024 2048 5120` | Cumulative MB of unique data written per drift level (1%, 5%, 10%, 25% of 20 GB) |
| `GOLDEN_DISK_SIZE` | `20Gi` | Size of the golden image disk |
| `SOURCE_IMAGE_URL` | Fedora Cloud 43 qcow2 | Base OS image URL |

## Output

All measurement data is written to the `results/` directory:

- `*_ceph-df.json` -- Pool-level Ceph usage at each measurement point
- `*_rbd-du.json` -- Per-RBD-image disk usage
- `*_pvc-map.csv` -- PVC-to-RBD-image mapping
- `*_clone-info.txt` -- Clone parent relationships
- `summary.csv` -- Aggregated metrics across all measurement points
- `storage_efficiency_report.txt` -- Final human-readable report

For an example of the generated report, see the [Example Report](docs/example_report.html).

## Validating Clone Type

For valid results, CDI must use **CSI-level clones** (not host-assisted copies). After cloning, verify:

```bash
oc get dv -n vm-storage-test -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.cdi\.kubevirt\.io/cloneType}{"\n"}{end}'
```

Every clone should show `csi-clone`. If any show `copy`, the StorageClass may not support CSI cloning and the efficiency results will not reflect CoW behavior.

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.
