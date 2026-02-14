# ODF Storage Concepts for vSAN Administrators

## Introduction

If you manage VMware vSAN, you think in terms of disk groups, storage policies, FTT/FTM settings, and fault domains. OpenShift Data Foundation (ODF) — Red Hat's software-defined storage built on Ceph — solves the same problems with different primitives. The concepts map more closely than you might expect, but the boundaries between them sit in different places.

This document maps vSAN concepts to their ODF equivalents so you can reason about capacity planning, data protection, and performance without starting from scratch. It complements the [clone mechanics comparison](clone-comparison.md), which covers how VM disk cloning works across platforms.

## The Big Picture: vSAN vs ODF Architecture

Both systems aggregate local disks across multiple hosts into a single shared storage pool, distribute data for protection, and let administrators choose how data is stored via policies. The layers stack differently:

| Layer | vSAN | ODF / Ceph |
|---|---|---|
| **Management plane** | vCenter Server | OpenShift (via ODF operator) |
| **Cluster** | vSAN Cluster (enabled per vSphere cluster) | StorageCluster CR (deployed by the ODF operator) |
| **Physical storage** | Disk groups (cache tier + capacity tier) | OSDs (one daemon per physical disk, no separate cache tier) |
| **Logical partitioning** | — (single datastore per cluster) | Ceph Pools (each pool has its own protection and compression settings) |
| **Policy / class** | VM Storage Policy (per-VM or per-VMDK) | StorageClass (points to a specific Ceph pool) |
| **Volume** | VMDK on the vSAN datastore | PVC backed by an RBD image in a Ceph pool |

**Key difference:** In vSAN, the storage policy is assigned per-VM or per-VMDK — you can give one VM RAID-1 and another RAID-5 on the same datastore. In ODF, the protection and compression settings are configured per-pool. All PVCs in a given pool share those settings. To offer different protection levels, you create separate pools with separate StorageClasses.

## StorageCluster

The **StorageCluster** is the top-level ODF custom resource. Creating one is the ODF equivalent of enabling vSAN on a vSphere cluster. It declares:

- Which nodes contribute storage (by label selector)
- How many OSDs to create per node (typically one per physical disk)
- Device classes and device filters
- Whether to enable encryption, compression, or other cluster-wide features

In vSAN terms: "Enable vSAN on this cluster, using these hosts and their local disks."

```
vSAN:  vSphere Cluster → Enable vSAN → Select hosts
ODF:   OpenShift Cluster → Deploy ODF operator → Create StorageCluster CR
```

## OSDs and Device Classes

An **OSD (Object Storage Daemon)** is a Ceph process that manages a single physical disk. Every disk contributed to the ODF cluster gets its own OSD. This is the closest equivalent to a single capacity disk in a vSAN disk group.

**Device classes** (SSD, HDD, NVMe) tag each OSD by media type. Ceph pools can be restricted to a specific device class, letting you direct workloads to the appropriate storage tier. In vSAN, you achieve something similar by creating multiple storage policies that target different tiers.

**No separate cache tier:** vSAN disk groups have a dedicated cache disk (SSD) in front of the capacity disks. Ceph's BlueStore storage engine does not use a separate cache disk. Instead, each OSD uses a small partition on the same device (or optionally a separate fast device) for its write-ahead log (WAL) and metadata database (DB). The performance profile is different — there is no read cache equivalent to vSAN's 70% read / 30% write cache split.

## StoragePools (Ceph Pools)

A **Ceph pool** is a logical partition of the cluster. Each pool has its own:

- Replication or erasure coding profile (data protection)
- Compression setting (on or off, aggressive or passive)
- Placement group count (internal sharding — see below)
- CRUSH rule (failure domain — host, rack, zone)

This is where ODF differs most from vSAN. A vSAN storage policy specifies FTT, FTM (RAID-1/5/6), dedup, and compression — and you assign that policy per-VM or per-VMDK. In ODF, these settings belong to the **pool**, not the individual volume. All PVCs backed by a given pool share the same protection and compression behavior.

The test harness in this repository uses pool `nrt-2` (configured in `00-config.sh`).

**vSAN parallel:** A Ceph pool is like a vSAN storage policy that is permanently "applied" to a section of the datastore. You pick which section to use by choosing the matching StorageClass.

### Example: Replicated Pool (2 replicas)

This is the type of pool used by the test harness — a replicated RBD block pool suitable for VM disks:

```yaml
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: nrt-2                          # Pool name referenced by the StorageClass
  namespace: openshift-storage
spec:
  failureDomain: host                  # Spread replicas across hosts (like vSAN fault domains)
  replicated:
    size: 2                            # 2 replicas = FTT=1 with RAID-1 mirroring
    requireSafeReplicaSize: true       # Prevent setting size=1 accidentally
  parameters:
    compression_mode: aggressive       # Inline compression on all writes
```

