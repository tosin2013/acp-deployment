#!/usr/bin/env bash
# install-kvm-host.sh — Install KVM/libvirt on CentOS Stream 10 and configure /dev/vdb as VM storage pool
# Usage: sudo ./hack/install-kvm-host.sh [--vm-disk /dev/vdb]
#
# Requirements:
#   - CentOS Stream 10 (or RHEL 9/10 compatible)
#   - Root or sudo privileges
#   - /dev/vdb (or specified disk) unformatted and available
#
# After running this script:
#   - libvirt/KVM stack is installed and enabled
#   - Storage pool 'acp-vms' is created on the specified disk
#   - Nested virtualisation is enabled for OpenShift Virtualization support
#   - The current user is added to the 'libvirt' group (re-login required)

set -euo pipefail

VM_DISK="${1:-/dev/vdb}"
POOL_NAME="acp-vms"
POOL_MOUNT="/var/lib/libvirt/acp-vms"

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

# ── Preflight checks ───────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "This script must be run as root (sudo $0)"

# Check the VM disk exists and is a block device
[[ -b "${VM_DISK}" ]] || die "VM disk ${VM_DISK} not found or is not a block device"

# Warn if the disk appears to be in use
if lsblk -n -o MOUNTPOINT "${VM_DISK}" | grep -q .; then
    die "${VM_DISK} appears to be mounted. Aborting to prevent data loss."
fi

info "KVM host installation starting"
info "  VM storage disk : ${VM_DISK}"
info "  Pool name       : ${POOL_NAME}"
info "  Pool mount      : ${POOL_MOUNT}"
echo ""

# ── Install KVM packages ───────────────────────────────────────────────────────
info "Installing KVM/libvirt packages..."
dnf install -y \
    qemu-kvm \
    libvirt \
    libvirt-client \
    virt-install \
    libguestfs-tools \
    python3-libvirt \
    iproute \
    jq \
    python3-pip \
    wget \
    curl \
    dnsmasq \
    haproxy || {
    warn "One or more packages failed to install. Check dnf output above."
}
# aws-cli: try awscli2 (CentOS Stream 10 package name), fall back to pip3
if ! command -v aws &>/dev/null; then
    dnf install -y awscli2 2>/dev/null || pip3 install awscli --quiet || \
        warn "aws-cli install failed; install manually with: pip3 install awscli"
fi

# ── Enable and start libvirtd ──────────────────────────────────────────────────
info "Enabling and starting libvirtd..."
systemctl enable --now libvirtd
systemctl enable --now virtlogd

# ── Add current non-root user to libvirt group ─────────────────────────────────
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo '')}"
if [[ -n "${REAL_USER}" && "${REAL_USER}" != "root" ]]; then
    info "Adding ${REAL_USER} to the 'libvirt' group..."
    usermod -aG libvirt "${REAL_USER}"
    info "  Note: ${REAL_USER} must log out and back in for group membership to take effect"
fi

# ── Enable nested virtualisation ──────────────────────────────────────────────
info "Enabling nested virtualisation..."
CPU_VENDOR=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $3}')
if [[ "${CPU_VENDOR}" == "GenuineIntel" ]]; then
    cat > /etc/modprobe.d/kvm-intel-nested.conf <<'EOF'
options kvm_intel nested=1
EOF
    modprobe -r kvm_intel 2>/dev/null || true
    modprobe kvm_intel nested=1 || warn "Could not reload kvm_intel module live; will apply on next boot"
    info "  Intel nested virt configured (kvm_intel nested=1)"
elif [[ "${CPU_VENDOR}" == "AuthenticAMD" ]]; then
    cat > /etc/modprobe.d/kvm-amd-nested.conf <<'EOF'
options kvm_amd nested=1
EOF
    modprobe -r kvm_amd 2>/dev/null || true
    modprobe kvm_amd nested=1 || warn "Could not reload kvm_amd module live; will apply on next boot"
    info "  AMD nested virt configured (kvm_amd nested=1)"
else
    warn "Unknown CPU vendor '${CPU_VENDOR}'. Nested virt not configured."
fi

# Verify nested virt is active
NESTED_STATUS=$(cat /sys/module/kvm_intel/parameters/nested 2>/dev/null \
    || cat /sys/module/kvm_amd/parameters/nested 2>/dev/null || echo "unknown")
if [[ "${NESTED_STATUS}" == "Y" || "${NESTED_STATUS}" == "1" ]]; then
    info "  Nested virtualisation: ENABLED"
else
    warn "  Nested virtualisation: ${NESTED_STATUS} (may require reboot)"
fi

# ── Create libvirt storage pool on /dev/vdb ────────────────────────────────────
info "Configuring libvirt storage pool '${POOL_NAME}' on ${VM_DISK}..."

# Check if pool already exists
if virsh pool-info "${POOL_NAME}" &>/dev/null; then
    warn "Pool '${POOL_NAME}' already exists. Skipping creation."
else
    mkdir -p "${POOL_MOUNT}"
    # Format vdb as a single ext4 partition for libvirt dir pool
    # We use a directory pool (not a disk pool) so qcow2 images can be created flexibly
    info "  Formatting ${VM_DISK} with ext4..."
    mkfs.ext4 -F -L acp-vms "${VM_DISK}"
    
    # Add to fstab for persistence
    DISK_UUID=$(blkid -s UUID -o value "${VM_DISK}")
    grep -q "acp-vms" /etc/fstab || \
        echo "UUID=${DISK_UUID}  ${POOL_MOUNT}  ext4  defaults,nofail  0  2" >> /etc/fstab
    mount "${POOL_MOUNT}"
    
    # Define and start the libvirt dir pool
    virsh pool-define-as "${POOL_NAME}" dir --target "${POOL_MOUNT}"
    virsh pool-autostart "${POOL_NAME}"
    virsh pool-start "${POOL_NAME}"
    info "  Storage pool '${POOL_NAME}' created and started"
fi

# Show pool info
virsh pool-info "${POOL_NAME}"

# ── Final summary ──────────────────────────────────────────────────────────────
echo ""
info "KVM host installation complete."
info ""
info "Next steps:"
info "  1. Run: ./hack/setup-libvirt-networks.sh"
info "  2. Run: source ./hack/env.sh  # set CLUSTER_NAME, BASE_DOMAIN, etc."
info "  3. Run: ./hack/setup-dnsmasq.sh"
info "  4. Run: ./hack/configure-route53-dns.sh add"
info "  5. Run: ./hack/configure-haproxy-forwarder.sh"
info "  6. Run: ./hack/verify-dns-resolution.sh"
info "  7. Run: ./hack/deploy-kvm-vms.sh"
if [[ -n "${REAL_USER}" && "${REAL_USER}" != "root" ]]; then
    echo ""
    warn "IMPORTANT: Log out and back in as '${REAL_USER}' before running virsh/virt-install commands"
    warn "           (required for libvirt group membership to take effect)"
fi
