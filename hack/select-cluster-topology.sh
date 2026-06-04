#!/usr/bin/env bash
# =============================================================================
# hack/select-cluster-topology.sh
# =============================================================================
# Auto-selects SNO or Converged edge topology based on available host resources
# and creates examples/ibm-cloud-active symlink to the chosen example directory.
#
# Usage:
#   ./hack/select-cluster-topology.sh
#
# Environment variables:
#   OPENSHIFT_VIRT=true   Raise RAM thresholds to account for KubeVirt overhead.
#                         Default: false
#   FORCE_TOPOLOGY=ibm-cloud-converged|ibm-cloud-sno
#                         Override auto-detection and force a specific topology.
#
# Supported topologies:
#   ibm-cloud-converged   3-node compact cluster on VLAN 1925 (192.168.50.0/24)
#                         Min: 96 GB RAM, 24 CPU, 360 GB free disk
#                         With OCP Virt: 128 GB RAM
#   ibm-cloud-sno         Single-Node OpenShift on VLAN 1926 (192.168.51.0/24)
#                         Min: 32 GB RAM, 8 CPU, 120 GB free disk
#                         With OCP Virt: 48 GB RAM
#
# After running this script:
#   All subsequent commands reference examples/ibm-cloud-active/ automatically:
#     ansible-playbook playbooks/create-installation-media.yml \
#       -i examples/ibm-cloud-active/inventory.yml \
#       -e @examples/ibm-cloud-active/extra-vars.yml
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
EXAMPLES_DIR="$REPO_ROOT/examples"
ACTIVE_LINK="$EXAMPLES_DIR/ibm-cloud-active"

OPENSHIFT_VIRT="${OPENSHIFT_VIRT:-false}"
FORCE_TOPOLOGY="${FORCE_TOPOLOGY:-}"

# ── Thresholds ─────────────────────────────────────────────────────────────────
# Base thresholds (no OCP Virt)
CONVERGED_MIN_RAM_GB=96
CONVERGED_MIN_DISK_GB=360
CONVERGED_MIN_CPUS=24

SNO_MIN_RAM_GB=32
SNO_MIN_DISK_GB=120
SNO_MIN_CPUS=8

# With OpenShift Virtualization enabled, raise RAM thresholds
if [[ "$OPENSHIFT_VIRT" == "true" ]]; then
  CONVERGED_MIN_RAM_GB=128
  SNO_MIN_RAM_GB=48
  echo "INFO: OPENSHIFT_VIRT=true — using higher RAM thresholds (Converged: ${CONVERGED_MIN_RAM_GB} GB, SNO: ${SNO_MIN_RAM_GB} GB)"
fi

# ── Inspect host resources ─────────────────────────────────────────────────────
# Available RAM in GB (free/available, not total)
AVAILABLE_RAM_GB=$(free -g | awk '/^Mem:/{print $7}')
# Total CPU cores
AVAILABLE_CPUS=$(nproc)
# Free disk on libvirt images directory (fall back to /var/lib/libvirt if pool not mounted)
LIBVIRT_DIR="/var/lib/libvirt/images"
if [[ ! -d "$LIBVIRT_DIR" ]]; then
  LIBVIRT_DIR="/var/lib/libvirt"
fi
AVAILABLE_DISK_GB=$(df -BG "$LIBVIRT_DIR" | awk 'NR==2{gsub("G",""); print $4}')

echo ""
echo "============================================================"
echo "  Edge Cluster Topology Auto-Selection"
echo "============================================================"
echo "  Host resources:"
echo "    RAM available:  ${AVAILABLE_RAM_GB} GB  (Converged min: ${CONVERGED_MIN_RAM_GB} GB, SNO min: ${SNO_MIN_RAM_GB} GB)"
echo "    CPU cores:      ${AVAILABLE_CPUS}        (Converged min: ${CONVERGED_MIN_CPUS}, SNO min: ${SNO_MIN_CPUS})"
echo "    Disk free:      ${AVAILABLE_DISK_GB} GB  (Converged min: ${CONVERGED_MIN_DISK_GB} GB, SNO min: ${SNO_MIN_DISK_GB} GB)"
echo "    OCP Virt:       ${OPENSHIFT_VIRT}"
echo "------------------------------------------------------------"

# ── Select topology ────────────────────────────────────────────────────────────
if [[ -n "$FORCE_TOPOLOGY" ]]; then
  TOPOLOGY="$FORCE_TOPOLOGY"
  echo "  FORCE_TOPOLOGY set — using: $TOPOLOGY"
elif [[ "$AVAILABLE_RAM_GB" -ge "$CONVERGED_MIN_RAM_GB" && \
        "$AVAILABLE_CPUS"  -ge "$CONVERGED_MIN_CPUS"  && \
        "$AVAILABLE_DISK_GB" -ge "$CONVERGED_MIN_DISK_GB" ]]; then
  TOPOLOGY="ibm-cloud-converged"
  echo "  Selected: CONVERGED (3-node compact, VLAN 1925, 192.168.50.0/24)"
elif [[ "$AVAILABLE_RAM_GB" -ge "$SNO_MIN_RAM_GB" && \
        "$AVAILABLE_CPUS"  -ge "$SNO_MIN_CPUS"  && \
        "$AVAILABLE_DISK_GB" -ge "$SNO_MIN_DISK_GB" ]]; then
  TOPOLOGY="ibm-cloud-sno"
  echo "  Selected: SNO (single node, VLAN 1926, 192.168.51.0/24)"
else
  echo ""
  echo "ERROR: Insufficient resources for any supported topology."
  echo "       SNO minimum: ${SNO_MIN_RAM_GB} GB RAM, ${SNO_MIN_CPUS} CPUs, ${SNO_MIN_DISK_GB} GB disk"
  echo "       Available:   ${AVAILABLE_RAM_GB} GB RAM, ${AVAILABLE_CPUS} CPUs, ${AVAILABLE_DISK_GB} GB disk"
  echo ""
  echo "       To force a topology anyway: FORCE_TOPOLOGY=ibm-cloud-sno ./hack/select-cluster-topology.sh"
  exit 1
fi

TOPOLOGY_DIR="$EXAMPLES_DIR/$TOPOLOGY"
if [[ ! -d "$TOPOLOGY_DIR" ]]; then
  echo "ERROR: Topology directory not found: $TOPOLOGY_DIR"
  exit 1
fi

# ── Create symlink ─────────────────────────────────────────────────────────────
ln -sfn "$TOPOLOGY_DIR" "$ACTIVE_LINK"

echo "  Active config:  examples/ibm-cloud-active → examples/$TOPOLOGY"
echo "============================================================"
echo ""
echo "Next steps:"
echo "  1. Fill in pull_secret and ssh_pub_key in examples/$TOPOLOGY/extra-vars.yml"
echo "     OR run: ./hack/setup-cluster-vars.sh"
echo ""
echo "  2. If enabling OpenShift Virtualization, set in extra-vars.yml:"
echo "     install_openshift_virtualization: true"
if [[ "$TOPOLOGY" == "ibm-cloud-converged" ]]; then
  echo "     (requires >= 128 GB RAM — you have ${AVAILABLE_RAM_GB} GB)"
else
  echo "     (requires >= 48 GB RAM — you have ${AVAILABLE_RAM_GB} GB)"
fi
echo ""
echo "  3. Deploy VMs and generate ISO:"
echo "     ./hack/deploy-kvm-vms.sh"
echo "     ansible-playbook playbooks/create-installation-media.yml \\"
echo "       -i examples/ibm-cloud-active/inventory.yml \\"
echo "       -e @examples/ibm-cloud-active/extra-vars.yml"