### Example: Erasure Coded Pool (2+1)

An EC pool for bulk or archive data where space efficiency matters more than random I/O performance:

```yaml
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: nrt-2-ec                       # Separate pool for EC-backed volumes
  namespace: openshift-storage
spec:
  failureDomain: host
  erasureCoded:
    dataChunks: 2                      # k=2 data chunks
    codingChunks: 1                    # m=1 coding chunk (like RAID-5 / FTT=1)
  parameters:
    compression_mode: aggressive
```

### Example: 3-Replica Pool (Maximum Resilience)

For production VM disks where tolerating two simultaneous failures is required:

```yaml
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: nrt-2-rep3
  namespace: openshift-storage
spec:
  failureDomain: host
  replicated:
    size: 3                            # 3 replicas = FTT=2 with RAID-1 mirroring
  parameters:
    compression_mode: aggressive
```

After creating a pool, verify it is healthy:

```bash
oc exec -n openshift-storage $(oc get pod -n openshift-storage -l app=rook-ceph-tools -o name) -- ceph osd pool ls detail | grep nrt-2
```

## StorageClasses

A **StorageClass** is a Kubernetes resource that tells the CSI provisioner which Ceph pool to use when creating a new volume. It includes parameters like pool name, filesystem type, and whether to enable encryption.

When a user creates a PVC and specifies a StorageClass, they are effectively choosing a storage policy — selecting the protection level, compression setting, and device class that the backing pool provides.

**vSAN parallel:** Selecting a StorageClass is like applying a VM Storage Policy to a VMDK.

A typical ODF deployment has several StorageClasses out of the box:

| StorageClass | Backing | Use Case |
|---|---|---|
| `ocs-storagecluster-ceph-rbd` | Default replicated RBD pool | Block storage for VMs, databases |
| `ocs-storagecluster-cephfs` | CephFS filesystem pool | Shared file storage (ReadWriteMany) |
| `ocs-storagecluster-ceph-rgw` | RADOS Gateway | S3-compatible object storage |
| Custom (e.g., `odf-rbd-ec-2-1`) | EC pool you create | Space-efficient bulk/archive storage |

You can create additional pools and StorageClasses to offer different protection levels. The test harness uses the StorageClass `nrt-2-rbd` (configured in `00-config.sh`).

### Example: StorageClass for a Replicated Pool

This is the StorageClass the test harness uses. It points to the `nrt-2` replicated pool and enables CSI-level cloning (required for CoW clone efficiency):

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nrt-2-rbd                            # Name referenced in 00-config.sh
provisioner: openshift-storage.rbd.csi.ceph.com
parameters:
  clusterID: openshift-storage                # ODF namespace
  pool: nrt-2                                 # Must match the CephBlockPool name
  imageFormat: "2"                            # RBD image format (2 = layering support for CoW)
  imageFeatures: layering,exclusive-lock      # layering is required for CSI cloning
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: openshift-storage
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: openshift-storage
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: openshift-storage
  csi.storage.k8s.io/fstype: ext4
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
```

Key parameters explained:

- **`pool`** ties this StorageClass to a specific CephBlockPool. Changing the pool name is how you direct PVCs to a different protection level.
- **`imageFeatures: layering`** enables RBD layering, which is what makes CoW clones possible. Without this, CDI falls back to host-assisted full copies.
- **`volumeBindingMode: Immediate`** creates the backing RBD image as soon as the PVC is created (rather than waiting for a pod to consume it). This is required for CDI cloning workflows.

### Example: StorageClass for an EC Pool

If you created the `nrt-2-ec` erasure coded pool from the earlier example, you would pair it with a StorageClass like this:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nrt-2-ec-rbd
provisioner: openshift-storage.rbd.csi.ceph.com
parameters:
  clusterID: openshift-storage
  pool: nrt-2-ec                              # Points to the EC pool
  imageFormat: "2"
  imageFeatures: layering,exclusive-lock
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: openshift-storage
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: openshift-storage
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: openshift-storage
  csi.storage.k8s.io/fstype: ext4
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
```

The YAML is nearly identical — only the `pool` parameter changes. This is the ODF equivalent of creating a second vSAN storage policy with different FTT/FTM settings.

### Using a Custom StorageClass with the Test Harness

To run the test harness against a different pool, update two variables in `00-config.sh`:

```bash
export STORAGE_CLASS="nrt-2-rbd"    # StorageClass name from the examples above
export CEPH_POOL="nrt-2"            # Matching CephBlockPool name
```

