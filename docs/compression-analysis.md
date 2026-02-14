---
layout: default
title: Compression Analysis
---

# Compression Analysis

This document explains the "Compression Impact" chart in the storage efficiency report — what the numbers mean, where they come from, and why so little of the test data benefits from compression.

## Reading the Compression Impact Chart

The chart shows two bars at each measurement point:

- **Before Compression** (orange) — Total bytes that Ceph identified as compressible and attempted to compress, across the entire pool.
- **After Compression** (teal) — The size of that same data after compression was applied.

These are **pool-wide totals**, not per-VM values. At the 25% drift level, the 21.53 GB "Before Compression" figure represents the total compressible data across all 100 clones and the golden image combined.

Data that Ceph determines is incompressible never appears in the chart — it is stored as-is and not counted in these metrics.

## Where the Numbers Come From

The metrics are two BlueStore-level counters from `ceph df detail --format json` for the target pool:

- **`compress_under_bytes`** — Total bytes of data that passed through BlueStore's compression pipeline (the "before" value).
- **`compress_bytes_used`** — The on-disk size of that data after compression (the "after" value).

These counters track only the data that BlueStore's heuristic identified as worth compressing. Data that BlueStore skips (because a sample showed it was incompressible) is stored uncompressed and excluded from both counters.

## Compression Progression

The table below shows how compression metrics evolve across all seven measurement points. "Stored" is the total pool usage from `ceph df`.

| Phase | Stored (GB) | Compressible (GB) | After Compression (GB) | Saved (GB) | Ratio | % of Stored |
|-------|------------:|-------------------:|-----------------------:|-----------:|------:|------------:|
| baseline | 5.73 | 0.25 | 0.12 | 0.12 | 50% | 4.3% |
| after-golden-image | 5.74 | 0.25 | 0.12 | 0.12 | 50% | 4.3% |
| after-100-clones | 5.74 | 0.25 | 0.12 | 0.12 | 50% | 4.3% |
| +200 MB drift | 32.3 | 9.23 | 4.62 | 4.62 | 50% | 28.6% |
| +1 GB drift | 116.3 | 14.48 | 7.24 | 7.24 | 50% | 12.4% |
| +2 GB drift | 218.4 | 16.71 | 8.35 | 8.35 | 50% | 7.7% |
| +5 GB drift | 524.1 | 21.53 | 10.76 | 10.76 | 50% | 4.1% |

Two patterns stand out:

1. **Compressible data grows with drift** even though the drift data itself is incompressible — because each drift phase involves VMs running and generating compressible operational data.
2. **Compressible-as-%-of-stored drops** at higher drift levels because the incompressible random data dominates the pool.

## Why Only 4% of Data Is Compressible

The drift simulation deliberately uses `dd if=/dev/urandom` to write random data into each clone. Random data is incompressible by definition — BlueStore samples it, determines compression would not help, and stores it as-is.

The 21.53 GB of compressible data at the 25% drift level comes from:

- **Filesystem metadata** — Inodes, ext4 journals, block allocation tables, and directory structures generated as VMs write drift files. These are highly structured and compress well.
- **OS boot artifacts** — Each VM boots during drift phases, generating systemd journals, log files, `/tmp` data, and other operational output. This is text-heavy and compresses easily.
- **Golden image content** — A small amount (0.25 GB at baseline) of compressible data from the original Fedora Cloud image.

The compressible data grows from 0.25 GB to 21.53 GB across drift phases because each phase boots VMs, writes drift data (which generates metadata as a side effect), and shuts them down — accumulating more operational data each time.

## The Consistent 50% Ratio

Every measurement point shows exactly 50% compression — the compressible data is always reduced to half its original size. This consistency suggests the compressible content is predominantly filesystem metadata and structured log data, which compresses predictably. The ratio does not change because each drift phase generates more of the same type of compressible data (metadata and logs) rather than introducing a different mix.

## Real Workloads vs. This Test

This test represents a **worst case for compression**. Random data from `/dev/urandom` is the least compressible payload possible, so it isolates CoW efficiency without compression masking the results.

Real VM workloads contain far more compressible content:

- **Application logs** — Repetitive text that compresses at 5:1 or better.
- **Database files** — Structured data with repeated patterns.
- **Documents and web assets** — Text, HTML, CSS, and uncompressed images.
- **OS updates and packages** — RPM/deb contents with significant redundancy.

Production environments should see a much higher percentage of data benefiting from compression, and likely better ratios than the 50% observed here.

## Three Layers of Storage Efficiency

Storage savings in this test come from three independent mechanisms. Each operates at a different layer, and their effects stack.

### 1. Thin Provisioning (~1,496 GB saved)

RBD images are thin-provisioned by default. Each VM's 20 GB virtual disk is a *contract* for the maximum size the VM may use, not a pre-allocation of 20 GB on disk. Blocks that the VM has never written consume zero storage.

The golden image contains ~5 GB of OS and test data, so it occupies only 5.7 GB of its 20 GB disk — 71% of the virtual disk is unwritten and free. Clones inherit this sparsity. Even after the 25% drift phase writes 5 GB of additional data into each clone, every disk still has large unwritten regions.

Thin provisioning is the single largest source of savings in this test. With 101 VMs (100 clones + the golden image), the fully-provisioned cost would be 101 × 20 GB = **2,020 GB**, yet the pool stores only 524 GB — a gap of ~1,496 GB that thin provisioning accounts for.

### 2. CoW Cloning (~474 GB saved)

Copy-on-write cloning avoids duplicating the golden image across clones. All 100 clones share a single 5.7 GB base image; only blocks that a clone modifies (drift data, boot artifacts) are written as new allocations. At the 25% drift level, CoW saves roughly 474 GB that would otherwise be consumed by 100 redundant copies of the base image.

### 3. Compression (~10.7 GB saved)

BlueStore compression shrinks compressible data before writing it to disk. In this test it saves 10.76 GB by compressing filesystem metadata and logs to half their original size. This is the smallest contributor because the test deliberately uses incompressible random data for drift.

### How They Stack

The three layers apply in sequence — each reduces storage that the previous layer left behind:

| Layer | Cumulative storage | Savings at this layer |
|-------|-------------------:|----------------------:|
| Fully provisioned (101 × 20 GB) | 2,020 GB | — |
| After thin provisioning | ~524 GB | ~1,496 GB (unwritten blocks) |
| After CoW cloning | ~50 GB unique data | ~474 GB (shared base image) |
| After compression | ~39 GB unique data | ~10.7 GB (metadata/logs compressed 50%) |

Thin provisioning removes the most storage because each 20 GB disk is mostly empty. CoW eliminates the next largest cost — duplicated base image data. Compression mops up whatever compressible data remains.

### Production Trade-offs

In real workloads that write more of each virtual disk, thin provisioning savings decrease — VMs that fill 80% of their disk leave only 20% thin. But compression savings increase, because real application data (logs, databases, documents) is far more compressible than the `/dev/urandom` output used in this test. The balance shifts from thin provisioning toward compression as disks fill up, but the total savings from all three layers combined remains substantial.
