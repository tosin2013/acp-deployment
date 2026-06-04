#!/usr/bin/env bash
# setup-dnsmasq.sh — Inject cluster DNS records into libvirt's built-in dnsmasq
#
# Usage: sudo ./hack/setup-dnsmasq.sh
#
# Required environment variables (set in hack/env.sh):
#   CLUSTER_NAME   - OpenShift cluster name (e.g., "acp")
#   BASE_DOMAIN    - Base DNS domain (e.g., "example.com")
#   API_VIP        - API server VIP (default: auto from active topology)
#   INGRESS_VIP    - Ingress VIP (default: auto from active topology)
#
# VyOS-first networking — active VLAN auto-detection:
#   examples/ibm-cloud-active → ibm-cloud-converged  ⟹  NETWORK=1925, gateway 192.168.50.1
#   examples/ibm-cloud-active → ibm-cloud-sno        ⟹  NETWORK=1926, gateway 192.168.51.1
#   Override: export LIBVIRT_NETWORK=<network-name>
#
# Why this approach (libvirt network DNS, not a separate dnsmasq service):
#   libvirt already runs its own dnsmasq on the VLAN gateway for the provisioning network.
#   A second dnsmasq service cannot bind to the same address/port. Instead, we inject
#   cluster DNS records directly into libvirt's dnsmasq via:
#   - virsh net-update: adds static host A records (api.*, api-int.*) — live, no restart
#   - dnsmasq:options XML extension: adds the wildcard *.apps.* address entry
#   Then we SIGHUP the dnsmasq process to reload config (never net-destroy while VMs run).

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "This script must be run as root (sudo $0)"

: "${CLUSTER_NAME:?ERROR: CLUSTER_NAME is not set. Source hack/env.sh first.}"
: "${BASE_DOMAIN:?ERROR: BASE_DOMAIN is not set. Source hack/env.sh first.}"

# Auto-detect active VLAN network from topology symlink (VyOS-first)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
if [[ -z "${LIBVIRT_NETWORK:-}" ]]; then
    ACTIVE_LINK=$(readlink -f "${REPO_ROOT}/examples/ibm-cloud-active" 2>/dev/null || echo "")
    if [[ "$ACTIVE_LINK" == *"sno"* ]]; then
        LIBVIRT_NETWORK="1926"
        GW_IP="192.168.51.1"
        API_VIP="${API_VIP:-192.168.51.253}"
        INGRESS_VIP="${INGRESS_VIP:-192.168.51.252}"
    else
        LIBVIRT_NETWORK="1925"
        GW_IP="192.168.50.1"
        API_VIP="${API_VIP:-192.168.50.253}"
        INGRESS_VIP="${INGRESS_VIP:-192.168.50.252}"
    fi
else
    # Derive gateway from network name (e.g., 1925 → 192.168.50.1)
    case "${LIBVIRT_NETWORK}" in
        1925) GW_IP="192.168.50.1"; API_VIP="${API_VIP:-192.168.50.253}"; INGRESS_VIP="${INGRESS_VIP:-192.168.50.252}" ;;
        1926) GW_IP="192.168.51.1"; API_VIP="${API_VIP:-192.168.51.253}"; INGRESS_VIP="${INGRESS_VIP:-192.168.51.252}" ;;
        *)    GW_IP="${GW_IP:?ERROR: GW_IP must be set for custom LIBVIRT_NETWORK=${LIBVIRT_NETWORK}}" ;;
    esac
fi
NETWORK="${LIBVIRT_NETWORK}"

FQDN_API="api.${CLUSTER_NAME}.${BASE_DOMAIN}"
FQDN_API_INT="api-int.${CLUSTER_NAME}.${BASE_DOMAIN}"
FQDN_APPS_WILD=".apps.${CLUSTER_NAME}.${BASE_DOMAIN}"

info "Injecting cluster DNS into libvirt network '${NETWORK}' (gateway: ${GW_IP})"
info "  ${FQDN_API}     → ${API_VIP}"
info "  ${FQDN_API_INT} → ${API_VIP}"
info "  *.apps.${CLUSTER_NAME}.${BASE_DOMAIN} → ${INGRESS_VIP}"

