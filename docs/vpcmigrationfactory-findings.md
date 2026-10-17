---
layout: default
title: VPCMigrationFactory Findings
---

# Cloning Findings from the VPCMigrationFactory Box Folder

**Source:** IBM team Box folder VPCMigrationFactory, read on 17 Oct 2026.
**Status:** Not reproduced. This project did not run these tests. The facts below come from the Box notes. Treat them as leads, not as results of this harness.

## 303 VMs provisioned from a VolumeSnapshot

Source: "Scale testing - ODF" (17 Sep 2026). Test date in the note: 11 Sep 2026.

- **Cluster:** ROKS `br-sao-1`, OCP 4.21.27, StorageClass `ocs-storagecluster-ceph-rbd-virtualization`. 4 compute + 6 ODF nodes.
- **Provisioning:** VMs came from a VolumeSnapshot source, with no PVC clone. This harness clones from a PVC through CDI (`source.pvc`), so the two methods differ.
- **VMs:** 200 CentOS + 100 Windows at 2 vCPU / 4 GiB. The note gives 303 VMs in total. Four namespaces on localnet VLANs through a ClusterUserDefinedNetwork.
- **State:** All 303 running, 0 paused, all live-migratable.
- **fio** on 50 CentOS VMs (randrw 70/30, 8K, IO depth 8), per VM: read about 1,774 IOPS at 1.58 ms mean; write about 760 IOPS at 6.79 ms.

## Snapshot-based PVCs need two RBD image features

Source: "ROVE - Required Change Checklist" (9 Sep 2026). This is a workaround for a known issue.

If VMs deploy from snapshot-based PVCs, patch the snapshot RBD images to include the features `exclusive-lock` and `fast-diff`.

The same checklist says to enable autoscale on `ocs-storagecluster-cephblockpool`.
