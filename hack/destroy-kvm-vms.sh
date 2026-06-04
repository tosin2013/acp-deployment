#!/usr/bin/env bash
# destroy-kvm-vms.sh — Destroy KVM VMs and clean up DNS for ACP OpenShift cluster
#
# Forked from:
#   https://raw.githubusercontent.com/tosin2013/openshift-agent-install/refs/heads/main/hack/destroy-on-kvm.sh
#
# Adaptations for acp-deployment:
#   - Reads from examples/ibm-cloud-active/extra-vars.yml (not nodes.yml / cluster.yml)
#   - Removes DNS from libvirt network 1925/1926 (not 'default')
#   - Deletes volumes from 'acp-vms' libvirt pool (not flat files in /var/lib/libvirt/images)
#   - Disk naming: <node>-os.qcow2, <node>-odf1.qcow2, <node>-odf2.qcow2
#   - Removes QEMU ISO copy: /var/lib/libvirt/images/agent-acp.x86_64.iso
#   - Optional --route53 flag to remove Route53 external DNS records
#   - Auto-detects provisioning VLAN from examples/ibm-cloud-active symlink
#
# Usage:
#   sudo ./hack/destroy-kvm-vms.sh
#   sudo ./hack/destroy-kvm-vms.sh --config examples/ibm-cloud-active/extra-vars.yml
#   sudo ./hack/destroy-kvm-vms.sh --route53      # also remove Route53 DNS records

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "This script must be run as root (sudo $0)"

# ── Parse arguments ────────────────────────────────────────────────────────────
CONFIG="${REPO_ROOT}/examples/ibm-cloud-active/extra-vars.yml"
REMOVE_ROUTE53=false
POOL="acp-vms"
ISO_QEMU_PATH="/var/lib/libvirt/images/agent-acp.x86_64.iso"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)   CONFIG="$2"; shift 2;;
        --route53)  REMOVE_ROUTE53=true; shift;;
        --pool)     POOL="$2"; shift 2;;
        -h|--help)
            echo "Usage: sudo $0 [--config PATH] [--route53] [--pool NAME]"
            echo "  --config PATH   Path to extra-vars.yml (default: examples/ibm-cloud-active/extra-vars.yml)"
            echo "  --route53       Also remove Route53 external DNS records"
            echo "  --pool NAME     libvirt storage pool (default: acp-vms)"
            exit 0;;
        *) die "Unknown argument: $1";;
    esac
done

[[ -f "${CONFIG}" ]] || die "Config not found: ${CONFIG}"

# ── Require yq ────────────────────────────────────────────────────────────────
command -v yq &>/dev/null || die "yq is required but not installed. Run: sudo snap install yq"

# ── Read cluster config ────────────────────────────────────────────────────────
CLUSTER_NAME=$(yq eval '.openshift.cluster_name' "${CONFIG}" 2>/dev/null)
BASE_DOMAIN=$(yq eval '.openshift.base_domain' "${CONFIG}" 2>/dev/null)
API_VIP=$(yq eval '.openshift.api_address' "${CONFIG}" 2>/dev/null)
INGRESS_VIP=$(yq eval '.openshift.ingress_address' "${CONFIG}" 2>/dev/null)

[[ -n "${CLUSTER_NAME}" && "${CLUSTER_NAME}" != "null" ]] || die "Could not read openshift.cluster_name from ${CONFIG}"
[[ -n "${BASE_DOMAIN}" && "${BASE_DOMAIN}" != "null" ]]   || die "Could not read openshift.base_domain from ${CONFIG}"