# ── Verify the libvirt network exists ─────────────────────────────────────────
virsh net-info "${NETWORK}" &>/dev/null || \
    die "libvirt network '${NETWORK}' not found. Run: sudo ./hack/vyos-router.sh"

# ── Step 1: Add host A records via virsh net-update ───────────────────────────
# Remove existing records for this cluster first (idempotent re-runs)
EXISTING_HOST=$(virsh net-dumpxml "${NETWORK}" 2>/dev/null | grep -o "ip='${API_VIP}'" | head -1 || true)
if [[ -n "${EXISTING_HOST}" ]]; then
    info "Removing existing DNS host record for ${API_VIP} (idempotent re-run)..."
    virsh net-update "${NETWORK}" delete dns-host \
        "<host ip='${API_VIP}'/>" --live --config 2>/dev/null || true
fi

info "Adding DNS host records (api.*, api-int.*)..."
virsh net-update "${NETWORK}" add dns-host \
    "<host ip='${API_VIP}'><hostname>${FQDN_API}</hostname><hostname>${FQDN_API_INT}</hostname></host>" \
    --live --config

info "Adding DNS host record for ingress VIP..."
EXISTING_INGRESS=$(virsh net-dumpxml "${NETWORK}" 2>/dev/null | grep -o "ip='${INGRESS_VIP}'" | head -1 || true)
if [[ -n "${EXISTING_INGRESS}" ]]; then
    virsh net-update "${NETWORK}" delete dns-host \
        "<host ip='${INGRESS_VIP}'/>" --live --config 2>/dev/null || true
fi
virsh net-update "${NETWORK}" add dns-host \
    "<host ip='${INGRESS_VIP}'><hostname>ingress.${CLUSTER_NAME}.${BASE_DOMAIN}</hostname></host>" \
    --live --config

# ── Step 2: Inject wildcard *.apps via dnsmasq:options in network XML ─────────
# virsh net-update cannot add wildcard records — we must edit the XML directly.
info "Injecting wildcard *.apps.* DNS record via dnsmasq:options XML extension..."

CURRENT_XML=$(virsh net-dumpxml "${NETWORK}" 2>/dev/null)

# Check if dnsmasq:options already present for this cluster
if echo "${CURRENT_XML}" | grep -q "address=/${FQDN_APPS_WILD}/"; then
    info "  Wildcard entry already present — skipping"
else
    # Build the updated XML using Python (no xmlstarlet dependency)
    python3 - <<PYEOF
import sys

xml_in = """${CURRENT_XML}"""

dnsmasq_block = """  <dnsmasq:options xmlns:dnsmasq="http://libvirt.org/schemas/network/dnsmasq/1.0">
    <dnsmasq:option value="address=/${FQDN_APPS_WILD}/${INGRESS_VIP}"/>
  </dnsmasq:options>"""

if "dnsmasq:options" in xml_in:
    print("dnsmasq:options block already exists — not injecting", file=sys.stderr)
    print(xml_in)
else:
    updated = xml_in.rstrip().rstrip("</network>").rstrip() + "\n" + dnsmasq_block + "\n</network>\n"
    print(updated)
PYEOF
    UPDATED_XML=$(python3 - <<PYEOF
import sys

xml_in = """${CURRENT_XML}"""

dnsmasq_block = """  <dnsmasq:options xmlns:dnsmasq="http://libvirt.org/schemas/network/dnsmasq/1.0">
    <dnsmasq:option value="address=/${FQDN_APPS_WILD}/${INGRESS_VIP}"/>
  </dnsmasq:options>"""

if "dnsmasq:options" in xml_in:
    print(xml_in)
else:
    # Strip trailing whitespace and the closing </network> tag, append dnsmasq block
    lines = xml_in.rstrip().splitlines()
    # Remove last </network> line
    while lines and lines[-1].strip() == "</network>":
        lines.pop()
    updated = "\n".join(lines) + "\n" + dnsmasq_block + "\n</network>"
    print(updated)
PYEOF
)

    echo "${UPDATED_XML}" > /tmp/libvirt-net-${NETWORK}-updated.xml
    virsh net-define /tmp/libvirt-net-${NETWORK}-updated.xml
    rm -f /tmp/libvirt-net-${NETWORK}-updated.xml
    info "  Wildcard *.apps.* → ${INGRESS_VIP} injected into network XML"
