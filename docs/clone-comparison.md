# Linked Clones Across Platforms: VMware, ODF, and IBM Cloud

## Introduction

When deploying many virtual machines from a single template — whether for VDI desktops, dev/test environments, or training labs — every VM needs its own disk. A naive approach copies the entire template disk for each clone. For a 20 GB template and 100 clones, that means 2 TB of storage consumed, even though every clone starts as an identical copy of the same data.

**Linked clones** (also called copy-on-write or CoW clones) solve this problem. Instead of duplicating the full disk, each clone shares the unchanged data with the template and only stores the blocks that differ. If each clone drifts by 1 GB of unique writes, total storage drops from 2 TB to roughly 120 GB (20 GB template + 100 x 1 GB of unique data) — a 94% reduction.

However, not every storage platform implements clones the same way. Some deliver true CoW efficiency; others create full copies behind the scenes. This document compares how VMware, Red Hat OpenShift Data Foundation (ODF), and IBM Cloud storage each handle the problem, so you can understand what to expect from your environment.

## VMware Linked Clones

### What They Are

VMware vSphere offers two clone types: **full clones** and **linked clones**. A full clone is a complete, independent copy of the source VM's disk. A linked clone starts from a **snapshot** of the parent VM. That snapshot becomes a read-only base disk, and the clone gets a thin **delta disk** that records only the changes.

### How Delta Disks Work

Linked clones use copy-on-write at the VMDK (virtual disk) level:

- **Reads** of data that the clone has not modified are served directly from the parent snapshot's base disk. There is no duplication of that data.
- **Writes** land in the clone's delta disk. The first time a block is written, it is copied from the parent into the delta (the "copy" in copy-on-write), and all future reads of that block come from the delta.

Over time, as the clone modifies more data, its delta disk grows. But blocks that are never modified — OS binaries, installed applications, static configuration — remain shared across all clones via the parent snapshot.

### Benefits

- **Near-instant creation.** Creating a linked clone only requires creating a new delta disk file, not copying gigabytes of data. Clones typically appear in seconds.
- **Storage proportional to drift.** Total storage consumed scales with how much each clone changes, not the size of the original disk.
- **Efficient at scale.** 100 linked clones of a 20 GB template might consume 25 GB total if drift is minimal, rather than 2 TB.

### Trade-offs

- **I/O overhead.** Reading a block may require walking the snapshot chain to find the most recent version. Long chains (snapshots of snapshots) amplify this overhead.
- **Parent dependency.** Linked clones cannot exist without their parent snapshot. Deleting or corrupting the parent breaks every clone derived from it.
- **Chain management.** VMware recommends limiting snapshot chain depth. Very long chains degrade performance and complicate management.

## The ODF / Ceph RBD Equivalent

Red Hat OpenShift Data Foundation (ODF) uses Ceph as its underlying storage system. When running OpenShift Virtualization (CNV), VM disks are stored as **Ceph RBD (RADOS Block Device) images**. ODF supports a clone mechanism that is functionally equivalent to VMware linked clones, but implemented at the storage layer rather than the hypervisor layer.

### How CDI CSI-Level Cloning Works

OpenShift Virtualization uses the **Containerized Data Importer (CDI)** to manage VM disk lifecycle. When you create a new VM by cloning an existing disk (via a DataVolume that references an existing PersistentVolumeClaim), CDI can use one of two paths:

1. **CSI clone (preferred):** CDI asks the Ceph CSI driver to clone the volume. Ceph creates an **RBD snapshot** of the source image and then creates a **CoW child image** from that snapshot. This is a metadata-only operation — no data is copied.
2. **Host-assisted copy (fallback):** If CSI cloning is not available or fails, CDI falls back to reading all data from the source and writing it to a new volume. This is a full copy with no space savings.

### Mechanics

The CSI clone path works like this:

- Ceph takes an internal snapshot of the golden image's RBD image (the source PVC).
- Ceph creates a new RBD image (the clone's PVC) as a CoW child of that snapshot.
- **Reads** of unchanged blocks are served from the parent snapshot — the data is not duplicated.
- **Writes** create new RADOS objects in the child image. Only the modified blocks consume additional storage.

This is the same copy-on-write principle as VMware linked clones, but handled entirely within the Ceph storage cluster.

### Mapping to VMware Concepts

| VMware Concept | ODF / Ceph Equivalent |
|---|---|
| Parent VM snapshot (base disk) | RBD snapshot of the golden image PVC |
| Delta disk (per-clone) | RBD CoW child image (clone's PVC) |
| Snapshot chain | Parent-child relationship in Ceph |
| VMDK-level CoW | RADOS object-level CoW |

### Benefits

- **Same space efficiency as VMware linked clones.** Storage consumption is proportional to drift, not total disk size.
- **Storage-layer operation.** The clone is managed entirely by Ceph — there are no VM-level snapshot chains to manage, and the hypervisor (KubeVirt) is not involved in the clone mechanics.
- **Kubernetes-native.** Clones are created by defining a DataVolume YAML manifest and applying it to the cluster. Standard Kubernetes tooling handles the lifecycle.

### Validating That CoW Cloning Is Active

It is critical to verify that CDI is actually using CSI-level cloning and not falling back to host-assisted copy. After a clone is created, check the DataVolume's annotation:

```bash
oc get dv <clone-name> -o jsonpath='{.metadata.annotations.cdi\.kubevirt\.io/cloneType}'
```

- **`csi-clone`** — CoW clone via the Ceph CSI driver. Space-efficient.
- **`copy`** — Host-assisted full copy. No space savings. If you see this, your test results will not reflect CoW efficiency.

Common reasons for fallback to `copy` include mismatched StorageClasses between source and clone, missing CSI clone capabilities, or CDI configuration issues.

## IBM Cloud Block and File Storage

IBM Cloud offers several storage options for virtual machines. Their clone behavior varies significantly depending on whether you are using cloud-hosted (VPC) storage or on-premises IBM storage arrays.

### VPC Block Storage (vpc.block.csi.ibm.io)

IBM Cloud VPC Block Storage is the default block storage option for IBM Cloud Kubernetes Service (IKS) and Red Hat OpenShift on IBM Cloud (ROKS) clusters running in VPC infrastructure.

**Snapshot support:** The VPC Block CSI driver supports volume snapshots. You can create a point-in-time snapshot of a volume, then create a new volume from that snapshot.

**No CSI volume cloning:** The VPC Block CSI driver does **not** support the CSI `VolumeClone` capability. There is no way to create a CoW clone of an existing volume through the CSI interface.

**What happens when you clone a VM disk:** To duplicate a VM's disk, you must take a snapshot of the source volume and then restore (provision) a new volume from that snapshot. The restored volume is a **full, independent copy** of the data at the time of the snapshot. There is no copy-on-write relationship between the original and the new volume. Every block is duplicated.

**Storage impact:** Cloning 100 VMs from a 20 GB template produces 100 x 20 GB = 2 TB of block storage consumption, regardless of how little each clone diverges from the template. There is no efficiency gain from shared data.

**Bare metal limitation:** VPC Block Storage volumes cannot be attached to bare metal worker nodes. Since OpenShift Virtualization requires bare metal workers, VPC Block Storage is not a viable option for VM disks on ROKS bare metal clusters. See the [IBM Cloud Bare Metal Server FAQ](https://cloud.ibm.com/docs/vpc?topic=vpc-bare-metal-server-faq) for details.

### VPC File Storage (vpc.file.csi.ibm.io)

IBM Cloud VPC File Storage provides NFS-based shared file systems. While it supports snapshots and can create volumes from existing volumes, the resulting volumes are full copies — the same full-copy semantics as VPC Block Storage. There is no block-level CoW.

### On-Premises IBM Block Storage (block.csi.ibm.com)

IBM's on-premises storage arrays — FlashSystem, Storwize, and SAN Volume Controller (SVC) — offer a fundamentally different capability through **FlashCopy**.

**FlashCopy** creates a space-efficient, point-in-time copy of a volume. It uses copy-on-write mechanics similar to Ceph RBD clones:

- At creation time, the FlashCopy target volume shares data with the source. No blocks are physically copied.
- When either the source or target is written to, the original data is preserved in the target via CoW before the write completes.
- Over time, only modified blocks consume additional storage.

The IBM block CSI driver (`block.csi.ibm.com`) exposes this capability as CSI volume cloning, making it compatible with CDI's CSI clone path in OpenShift Virtualization.

**Important distinction:** FlashCopy is only available with on-premises IBM storage arrays. It is **not** available on IBM Cloud VPC infrastructure.

### Practical Implications

If you run this test harness on **IBM Cloud VPC storage**, expect to see roughly 0% efficiency gain — every clone is a full copy, and total storage consumption scales linearly with clone count.

If you need CoW clone efficiency on IBM Cloud, you have two options:

1. **Deploy ODF on IBM Cloud.** ROKS clusters support the ODF add-on, which provisions a Ceph cluster on top of VPC Block Storage. Once ODF is running, you get Ceph RBD CoW clones, the same mechanism described in the ODF section above.
2. **Use IBM FlashSystem on-premises.** If your infrastructure includes on-prem IBM storage arrays, FlashCopy provides space-efficient clones natively.

## Comparison Table

| | VMware Linked Clone | ODF / Ceph RBD CoW Clone | IBM Cloud VPC (Snapshot-Restore) | IBM On-Prem FlashCopy |
|---|---|---|---|---|
| **Mechanism** | VMDK snapshot + delta disk | RBD snapshot + CoW child image | Volume snapshot + full restore | FlashCopy (CoW at array level) |
| **Storage at creation** | Minimal (delta disk metadata only) | Minimal (metadata-only operation) | Full copy of source volume | Minimal (metadata-only operation) |
| **Copy-on-write** | Yes — writes go to delta disk | Yes — writes create new RADOS objects | No — all blocks copied at restore time | Yes — writes trigger CoW at array level |
| **Clone speed** | Seconds | Seconds | Minutes (proportional to volume size) | Seconds |
| **Dependency chain** | Clone depends on parent snapshot | Child image depends on parent snapshot in Ceph | None — fully independent after restore | Depends on FlashCopy relationship until background copy completes |
| **Space efficiency at scale** | High — shared base, per-clone drift only | High — shared base, per-clone drift only | None — each clone is a full copy | High — shared base, per-clone drift only |
| **Where available** | VMware vSphere | Any ODF/Ceph deployment (on-prem, cloud) | IBM Cloud VPC only | IBM FlashSystem, Storwize, SVC (on-prem only) |

## Key Takeaways

- **Not all "clones" are equal.** The word "clone" can mean a space-efficient CoW copy or a full block-for-block duplicate depending on the storage platform. The difference matters enormously at scale.

- **CSI clone support varies by driver.** Just because a CSI driver supports snapshots does not mean it supports CoW cloning. IBM Cloud VPC Block Storage supports snapshots but not CSI volume clones — resulting in full copies every time.

- **Verify your clone type.** In OpenShift Virtualization with ODF, always check the `cdi.kubevirt.io/cloneType` annotation. A value of `csi-clone` confirms CoW efficiency; `copy` means you are getting full copies with no space savings.

- **This test harness validates real behavior.** Rather than trusting documentation or assumptions, the scripts in this repository measure actual storage consumption before and after cloning, and after simulated drift. If your storage does not deliver CoW clones, the numbers will show it.

- **Platform choice determines efficiency.** VMware linked clones, ODF/Ceph RBD CoW clones, and IBM FlashCopy all deliver genuine space efficiency. IBM Cloud VPC storage does not. Choose your storage backend accordingly when space-efficient VM fleets are a requirement.