Both must refer to the same backing pool. The harness uses `STORAGE_CLASS` when creating PVCs and `CEPH_POOL` when querying Ceph directly for storage metrics.

## Data Protection: Replicas vs Erasure Coding

vSAN administrators choose data protection through the FTT (Failures To Tolerate) and FTM (Failure Tolerance Method) policy settings. ODF provides the same spectrum of choices, but the terminology and configuration mechanism differ.

### Replication (vSAN RAID-1 / FTT with Mirroring)

Ceph replication writes complete copies of every object to multiple OSDs on different failure domains.

| Replicas | Failure Tolerance | Raw Overhead | vSAN Equivalent | Notes |
|---|---|---|---|---|
| **1** | None | 1x | — | No redundancy. A single disk failure means data loss. Only appropriate for scratch or ephemeral data. |
| **2** | 1 OSD or node failure | 2x | FTT=1 with RAID-1 | Common default in ODF. Tolerates one failure; the cluster can reconstruct data from the surviving copy during rebuild. |
| **3** | 2 simultaneous failures | 3x | FTT=2 with RAID-1 | Higher durability at higher cost. Required when the cluster must survive overlapping failures (a second failure occurring before the first rebuild completes). |

The test harness cluster uses 2 replicas (reported in the `01-setup.sh` environment summary).

### Erasure Coding (vSAN RAID-5 / RAID-6)

Erasure coding (EC) splits each object into **k data chunks** and **m coding (parity) chunks**, spread across k+m OSDs. Any m chunks can be lost without data loss.

| EC Profile | Chunks | Failure Tolerance | Raw Overhead | vSAN Equivalent |
|---|---|---|---|---|
| **2+1** | 2 data + 1 coding | 1 failure | 1.5x | FTT=1, RAID-5 (conceptually; vSAN uses 3+1) |
| **4+2** | 4 data + 2 coding | 2 failures | 1.5x | FTT=2, RAID-6 (conceptually; vSAN uses 4+2) |
| **2+2** | 2 data + 2 coding | 2 failures | 2x | — (no direct vSAN equivalent) |

**Trade-offs vs replication:**

- EC is more space-efficient for the same failure tolerance (1.5x vs 2x for tolerating one failure).
- EC has higher CPU overhead — every write requires computing parity, and every degraded read requires reconstruction.
- EC has worse small-random-I/O latency because each I/O touches multiple OSDs.
- EC works well for large sequential workloads (backups, media, logs) but is generally a poor fit for primary VM disks.

**Configuration difference:** In vSAN, you select RAID-5 or RAID-6 per-VM via a storage policy. In ODF, erasure coding is configured per-pool. You create an EC pool, create a StorageClass that points to it, and then use that StorageClass for workloads that benefit from the space efficiency.

### Quick Mapping: vSAN Policies to ODF Pools

| vSAN Policy | ODF Equivalent | Raw Overhead | Failure Tolerance |
|---|---|---|---|
| FTT=1, RAID-1 (mirroring) | 2-replica pool | 2x | 1 failure |
| FTT=2, RAID-1 (mirroring) | 3-replica pool | 3x | 2 failures |
| FTT=1, RAID-5 | EC 2+1 pool | 1.5x | 1 failure |
| FTT=2, RAID-6 | EC 4+2 pool | 1.5x | 2 failures |

## Placement Groups and CRUSH

### Placement Groups

**Placement groups (PGs)** are Ceph's internal mechanism for distributing data across OSDs. Every object stored in a pool is assigned to a PG (via a hash of the object name), and the PG is then mapped to a set of OSDs by the CRUSH algorithm.

There is no direct vSAN equivalent — vSAN distributes components across hosts using its own internal algorithms without exposing an intermediate grouping concept.

What you need to know:

- More PGs means finer distribution across OSDs, but each PG consumes memory on the OSDs it maps to.
- ODF auto-tunes PG counts in most deployments (via the Ceph `pg_autoscaler`). You rarely need to set them manually.
- If a pool has too few PGs, data can be unevenly distributed. If it has too many, OSD memory consumption increases.

### CRUSH Rules

**CRUSH (Controlled Replication Under Scalable Hashing)** is the algorithm Ceph uses to determine which OSDs store each PG. CRUSH rules define the **failure domain** — the level of the infrastructure hierarchy across which replicas (or EC chunks) must be spread.

| CRUSH Failure Domain | Meaning | vSAN Equivalent |
|---|---|---|
| `host` | Replicas on different nodes | Default vSAN behavior (components on different hosts) |
| `rack` | Replicas in different racks | vSAN fault domains (one domain per rack) |
| `zone` | Replicas in different availability zones | vSAN stretched cluster (2 sites + witness) |

