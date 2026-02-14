#!/bin/bash
# ============================================================
# ODF Storage Efficiency Test - Configuration
# ============================================================
# Edit these variables to match your environment.

# Namespace for all test resources
export TEST_NS="vm-storage-test"

# StorageClass and Ceph pool (get these from your ODF StoragePool CR:
#   oc get storagepool -n openshift-storage)
export STORAGE_CLASS="nrt-2-rbd"
export CEPH_POOL="nrt-2"

# Golden image settings
export GOLDEN_VM_NAME="golden-template"
export GOLDEN_DV_NAME="golden-image-dv"
export GOLDEN_DISK_SIZE="20Gi"

# Source image URL (Fedora Cloud qcow2 - change to RHEL if preferred)
# This is the base OS image that will become your golden template.
export SOURCE_IMAGE_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/43/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-43-1.6.x86_64.qcow2"

# Alternatively, use a registry-based source (faster, no external download):
# export SOURCE_REGISTRY="registry.redhat.io/rhel9/rhel-guest-image:latest"

# Clone settings
export CLONE_PREFIX="clone-vm"
export CLONE_COUNT=100          # Set to 100 for Phase 2, 1000 for Phase 4
export CLONE_BATCH_SIZE=20      # Create clones in batches to avoid API pressure

# Drift simulation settings (MB of unique data per VM)
export DRIFT_LEVELS_MB="200 1024 2048 5120"  # 1%, 5%, 10%, 25% of 20GB

# Toolbox pod label selector
export TOOLBOX_SELECTOR="app=rook-ceph-tools"
export TOOLBOX_NS="openshift-storage"

# SSH key for VM access (auto-generated if missing)
export SSH_KEY_DIR="./ssh-keys"
export SSH_KEY_PATH="$SSH_KEY_DIR/odf-test"
mkdir -p "$SSH_KEY_DIR" 2>/dev/null
if [[ ! -f "$SSH_KEY_PATH" ]]; then
    ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -q
fi
export SSH_PUB_KEY=$(cat "$SSH_KEY_PATH.pub")
export VM_SSH_USER="fedora"

# Output directory for measurement CSVs
export RESULTS_DIR="./results"
mkdir -p "$RESULTS_DIR" 2>/dev/null