# Read node names from openshift.control_nodes[*].name
mapfile -t NODE_NAMES < <(yq eval '.openshift.control_nodes[].name' "${CONFIG}" 2>/dev/null)
[[ ${#NODE_NAMES[@]} -gt 0 ]] || die "Could not read control_nodes[].name from ${CONFIG}"

# ── Auto-detect provisioning VLAN ─────────────────────────────────────────────
if [[ -z "${LIBVIRT_NETWORK:-}" ]]; then
    ACTIVE_LINK=$(readlink -f "${REPO_ROOT}/examples/ibm-cloud-active" 2>/dev/null || echo "")
    if [[ "$ACTIVE_LINK" == *"sno"* ]]; then
        LIBVIRT_NETWORK="1926"
    else
        LIBVIRT_NETWORK="1925"
    fi
fi

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Destroying KVM VMs — ACP OpenShift Cluster           ${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "  Cluster  : ${CLUSTER_NAME}.${BASE_DOMAIN}"
echo -e "  Nodes    : ${NODE_NAMES[*]}"
echo -e "  Network  : ${LIBVIRT_NETWORK}"
echo -e "  Pool     : ${POOL}"
echo -e "  Route53  : ${REMOVE_ROUTE53}"
echo ""

# ── Step 1: Stop background processes ─────────────────────────────────────────
echo -e "${BOLD}[1/5]${NC} Stopping background processes..."
pkill -f "openshift-install agent" 2>/dev/null && info "  openshift-install monitor stopped" || true
pkill -f "watch-and-reboot-kvm-vms" 2>/dev/null && info "  VM watchdog stopped" || true

# ── Step 2: Remove DNS from libvirt network ───────────────────────────────────
echo ""
echo -e "${BOLD}[2/5]${NC} Removing DNS records from libvirt network '${LIBVIRT_NETWORK}'..."

if virsh net-info "${LIBVIRT_NETWORK}" &>/dev/null; then
    if [[ -n "${API_VIP:-}" ]] && [[ "${API_VIP}" != "null" ]]; then
        info "  Removing API DNS host record (${API_VIP})..."
        virsh net-update "${LIBVIRT_NETWORK}" delete dns-host \
            "<host ip='${API_VIP}'/>" --live --config 2>/dev/null || \
            warn "  API host record not found (already clean)"
    fi

    if [[ -n "${INGRESS_VIP:-}" ]] && [[ "${INGRESS_VIP}" != "null" ]]; then
        info "  Removing ingress DNS host record (${INGRESS_VIP})..."
        virsh net-update "${LIBVIRT_NETWORK}" delete dns-host \
            "<host ip='${INGRESS_VIP}'/>" --live --config 2>/dev/null || \
            warn "  Ingress host record not found (already clean)"
    fi

    # Remove wildcard *.apps.* from dnsmasq:options XML if present
    CURRENT_XML=$(virsh net-dumpxml "${LIBVIRT_NETWORK}" 2>/dev/null)
    if echo "${CURRENT_XML}" | grep -q "address=/.apps.${CLUSTER_NAME}.${BASE_DOMAIN}/"; then
        info "  Removing wildcard *.apps.* dnsmasq option from network XML..."
        UPDATED_XML=$(python3 - <<PYEOF
import sys, re
xml = """${CURRENT_XML}"""
# Remove the specific dnsmasq:option line for this cluster
xml = re.sub(r'\s*<dnsmasq:option value="address=/\.apps\.${CLUSTER_NAME}\.${BASE_DOMAIN}/[^"]+"/>\n?', '', xml)
# If dnsmasq:options block is now empty, remove it too
xml = re.sub(r'\s*<dnsmasq:options[^>]*>\s*</dnsmasq:options>\n?', '', xml)
print(xml)
PYEOF
)
        echo "${UPDATED_XML}" > /tmp/libvirt-net-${LIBVIRT_NETWORK}-clean.xml
        virsh net-define /tmp/libvirt-net-${LIBVIRT_NETWORK}-clean.xml
        rm -f /tmp/libvirt-net-${LIBVIRT_NETWORK}-clean.xml
        # SIGHUP dnsmasq to reload (no network restart = no VM disconnection)
        DNSMASQ_PID_FILE="/var/run/libvirt/network/${LIBVIRT_NETWORK}.pid"
        [[ -f "${DNSMASQ_PID_FILE}" ]] && kill -HUP "$(cat "${DNSMASQ_PID_FILE}")" 2>/dev/null || true
        info "  Wildcard *.apps.* removed from network XML"
    else
        info "  No *.apps.* wildcard entry found (already clean)"
    fi
else
    warn "  Network '${LIBVIRT_NETWORK}' not found — skipping DNS cleanup"
fi

# ── Step 3: Destroy VMs ────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[3/5]${NC} Destroying VMs..."
for NODE in "${NODE_NAMES[@]}"; do
    VIRSH_VM=$(virsh list --all | grep " ${NODE} " || true)
    if [[ -n "${VIRSH_VM}" ]]; then
        info "  Destroying ${NODE}..."
        virsh destroy "${NODE}" 2>/dev/null || true
        virsh undefine "${NODE}" --nvram 2>/dev/null || virsh undefine "${NODE}" 2>/dev/null || true
        info "  ${NODE} destroyed and undefined"
    else
        warn "  ${NODE} not found in libvirt — skipping"
    fi
done

# ── Step 4: Delete disk volumes from pool ─────────────────────────────────────
echo ""
echo -e "${BOLD}[4/5]${NC} Deleting disk volumes from pool '${POOL}'..."
if virsh pool-info "${POOL}" &>/dev/null; then
    virsh pool-refresh "${POOL}" 2>/dev/null || true
    for NODE in "${NODE_NAMES[@]}"; do
        for SUFFIX in os odf1 odf2; do
            VOL="${NODE}-${SUFFIX}.qcow2"
            if virsh vol-info "${VOL}" --pool "${POOL}" &>/dev/null; then
                virsh vol-delete "${VOL}" --pool "${POOL}" && info "  Deleted ${VOL}" || warn "  Failed to delete ${VOL}"
            else
                warn "  Volume ${VOL} not found in pool '${POOL}' — skipping"
            fi
        done
    done
else
    warn "  Pool '${POOL}' not found — skipping volume cleanup"
fi

# Remove the QEMU ISO copy
if [[ -f "${ISO_QEMU_PATH}" ]]; then
    rm -f "${ISO_QEMU_PATH}" && info "  Removed QEMU ISO: ${ISO_QEMU_PATH}"
fi

# ── Step 5: Remove Route53 DNS records (optional) ─────────────────────────────
echo ""
echo -e "${BOLD}[5/5]${NC} Route53 DNS cleanup..."
if [[ "${REMOVE_ROUTE53}" == "true" ]]; then
    if [[ -f "${SCRIPT_DIR}/configure-route53-dns.sh" ]]; then
        info "  Running configure-route53-dns.sh delete..."
        # Run as the original non-root user if possible
        ORIG_USER="${SUDO_USER:-vpcuser}"
        su - "${ORIG_USER}" -c "source ${SCRIPT_DIR}/env.sh && bash ${SCRIPT_DIR}/configure-route53-dns.sh delete" || \
            bash "${SCRIPT_DIR}/configure-route53-dns.sh" delete || \
            warn "  Route53 cleanup script failed — remove records manually"
    else
        warn "  configure-route53-dns.sh not found — remove Route53 records manually"
    fi
else
    info "  Skipped (pass --route53 to also remove Route53 records)"
fi

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Cleanup complete.${NC}"
echo -e "  VMs: ${NODE_NAMES[*]} — destroyed"
echo -e "  Volumes: removed from pool '${POOL}'"
echo -e "  DNS: libvirt network '${LIBVIRT_NETWORK}' — cleaned"
echo -e "  Route53: ${REMOVE_ROUTE53}"
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""
echo "  To redeploy:"
echo "    sudo ./hack/deploy-kvm-vms.sh --iso /home/vpcuser/cluster_acp/install/agent.x86_64.iso"
echo ""
