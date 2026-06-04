#!/usr/bin/env bash
# verify-dns-resolution.sh — Mandatory DNS gate before KVM VM deployment
# Usage: ./hack/verify-dns-resolution.sh
#
# Required environment variables (set in hack/env.sh):
#   CLUSTER_NAME   - OpenShift cluster name (e.g., "acp")
#   BASE_DOMAIN    - Base DNS domain (e.g., "example.com")
#   EXTERNAL_IP    - IBM Cloud public IP (used to validate Route53 records)
#   API_VIP        - Internal API VIP (default: 192.168.50.253)
#   INGRESS_VIP    - Internal Ingress VIP (default: 192.168.50.252)
#
# Exit codes:
#   0 — all DNS checks passed; safe to proceed with VM deployment
#   1 — one or more checks failed; fix DNS before deploying VMs
#
# Called automatically by hack/deploy-kvm-vms.sh as a hard prerequisite.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
pass()  { echo -e "  ${GREEN}✓${NC} $*"; }
fail()  { echo -e "  ${RED}✗${NC} $*"; FAILED=$((FAILED + 1)); }
info()  { echo -e "${BOLD}[CHECK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }

: "${CLUSTER_NAME:?ERROR: CLUSTER_NAME is not set. Source hack/env.sh first.}"
: "${BASE_DOMAIN:?ERROR: BASE_DOMAIN is not set. Source hack/env.sh first.}"
: "${EXTERNAL_IP:?ERROR: EXTERNAL_IP is not set. Source hack/env.sh first.}"
# VyOS-first: detect active VLAN network to determine internal DNS gateway
SCRIPT_DIR_VDR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_VDR="$(dirname "${SCRIPT_DIR_VDR}")"
_ACTIVE_LINK=$(readlink -f "${REPO_ROOT_VDR}/examples/ibm-cloud-active" 2>/dev/null || echo "")
if [[ "${_ACTIVE_LINK}" == *"sno"* ]]; then
    API_VIP="${API_VIP:-192.168.51.253}"
    INGRESS_VIP="${INGRESS_VIP:-192.168.51.252}"
    INTERNAL_DNS="${INTERNAL_DNS:-192.168.51.1}"
    _PROV_NET="1926"
else
    API_VIP="${API_VIP:-192.168.50.253}"
    INGRESS_VIP="${INGRESS_VIP:-192.168.50.252}"
    INTERNAL_DNS="${INTERNAL_DNS:-192.168.50.1}"
    _PROV_NET="1925"
fi
EXTERNAL_DNS="8.8.8.8"
ROUTE53_WAIT_SECS=120
FAILED=0

FQDN_API="api.${CLUSTER_NAME}.${BASE_DOMAIN}"
FQDN_API_INT="api-int.${CLUSTER_NAME}.${BASE_DOMAIN}"
FQDN_APPS="test.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}   ACP DNS Verification Gate                           ${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo "  Cluster : ${CLUSTER_NAME}.${BASE_DOMAIN}"
echo "  Internal DNS: ${INTERNAL_DNS} (dnsmasq)"
echo "  External DNS: ${EXTERNAL_DNS} (Google / validates Route53)"
echo ""

# ── Check: VyOS router VM is running (HARD REQUIREMENT — ADR-0019) ────────────
# VyOS is a mandatory prerequisite for all KVM deployments, not just multi-cluster.
# It provides VLAN routing, DNS forwarding, and internet access for cluster VMs.
# See: ADR-0017 (VyOS-first architecture), ADR-0019 (Cockpit/VyOS requirement).
info "VyOS router VM (vyos-router) — hard requirement (ADR-0019)"
_vyos_state=$(sudo virsh domstate vyos-router 2>/dev/null || echo "missing")
if [[ "${_vyos_state}" == "running" ]]; then
    pass "vyos-router VM is running"
else
    fail "vyos-router VM is '${_vyos_state}' — must be running before VM deployment"
    echo ""
    echo -e "${RED}  ── VyOS Router Setup Required ──────────────────────────${NC}"
    echo "  VyOS is a HARD REQUIREMENT for all IBM Cloud KVM deployments."
    echo "  It provides VLAN routing and DNS for OpenShift cluster VMs."
    echo ""
    if [[ "${_vyos_state}" == "shut off" ]]; then
        echo "  Start the existing VM:"
        echo "    sudo virsh start vyos-router"
    elif [[ "${_vyos_state}" == "missing" ]]; then
        echo "  Create and configure VyOS:"
        echo "    1. sudo ACTION=create ./hack/vyos-router.sh"
        echo "    2. Open Cockpit: https://$(hostname -I | awk '{print $1}'):9090"
        echo "    3. Follow: docs/vyos-setup.md"
    fi
    echo ""
    echo "  Reference: ADR-0019 (docs/adrs/adr-0019-cockpit-vyos-console-management.md)"
    echo ""
fi

# ── Check: DNS is listening on the libvirt bridge ─────────────────────────────
# DNS is served by libvirt's built-in dnsmasq on the VyOS VLAN bridge.
# VyOS-first: network is 1925 (converged, 192.168.50.1) or 1926 (SNO, 192.168.51.1).
info "DNS listener on VLAN ${_PROV_NET} bridge (${INTERNAL_DNS}:53)"
if ss -tlnup 2>/dev/null | grep -q "${INTERNAL_DNS}:53"; then
    pass "DNS listener active on ${INTERNAL_DNS}:53 (libvirt dnsmasq on virbr-${_PROV_NET})"
elif virsh net-info "${_PROV_NET}" 2>/dev/null | grep -q "Active:.*yes"; then
    pass "libvirt network ${_PROV_NET} is active (dnsmasq managed by libvirt)"
else
    fail "No DNS listener on ${INTERNAL_DNS}:53. Run: sudo virsh net-start ${_PROV_NET}"
fi

# ── Check: dig is available ────────────────────────────────────────────────────
if ! command -v dig &>/dev/null; then
    echo -e "${RED}[ERROR]${NC} 'dig' not found. Install: sudo dnf install -y bind-utils" >&2
    exit 1
fi

# ── Internal DNS checks (via dnsmasq) ─────────────────────────────────────────
info "Internal DNS (dnsmasq @ ${INTERNAL_DNS})"

check_internal() {
    local fqdn="$1" expected="$2"
    local result
    result=$(dig @"${INTERNAL_DNS}" "${fqdn}" +short 2>/dev/null | head -1 || true)
    if [[ "${result}" == "${expected}" ]]; then
        pass "${fqdn} → ${result}"
    else
        fail "${fqdn} → '${result}' (expected: ${expected})"
        echo "       Fix: Check /etc/dnsmasq.d/acp-cluster.conf and restart dnsmasq"
    fi
}

check_internal "${FQDN_API}"     "${API_VIP}"
check_internal "${FQDN_API_INT}" "${API_VIP}"
check_internal "${FQDN_APPS}"    "${INGRESS_VIP}"

# ── External DNS checks (via Route53 → 8.8.8.8) ───────────────────────────────
info "External DNS (Route53 @ ${EXTERNAL_DNS} — up to ${ROUTE53_WAIT_SECS}s for propagation)"

check_external_with_retry() {
    local fqdn="$1" expected="$2"
    local result attempt=0 max_attempts=$(( ROUTE53_WAIT_SECS / 10 ))
    while [[ ${attempt} -lt ${max_attempts} ]]; do
        result=$(dig @"${EXTERNAL_DNS}" "${fqdn}" +short 2>/dev/null | head -1 || true)
        if [[ "${result}" == "${expected}" ]]; then
            pass "${fqdn} → ${result}"
            return 0
        fi
        attempt=$(( attempt + 1 ))
        if [[ ${attempt} -lt ${max_attempts} ]]; then
            warn "  ${fqdn} returned '${result}' — retrying in 10s (attempt ${attempt}/${max_attempts})..."
            sleep 10
        fi
    done
    fail "${fqdn} → '${result}' after ${ROUTE53_WAIT_SECS}s (expected: ${expected})"
    echo "       Fix: Run ./hack/configure-route53-dns.sh add and verify Route53 records"
}

check_external_with_retry "${FQDN_API}"  "${EXTERNAL_IP}"
check_external_with_retry "${FQDN_APPS}" "${EXTERNAL_IP}"

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
if [[ ${FAILED} -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}   ALL DNS CHECKS PASSED — safe to deploy VMs         ${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
    echo ""
    exit 0
else
    echo -e "${RED}${BOLD}   ${FAILED} DNS CHECK(S) FAILED — fix before deploying VMs ${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Common fixes:"
    echo "  Internal DNS    : sudo -E ./hack/setup-dnsmasq.sh  (targets VLAN ${_PROV_NET})"
    echo "  Route53 issues  : ./hack/configure-route53-dns.sh add"
    echo "  Check dnsmasq   : virsh net-dumpxml ${_PROV_NET} | grep -A5 dns"
    echo "  Check propagation: dig @8.8.8.8 ${FQDN_API} +short"
    echo ""
    exit 1
fi