The test harness reports the cluster's failure domain and CRUSH rule in the environment summary generated by `01-setup.sh`.

## RADOS Objects

Underneath every RBD image (VM disk), Ceph breaks the data into fixed-size **RADOS objects** — 4 MB by default. Each RADOS object is independently:

- Placed on a set of OSDs via CRUSH
- Replicated (or erasure-coded) according to the pool's protection settings
- Eligible for CoW cloning (only modified objects consume space in a clone)

This is conceptually similar to how vSAN breaks VMDKs into **components** (up to 255 GB each, further divided into 1 MB witness and data blocks) distributed across hosts. The idea is the same — decompose a large virtual disk into smaller pieces that can be independently placed and protected — but the granularity differs.

The 4 MB RADOS object size is what makes Ceph's CoW cloning efficient: when a clone VM writes to one part of a 20 GB disk, only the affected 4 MB objects are duplicated, not the entire disk. This is the foundation of the storage efficiency measured by the test harness in this repository.

## Recommendations

### VM Disk Storage (RBD)

- **Use 2 or 3 replicas for production VM disks.** 3 replicas provide the highest resilience (tolerates 2 failures); 2 replicas offer a good balance if capacity is constrained and you can tolerate a brief vulnerability window during single-failure rebuild.
- **Avoid erasure coding for primary VM disks.** The small-random-I/O penalty from EC parity calculation degrades interactive VM performance. Reserve EC for bulk data, backups, and media storage where sequential I/O dominates.

### StorageClass Strategy

- **Create separate StorageClasses for different workload profiles.** For example: `odf-rbd-replicated-3` for production VMs, `odf-rbd-replicated-2` for dev/test, `odf-rbd-ec-2-1` for archive volumes. This mirrors the vSAN practice of defining multiple storage policies.
- **Name StorageClasses descriptively.** Include the protection level in the name so users can make informed choices without inspecting pool configuration.

### Failure Domains

- **Ensure CRUSH rules spread replicas across hosts** (at minimum). In larger deployments with multiple racks, use rack-level failure domains. This is equivalent to configuring vSAN fault domains.
- **Match CRUSH failure domains to your physical topology.** If all nodes are in one rack, host-level domains are your maximum. Do not configure rack-level domains unless you actually have multiple racks with independent power and networking.

### Compression

- **Enable inline compression.** ODF supports BlueStore compression (aggressive or passive mode). The CPU cost on modern hardware is minimal, and the capacity savings are significant — especially for VM images that contain large amounts of empty space or compressible data (OS binaries, logs, text files).
- **Use aggressive mode** for general-purpose workloads. It compresses all data regardless of heuristics. Passive mode only compresses data that Ceph's heuristics suggest will compress well, which can miss opportunities.

## Concept Mapping Reference

| vSAN Term | ODF / Ceph Term | Notes |
|---|---|---|
| vSAN Cluster | StorageCluster CR | Top-level resource that defines the storage cluster |
| Disk group | — | No direct equivalent; ODF uses one OSD per disk with no cache tier grouping |
| Cache disk (SSD in disk group) | BlueStore WAL/DB | Small metadata partition, not a full read/write cache tier |
| Capacity disk | OSD | One OSD daemon per physical disk |
| vSAN Datastore | Ceph Pool | Logical grouping with its own protection and compression settings |
| VM Storage Policy | StorageClass | Selects pool, provisioner, and parameters for new volumes |
| FTT (Failures To Tolerate) | Replica count or EC m value | Number of simultaneous failures the data can survive |
| FTM: RAID-1 (mirroring) | Replication (2 or 3 replicas) | Full copies of data on separate failure domains |
| FTM: RAID-5/6 | Erasure coding (k+m) | Parity-based protection, more space-efficient but higher CPU cost |
| Fault domain | CRUSH failure domain | Level of hierarchy across which data is spread (host, rack, zone) |
| Component | RADOS object | Unit of data distribution; 1 MB in vSAN, 4 MB in Ceph by default |
| VMDK | RBD image | Virtual disk stored in a Ceph pool, visible as a block device to the VM |
| Linked clone (delta disk) | RBD CoW child image | Space-efficient clone; only modified blocks consume storage |
| Object (vSAN internal) | RADOS object | Smallest unit of placement, replication, and recovery |
| Deduplication | — | Ceph does not offer inline dedup; rely on CoW cloning and compression instead |
| Encryption (vSAN data-at-rest) | ODF cluster-wide or per-pool encryption | Both support AES-256; ODF encryption is managed via the StorageCluster CR |
| vSAN Health / Performance | Ceph Dashboard / `ceph status` | Monitoring and diagnostics for the storage cluster |