fi

# ── Step 3: Reload dnsmasq — SIGHUP to avoid disconnecting running VMs ───────
# NEVER use virsh net-destroy on a network with running VMs: it tears down the
# bridge and detaches all vnet interfaces, making VMs unreachable.
# SIGHUP reloads the dnsmasq conf files that libvirt writes from the XML.
info "Reloading dnsmasq for network '${NETWORK}' (SIGHUP — bridge stays up)..."
DNSMASQ_PID=""
for pidfile in "/var/run/libvirt/network/${NETWORK}.pid" "/run/libvirt/network/${NETWORK}.pid"; do
    [[ -f "${pidfile}" ]] && { DNSMASQ_PID=$(cat "${pidfile}"); break; }
done
if [[ -n "${DNSMASQ_PID}" ]]; then
    kill -HUP "${DNSMASQ_PID}" && info "  dnsmasq pid ${DNSMASQ_PID} — SIGHUP sent, config reloaded"
else
    # Fallback: only restart if no VMs have active connections
    ACTIVE_IFACES=$(ip link show | grep -c "master virbr-${NETWORK#*-}" 2>/dev/null || true)
    if [[ "${ACTIVE_IFACES}" -eq 0 ]]; then
        info "  No VMs attached — restarting network '${NETWORK}' to reload dnsmasq..."
        virsh net-destroy "${NETWORK}" 2>/dev/null && sleep 1
        virsh net-start "${NETWORK}"
        info "  Network restarted"
    else
        warn "  VMs attached to bridge — skipping network restart to preserve connectivity"
        warn "  Wildcard *.apps.* record is in persistent XML but dnsmasq not hot-reloaded"
        warn "  It will take effect after next planned network restart (e.g. host reboot)"
    fi
fi

# ── Step 4: Validate ──────────────────────────────────────────────────────────
info "Waiting 2s for dnsmasq to settle..."
sleep 2

if command -v dig &>/dev/null; then
    echo ""
    info "Validating DNS records via ${GW_IP}..."
    RESULT_API=$(dig @"${GW_IP}" "${FQDN_API}" +short 2>/dev/null | head -1 || true)
    RESULT_INT=$(dig @"${GW_IP}" "${FQDN_API_INT}" +short 2>/dev/null | head -1 || true)
    RESULT_APPS=$(dig @"${GW_IP}" "test${FQDN_APPS_WILD}" +short 2>/dev/null | head -1 || true)

    [[ "${RESULT_API}" == "${API_VIP}" ]] && \
        echo -e "  ${GREEN}✓${NC} ${FQDN_API} → ${RESULT_API}" || \
        echo -e "  ${RED}✗${NC} ${FQDN_API} → '${RESULT_API}' (expected ${API_VIP})"

    [[ "${RESULT_INT}" == "${API_VIP}" ]] && \
        echo -e "  ${GREEN}✓${NC} ${FQDN_API_INT} → ${RESULT_INT}" || \
        echo -e "  ${RED}✗${NC} ${FQDN_API_INT} → '${RESULT_INT}' (expected ${API_VIP})"

    [[ "${RESULT_APPS}" == "${INGRESS_VIP}" ]] && \
        echo -e "  ${GREEN}✓${NC} test${FQDN_APPS_WILD} → ${RESULT_APPS}" || \
        echo -e "  ${RED}✗${NC} test${FQDN_APPS_WILD} → '${RESULT_APPS}' (expected ${INGRESS_VIP})"
fi

echo ""
info "dnsmasq setup complete."
info "Next: Run ./hack/configure-route53-dns.sh add"
