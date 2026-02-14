# Understanding Storage Distribution

## Introduction

When you create a VM on OpenShift Virtualization with ODF, the experience is simple: you define a DataVolume, the VM boots, and the disk "just works." But between "I created a VM" and "where does the data actually live?" there is an invisible layer of distributed storage doing something fundamentally different from what traditional VM platforms do.

On VMware, a VM's disk is a VMDK file sitting on a single datastore, hosted by a specific storage array or disk group. You can point to it. On ODF, the same 20 GiB disk is split into thousands of small objects, spread across every node in the cluster, with multiple replicas on different hardware. No single node holds the complete disk. No single disk failure loses any data.

This document walks through real output from a 3-node, 24-OSD cluster to show exactly what that distribution looks like — first at the cluster level, then traced through a single VM's disk.

## Cluster-Wide View

The `show-node-distribution.sh` script provides a top-down view of how storage is distributed across the cluster. The following sections walk through its output from a live cluster with 100 cloned VMs.

### Per-Node Storage Summary

```bash
  Host                                                      Capacity       Used  %Used  OSDs
  kube-...-000001d7                                        23.29 TiB  288.7 GiB   1.2%     8
  kube-...-000002b1                                        23.29 TiB  275.6 GiB   1.2%     8
  kube-...-00000311                                        23.29 TiB  271.4 GiB   1.1%     8

  TOTAL                                                    69.86 TiB  835.7 GiB   1.2%    24
```

This is the highest-level view: three nodes, each contributing 23.29 TiB of raw capacity via eight OSDs (Object Storage Daemons — the Ceph processes that own physical disks). Usage is nearly identical across all three nodes — 271 to 289 GiB each — because Ceph's CRUSH algorithm distributes data by design, not by accident.

The total cluster holds ~70 TiB of raw capacity with 836 GiB used (1.2%). Even with 100 cloned VMs and their golden image, usage is minimal because CoW clones share data with the parent.

### Per-OSD Breakdown

Each node's eight OSDs carry a roughly equal share of the data:

```bash
  kube-...-000001d7
    osd.1        2.91 TiB   36.2 GiB   1.2%   PGs: 22
    osd.4        2.91 TiB   38.7 GiB   1.3%   PGs: 25
    osd.7        2.91 TiB   36.0 GiB   1.2%   PGs: 22
    osd.10       2.91 TiB   39.0 GiB   1.3%   PGs: 24
    osd.13       2.91 TiB   38.5 GiB   1.3%   PGs: 24
    osd.16       2.91 TiB   33.0 GiB   1.1%   PGs: 20
    osd.19       2.91 TiB   31.5 GiB   1.1%   PGs: 19
    osd.22       2.91 TiB   35.9 GiB   1.2%   PGs: 22

  kube-...-000002b1
    osd.2        2.91 TiB   32.1 GiB   1.1%   PGs: 19
    osd.5        2.91 TiB   35.9 GiB   1.2%   PGs: 22
    ...

  kube-...-00000311
    osd.0        2.91 TiB   28.6 GiB   1.0%   PGs: 18
    osd.3        2.91 TiB   29.5 GiB   1.0%   PGs: 18
    ...
```

An **OSD** is a Ceph daemon responsible for a single physical disk (or partition). Each OSD manages a set of **Placement Groups (PGs)** — logical buckets that Ceph uses to distribute data. Objects are assigned to PGs via a hash, and PGs are mapped to OSDs by the CRUSH algorithm.

The PG counts here range from 17 to 25 per OSD. That slight variation is normal — CRUSH optimizes for even distribution but does not guarantee identical PG counts. What matters is that no single OSD is dramatically overloaded compared to its peers.

### Balance Assessment

```bash
  Highest node utilization:  1.2%
  Lowest  node utilization:  1.1%
  Spread:                    0.1 percentage points

  WELL BALANCED
  Data is evenly distributed across all nodes.
  No action needed.
```

A 0.1 percentage-point spread across three nodes means the data is almost perfectly balanced. In practice, you would start investigating imbalance if the spread exceeded a few percentage points, which can happen with very small pools or unusual CRUSH rules.

### PG Distribution

```bash
  OSD           PGs  Distribution
  osd.0          18  ██████████████████
  osd.1          22  ██████████████████████
  osd.4          25  █████████████████████████
  osd.9          17  █████████████████
  osd.12         24  ████████████████████████
  ...

  Total PGs across OSDs: 512  (each PG is replicated, so counted per replica)
  Average PGs per OSD:   21.3
  PG spread:             Moderate (38% variance)
```

This section visualizes how the 512 PG replicas in this pool are spread across OSDs. The bar chart makes hotspots easy to spot — in this cluster, the bars are all roughly the same length, confirming even distribution. The "38% variance" sounds high but is normal for a pool of this size; the absolute difference between the busiest OSD (25 PGs) and the quietest (17 PGs) is small.

### Pool Activity

