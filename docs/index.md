---
layout: default
title: Home
---

# ODF Storage Efficiency Test

Benchmarking how OpenShift Data Foundation (ODF / Ceph RBD) handles VM disk cloning at scale, compared against VMware linked clones.

## Documentation

- [Linked Clones Across Platforms](clone-comparison.html) — How VMware linked clones, ODF/Ceph RBD CoW clones, and IBM Cloud storage each handle clone efficiency
- [Understanding Storage Distribution](storage-distribution.html) — How data fans out across nodes, OSDs, and placement groups
- [ODF Storage Concepts for vSAN Administrators](odf-storage-concepts.html) — ODF concepts mapped to VMware vSAN terminology
- [Compression Analysis](compression-analysis.html) — Why compression saves only 4% in this test and what that means for real workloads

## Example Report

- [Storage Efficiency Report](example_report.html) — Sample output from a 100-clone test run

## Source

The test harness and scripts are on GitHub: [odf-storage-efficiency-test](https://github.com/neil1taylor/odf-storage-efficiency-test)
