#!/usr/bin/env bash
# setup-libvirt-networks.sh — Create acp-storage libvirt NAT network
# Usage: sudo ./hack/setup-libvirt-networks.sh
#
# DEPRECATED for provisioning networks: VyOS-first architecture adopted.
#   Provisioning VLANs (1924/1925/1926) are now created by hack/vyos-router.sh.
#   Run hack/vyos-router.sh instead of this script for provisioning network setup.
#
# This script now creates ONLY:
#   acp-storage  192.168.52.0/24  — ODF Multus storage network (still needed separately)

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "This script must be run as root (sudo $0)"

# ── Network definitions ────────────────────────────────────────────────────────
define_network() {
    local name="$1"
    local bridge="$2"
    local cidr="$3"
    local gw="$4"
    local dhcp_start="$5"
    local dhcp_end="$6"

    if virsh net-info "${name}" &>/dev/null; then
        warn "Network '${name}' already exists. Skipping."
        return
    fi

    info "Creating libvirt network '${name}' (${cidr})..."

    cat > "/tmp/libvirt-net-${name}.xml" <<EOF
<network>
  <name>${name}</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='${bridge}' stp='on' delay='0'/>
  <ip address='${gw}' netmask='255.255.255.0'>
    <dhcp>
      <range start='${dhcp_start}' end='${dhcp_end}'/>
    </dhcp>
  </ip>
</network>
EOF

    virsh net-define "/tmp/libvirt-net-${name}.xml"
    virsh net-autostart "${name}"
    virsh net-start "${name}"
    rm -f "/tmp/libvirt-net-${name}.xml"
    info "  Network '${name}' created and started"
}

# acp-storage: ODF Multus storage network (no DHCP needed — static IPs via nmstate)
# NOTE: acp-provisioning is no longer created here.
#       Run hack/vyos-router.sh to create VLAN 1925 (converged) or 1926 (SNO).
define_network "acp-storage" "virbr-acp2" "192.168.52.0/24" \
    "192.168.52.1" "192.168.52.10" "192.168.52.50"

# ── Show results ───────────────────────────────────────────────────────────────
echo ""
info "Libvirt networks configured:"
virsh net-list --all
echo ""
info "Bridge interfaces:"
ip -br addr show | grep -E "virbr-acp" || warn "Bridge interfaces not yet visible (may need a moment)"
echo ""
info "acp-storage network setup complete."
warn "Provisioning VLANs (1924/1925/1926) are managed by hack/vyos-router.sh — run that first."
info "Next: Run ./hack/setup-dnsmasq.sh to configure internal cluster DNS"