```bash
  Client I/O:
    Read:  6.9 MiB/s  (1627 ops/s)
    Write: 366.5 MiB/s  (517 ops/s)
  Recovery:  None (cluster is clean)
```

A snapshot of live I/O at the moment the script ran. The write-heavy pattern (366 MiB/s writes vs. 6.9 MiB/s reads) is characteristic of the drift simulation phase, where each VM is writing unique data. "Recovery: None" confirms the cluster is healthy — no OSDs are down, no data is being rebalanced.

### Summary

```bash
  Balance:   Storage is well balanced across your 3 nodes.
             Each node is carrying a similar share of the data.
  Hotspots:  No hotspots detected. PG distribution is even across OSDs.
  Capacity:  1.2% used — plenty of headroom.
             69.05 TiB available across the cluster.
  Pool:      Pool 'nrt-2' is healthy with no active recovery.
```

The script distills the raw numbers into actionable observations. For a cluster running 100 cloned VMs with simulated drift, 1.2% usage and perfect balance is exactly what you would expect from CoW clones on a well-configured Ceph cluster.

## Single-VM Deep Dive

The `show-vm-placement.sh` script traces a single VM's disk from the Kubernetes layer all the way down to individual RADOS objects on specific OSDs and nodes. The following output traces `clone-vm-001`.

### The Mapping Chain

```bash
  VM                  clone-vm-001
   └─ PVC             clone-vm-001-disk
       └─ PV           pvc-793342cd-d14a-4cda-9aa2-2b39d4a88b2c
           └─ RBD Image   nrt-2/csi-vol-7e7002ab-fe50-4d4f-bfd5-4509bacab74f

  Disk size:        20.00 GiB
  Object size:      4.0 MiB  (each RADOS object)
  Total objects:    5,120
  Actual usage:     5.20 GiB
```

Four layers of abstraction connect the VM to physical storage:

1. **VM** — the KubeVirt VirtualMachine resource.
2. **PVC** — the PersistentVolumeClaim, which is how Kubernetes requests storage.
3. **PV** — the PersistentVolume, bound to the PVC by the CSI driver.
4. **RBD Image** — the actual Ceph block device image in the `nrt-2` pool.

The disk is 20 GiB in size but only consumes 5.20 GiB (26%) of actual storage. The remaining 74% is shared with the golden image parent via copy-on-write — it exists as pointers, not as duplicated data.

Ceph splits this 20 GiB disk into **5,120 objects** of 4 MiB each. Each object is an independent unit that can be placed on any OSD in the cluster.

### Clone Lineage

```bash
  Parent image:  nrt-2/csi-vol-...-temp@csi-vol-...
       │
       ▼  (CoW snapshot)
  This clone:    nrt-2/csi-vol-7e7002ab-fe50-4d4f-bfd5-4509bacab74f
```

This confirms the clone is a CoW child of the golden image. The parent is an RBD snapshot (the `@` delimiter denotes a snapshot in Ceph). When the VM reads a block it has never written to, Ceph follows the parent pointer to serve the data from the golden image's snapshot — no duplication required. Only when the VM writes to a block does Ceph copy that 4 MiB chunk into the clone's own storage.

### Data Anatomy

```bash
  Object naming:
    Prefix:  rbd_data.c4efa441f544
    Pattern: rbd_data.c4efa441f544.<16-hex-digit offset>

  Examples:
    rbd_data.c4efa441f544.0000000000000000  <- first 4.0 MiB of disk
    rbd_data.c4efa441f544.0000000000000a00  <- middle of disk
    rbd_data.c4efa441f544.00000000000013ff  <- last chunk of disk
```

Every object has a deterministic name: a prefix unique to this RBD image, followed by a hex offset identifying which 4 MiB slice of the disk it represents. Ceph hashes these names to determine which PG (and therefore which OSDs) each object lands on. This is why data distribution is automatic — the hash function ensures a roughly even spread without any manual placement decisions.

### Sample Placement Trace

The script samples 20 of the 5,120 objects to show where they physically land:

```bash
  Object                             PG           Primary    Replicas         Node
  rbd_data.c4efa441f544.00000000..   6.b00c5805   osd.22     osd.6            kube-...-000001d7
  rbd_data.c4efa441f544.00000000..   6.7ec23c01   osd.2      osd.3            kube-...-000002b1
  rbd_data.c4efa441f544.00000000..   6.b029b42b   osd.0      osd.16           kube-...-00000311
  rbd_data.c4efa441f544.00000000..   6.2e48f850   osd.3      osd.1            kube-...-00000311
  rbd_data.c4efa441f544.00000000..   6.8d660014   osd.6      osd.4            kube-...-00000311
  rbd_data.c4efa441f544.00000000..   6.8ca0fe23   osd.23     osd.9            kube-...-000002b1
  ...
```

Each row is one 4 MiB chunk of the VM's disk. Notice:

- **PG** — the placement group this object belongs to. Each PG hash is different, so objects land on different OSDs.
- **Primary** — the OSD that handles reads and writes for this object. The primaries are scattered across many different OSDs (0, 2, 3, 4, 5, 6, 9, 12, 14, 15, 19, 22, 23).
- **Replicas** — additional OSDs holding copies of this object on different nodes, ensuring data survives a node failure.
- **Node** — the node hosting the primary OSD. All three nodes appear as primary for different objects.

This is the core insight: a single VM's 20 GiB disk is not "on" any one node. It is spread across the entire cluster.

### Node Coverage

```bash
  Node                                                     Primary  + Replica  Total
  kube-...-000001d7                                              6          8     14
  kube-...-000002b1                                              6          4     10
  kube-...-00000311                                              8          8     16

  This VM's data touches ALL 3 nodes in the cluster.
  Unique PGs in sample: 20 | OSDs touched: 19 of 24
```

From just 20 sampled objects, the data already touches 19 of the 24 OSDs and all 3 nodes. Extrapolate to the full 5,120 objects, and the disk is effectively spread across every OSD in the cluster. There is no concept of "this VM lives on node 2" — the VM's compute runs on one node, but its storage is everywhere.

## How Drift Affects the Efficiency Metric

The test report shows storage efficiency declining as clones accumulate unique writes (drift).
Each drift level writes a new file of random data to every clone; previous files are kept, so the data is additive. Efficiency naturally declines as clones diverge from the golden image, but CoW continues to provide significant savings at every drift level.

### The progression

| Phase | PVCs | Stored (GB) | Full-Clone Cost (GB) | Efficiency |
|-------|-----:|------------:|---------------------:|-----------:|
| After cloning (no drift) | 101 | 5.73 | 579 | **101.0x** |
| +200 MB drift (1%) | 101 | 32.4 | 606 | **18.7x** |
| +1 GB drift (5%) | 101 | 116 | 689 | **5.9x** |
| +2 GB drift (10%) | 101 | 217 | 790 | **3.6x** |
| +5 GB drift (25%) | 101 | 524 | 1,097 | **2.1x** |

The efficiency ratio drops with each drift level because each clone is writing more unique data that cannot be shared. But notice the Full-Clone Cost column grows too — this reflects the fact that drift data would exist regardless of cloning strategy.

### How the formula works

The report calculates efficiency as:

```
drift_total     = actual_stored - post_clone_stored     # data added since cloning finished
full_clone_cost = pvc_count × baseline_stored + drift_total
efficiency      = full_clone_cost / actual_stored
```

- **First term (clone cost):** The cost of making full copies of the golden image for every clone — `101 × 5.734 GB = 579 GB`. This represents the data that CoW avoids duplicating.
- **Second term (drift):** The total new data written since cloning finished. This data is unique to each clone and would exist whether clones are CoW or full copies, so it appears in both the numerator and denominator.
- **Denominator (actual stored):** The real storage consumed by the pool.

At 25% drift, actual storage is 524 GB but full copies would cost 1,097 GB. The 2.1x ratio means CoW is still saving roughly half the storage even after significant divergence.

### What CoW is saving at 25% drift

At the highest drift level, CoW saves ~573 GB (1,097 − 524). Here is why:

- 75% of each clone's golden-image data was never written to. Those blocks are still shared with the parent and stored exactly once.
- Only the 25% of blocks that each clone actually modified required new storage.
- The drift data (~518 GB across all clones) is unique and must be stored regardless of cloning strategy — but the unmodified golden-image blocks are still shared.

### VMware linked clones behave the same way

This pattern is not unique to Ceph or ODF. VMware linked clones exhibit the same behavior: delta disks grow with writes, and the ratio of shared-to-unique data shrinks over time. The storage savings from any CoW mechanism are greatest immediately after cloning and diminish as clones diverge from the parent. The key question is not "what is the efficiency ratio?" but "how much divergence do you expect in your workload?" — and that depends on the use case, not the storage platform.

## Key Takeaways

- **Data is distributed, not localized.** A single VM's disk is split into thousands of 4 MiB objects, hashed into placement groups, and spread across every node and OSD in the cluster. No single node holds a complete copy of any VM's disk.

- **No single point of failure.** Every object is replicated across multiple nodes. A node failure does not cause data loss — Ceph serves reads from surviving replicas and automatically re-replicates to restore the desired replica count.

- **CoW clones share data.** A cloned VM starts by pointing to the golden image's data. Only blocks the clone writes to consume additional storage. In the example above, a 20 GiB disk uses only 5.20 GiB (26%) of actual storage — the other 74% is shared with the parent at zero cost.

- **This is different from VMware's storage model.** On VMware, a VM's VMDK sits on a single datastore backed by a specific storage device. On ODF, data is automatically spread and replicated across the cluster. There is no single-datastore bottleneck, and storage capacity scales by adding nodes rather than expanding individual arrays.

- **Balance is automatic.** Ceph's CRUSH algorithm distributes data without manual intervention. The cluster in this example shows a 0.1 percentage-point spread across three nodes — nearly perfect balance with no tuning required.
