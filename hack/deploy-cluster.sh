#!/usr/bin/env bash
# =============================================================================
# hack/deploy-cluster.sh
# =============================================================================
# Master cluster deployment orchestrator for IBM Cloud KVM ACP.
#
# Deployment order (matches upstream developer guide):
#   1.  setup-cluster-vars.sh          — populate pull secret + SSH key
#   2.  vyos-router.sh                 — create VLAN networks + VyOS VM (HARD REQUIREMENT — ADR-0019)
#   3.  select-cluster-topology.sh     — set ibm-cloud-active symlink
#   4.  configure-haproxy-forwarder.sh — configure + start HAProxy
#   5.  configure-route53-dns.sh add   — create Route53 A records
#   6.  generate-kvm-macs.sh           — pre-fill MAC addresses before ISO generation
#   7.  setup-dnsmasq.sh               — inject cluster DNS into VLAN dnsmasq
#   8.  verify-dns-resolution.sh       — DNS gate (hard stop on failure)
#   9.  create-installation-media.yml  — generate agent ISO (MACs are already valid)
#   10. deploy-kvm-vms.sh              — create KVM VMs with pre-assigned MACs
#   11. openshift-install agent wait-for install-complete
#   12. configure-converged-scheduling.sh — enable workload scheduling (converged)
#   13. site-post-install.yml          — ODF, Pipelines, AAP, OCP Virt
#
# Why this order matters:
#   openshift-install validates MAC addresses at ISO generation time.
#   Step 6 pre-generates MACs so the ISO (step 9) is valid on the first pass.
#   deploy-kvm-vms.sh (step 10) passes those same MACs to virt-install, so VMs
#   match the ISO exactly — no two-pass regeneration needed.
#
# Usage:
#   source hack/env.sh   # load CLUSTER_NAME, BASE_DOMAIN, EXTERNAL_IP, HOSTED_ZONE_ID
#   ./hack/deploy-cluster.sh [flags]
#
# Flags:
#   --topology converged|sno    Force topology (default: auto-detect from host resources)
#   --ocp-virt                  Apply OCP Virt RAM thresholds to topology selection
#   --skip-haproxy              Skip HAProxy configuration (already running)
#   --skip-route53              Skip Route53 DNS record creation (already configured)
#   --skip-post-install         Exit after install-complete; run playbooks manually
#   --skip-cert-manager         Pass -e skip_cert_manager=true to site-post-install.yml
#
# Idempotency:
#   Safe to re-run. Each step checks whether it has already been completed.
#   VMs, networks, DNS records, and MACs are only created/generated once.
#
# Prerequisites:
#   - source hack/env.sh (CLUSTER_NAME, BASE_DOMAIN, EXTERNAL_IP, HOSTED_ZONE_ID)
#   - ~/pull-secret.json from https://console.redhat.com/openshift/install/pull-secret
#   - ~/.aws/credentials with Route53 write permissions
#   - sudo privileges for libvirt and HAProxy steps
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

# ── Colors and helpers ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; CYAN='\033[0;36m'; NC='\033[0m'
info()   { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()    { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
skip()   { echo -e "${CYAN}[SKIP]${NC}  $*"; }

banner() {
    local msg="$1"
    echo ""
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  $(date '+%H:%M:%S')  ${msg}${NC}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"
    echo ""
}

# ── Parse flags ───────────────────────────────────────────────────────────────
FORCE_TOPOLOGY=""
OCP_VIRT=false
SKIP_HAPROXY=false
SKIP_ROUTE53=false
SKIP_POST_INSTALL=false
SKIP_CERT_MANAGER=false

usage() {
    cat <<EOF
Usage: source hack/env.sh && ./hack/deploy-cluster.sh [flags]

Flags:
  --topology converged|sno   Force topology (default: auto-detect from host resources)
  --ocp-virt                 Apply OCP Virt RAM thresholds to topology selection
  --skip-haproxy             Skip HAProxy configuration (already running)
  --skip-route53             Skip Route53 DNS record creation (already configured)
  --skip-post-install        Stop after install-complete; run playbooks manually
  --skip-cert-manager        Pass -e skip_cert_manager=true to site-post-install
  --help                     Show this help

HARD REQUIREMENTS (enforced by verify-dns-resolution.sh before VM creation):
  - VyOS router VM must be running (ADR-0019)
  - VLAN networks 1924/1925/1926/acp-storage must exist (ADR-0017)
  - Internal DNS (dnsmasq) and external DNS (Route53) must both resolve correctly (ADR-0018)

VyOS reference:
  https://tosin2013.github.io/openshift-agent-install/vyos-manual-configuration.html
  docs/vyos-setup.md
  docs/adrs/adr-0019-cockpit-vyos-console-management.md
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --topology)          FORCE_TOPOLOGY="ibm-cloud-$2"; shift 2 ;;
        --ocp-virt)          OCP_VIRT=true; shift ;;
        --vyos-vm)           echo "[WARN] --vyos-vm is no longer needed; VyOS VM is always required (ADR-0019)." >&2; shift ;;
        --skip-haproxy)      SKIP_HAPROXY=true; shift ;;
        --skip-route53)      SKIP_ROUTE53=true; shift ;;
        --skip-post-install) SKIP_POST_INSTALL=true; shift ;;
        --skip-cert-manager) SKIP_CERT_MANAGER=true; shift ;;
        --help|-h)           usage; exit 0 ;;
        *) die "Unknown argument: $1\nRun: $0 --help" ;;
    esac
done

# ── Ensure we run from repo root ───────────────────────────────────────────────
cd "${REPO_ROOT}"

# ── Source env.sh ─────────────────────────────────────────────────────────────
# shellcheck source=hack/env.sh
source hack/env.sh

# ── Validate required environment variables ────────────────────────────────────
for _var in CLUSTER_NAME BASE_DOMAIN EXTERNAL_IP HOSTED_ZONE_ID; do
    _val="${!_var:-}"
    if [[ -z "${_val}" || "${_val}" == "<"*">" ]]; then
        die "${_var} is not set or is still a placeholder.
  Edit hack/env.sh and export real values before running this script."
    fi
done

# ── Validate prerequisites ─────────────────────────────────────────────────────
[[ -f "${HOME}/pull-secret.json" ]] || \
    die "~/pull-secret.json not found.
  Download from: https://console.redhat.com/openshift/install/pull-secret"

command -v ansible-playbook &>/dev/null || \
    die "ansible-playbook not found. Run: sudo ./hack/bootstrap.sh"

command -v openshift-install &>/dev/null || \
    die "openshift-install not found. Run: sudo ./hack/bootstrap.sh"

command -v virsh &>/dev/null || \
    die "virsh not found. Run: sudo ./hack/bootstrap.sh"

# ── Welcome banner ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   ACP Cluster Deployment — IBM Cloud KVM             ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║  Cluster : ${CLUSTER_NAME}.${BASE_DOMAIN}${NC}"
echo -e "${BOLD}║  Host IP : ${EXTERNAL_IP}${NC}"
echo -e "${BOLD}║  VyOS VM : required — Cockpit config at https://${EXTERNAL_IP}:9090${NC}"
[[ "${SKIP_HAPROXY}" == "true" ]]      && echo -e "${BOLD}║  HAProxy : skip${NC}"
[[ "${SKIP_ROUTE53}" == "true" ]]      && echo -e "${BOLD}║  Route53 : skip${NC}"
[[ "${SKIP_POST_INSTALL}" == "true" ]] && echo -e "${BOLD}║  Post-install: skip${NC}"
[[ "${SKIP_CERT_MANAGER}" == "true" ]] && echo -e "${BOLD}║  cert-manager: skip${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

ACTIVE_EXAMPLE="examples/ibm-cloud-active"

# =============================================================================
# STEP 1 — Populate cluster variables
# =============================================================================
banner "Step 1/13 — Populating cluster variables"

_PULL_SECRET_WRITTEN=$(grep -c "pull_secret: ''" examples/ibm-cloud-converged/extra-vars.yml 2>/dev/null || true)
if [[ "${_PULL_SECRET_WRITTEN}" -gt 0 ]]; then
    info "Running setup-cluster-vars.sh..."
    ./hack/setup-cluster-vars.sh
else
    skip "Cluster vars already populated (pull_secret is set)"
fi

# =============================================================================
# STEP 2 — Create VyOS VLAN networks + VyOS router VM (HARD REQUIREMENT — ADR-0019)
# =============================================================================
banner "Step 2/13 — Creating VyOS VLAN networks + VyOS router VM (mandatory)"
warn "VyOS router is a HARD REQUIREMENT for all IBM Cloud KVM deployments (ADR-0019)."
warn "After network creation, you MUST configure the VyOS VM via Cockpit:"
warn "  1. Open: https://${EXTERNAL_IP}:9090"
warn "  2. Virtual Machines → vyos-router → Console"
warn "  3. Follow: docs/vyos-setup.md  (~10-15 min)"
warn "  hack/verify-dns-resolution.sh will fail if vyos-router is not running."
ACTION=create ./hack/vyos-router.sh
info "VyOS router VM created. Complete Cockpit configuration before proceeding."

# =============================================================================
# STEP 3 — Select cluster topology
# =============================================================================
banner "Step 3/13 — Selecting cluster topology"

if [[ -n "${FORCE_TOPOLOGY}" ]]; then
    FORCE_TOPOLOGY="${FORCE_TOPOLOGY}" OPENSHIFT_VIRT="${OCP_VIRT}" \
        ./hack/select-cluster-topology.sh
elif [[ "${OCP_VIRT}" == "true" ]]; then
    OPENSHIFT_VIRT=true ./hack/select-cluster-topology.sh
else
    ./hack/select-cluster-topology.sh
fi

ACTIVE_LINK=$(readlink -f "${ACTIVE_EXAMPLE}" 2>/dev/null || echo "")
if [[ "${ACTIVE_LINK}" == *"converged"* ]]; then
    IS_CONVERGED=true
    TOPOLOGY_NAME="converged"
else
    IS_CONVERGED=false
    TOPOLOGY_NAME="sno"
fi
info "Active topology: ${TOPOLOGY_NAME} → ${ACTIVE_LINK}"

# =============================================================================
# STEP 4 — Configure HAProxy
# =============================================================================
banner "Step 4/13 — Configuring HAProxy external access"

if [[ "${SKIP_HAPROXY}" == "true" ]]; then
    skip "--skip-haproxy set — skipping HAProxy configuration"
    systemctl is-active haproxy &>/dev/null || \
        warn "HAProxy is NOT running. External API/ingress access will fail."
else
    sudo -E "${SCRIPT_DIR}/configure-haproxy-forwarder.sh"
fi

# =============================================================================
# STEP 5 — Route53 DNS records
# =============================================================================
banner "Step 5/13 — Creating Route53 external DNS records"

if [[ "${SKIP_ROUTE53}" == "true" ]]; then
    skip "--skip-route53 set — skipping Route53 DNS creation"
else
    "${SCRIPT_DIR}/configure-route53-dns.sh" add
fi

# =============================================================================
# STEP 6 — Pre-generate KVM MAC addresses
# =============================================================================
banner "Step 6/13 — Pre-generating KVM MAC addresses"

# MACs must be known before ISO generation so openshift-install receives valid values.
# generate-kvm-macs.sh is idempotent — skips if MACs are already filled.
"${SCRIPT_DIR}/generate-kvm-macs.sh" "${ACTIVE_EXAMPLE}/extra-vars.yml"

# =============================================================================
# STEP 7 — Internal DNS setup
# =============================================================================
banner "Step 7/13 — Injecting cluster DNS into VLAN ${TOPOLOGY_NAME} dnsmasq"

sudo -E "${SCRIPT_DIR}/setup-dnsmasq.sh"

# =============================================================================
# STEP 8 — DNS verification gate (HARD STOP)
# =============================================================================
banner "Step 8/13 — DNS verification gate"

"${SCRIPT_DIR}/verify-dns-resolution.sh" || \
    die "DNS verification failed. Fix the issues above and re-run.
  Internal DNS : sudo -E ./hack/setup-dnsmasq.sh
  External DNS : ./hack/configure-route53-dns.sh add"

# =============================================================================
# STEP 9 — Generate agent ISO (MACs are now valid)
# =============================================================================
banner "Step 9/13 — Generating agent ISO"

INSTALL_DIR="${HOME}/cluster_${CLUSTER_NAME}/install"
ISO_PATH="${INSTALL_DIR}/agent.x86_64.iso"

# MACs were pre-generated in Step 6 — openshift-install will accept them.
# The ISO is idempotent if the install dir already has a fresh agent.x86_64.iso.
ansible-playbook playbooks/create-installation-media.yml \
    -i "${ACTIVE_EXAMPLE}/inventory.yml" \
    -e "@${ACTIVE_EXAMPLE}/extra-vars.yml"

info "Agent ISO generated: ${ISO_PATH}"

# =============================================================================
# STEP 10 — Deploy KVM VMs with pre-assigned MACs
# =============================================================================
banner "Step 10/13 — Creating KVM VMs"

# deploy-kvm-vms.sh reads MACs from extra-vars.yml and passes them to virt-install
# so the VMs get exactly the same MACs that are embedded in the ISO.
# Idempotency: skips existing VMs.
"${SCRIPT_DIR}/deploy-kvm-vms.sh"

# =============================================================================
# STEP 11 — Wait for cluster installation to complete
# =============================================================================
# Start the VM auto-reboot watcher in the background BEFORE wait-for-complete.
# The Agent-Based Installer shuts VMs down after writing RHCOS to disk; they
# do not self-reboot. Without this watcher the installation hangs.
banner "Step 11/13 — Waiting for cluster installation to complete"

WATCHER_LOG="/tmp/vm-watcher-${CLUSTER_NAME}.log"
info "Starting VM auto-reboot watcher in background (log: ${WATCHER_LOG})"
"${SCRIPT_DIR}/watch-and-reboot-kvm-vms.sh" \
    --config "${ACTIVE_EXAMPLE}/extra-vars.yml" \
    --timeout 7200 \
    > "${WATCHER_LOG}" 2>&1 &
WATCHER_PID=$!
info "  Watcher PID: ${WATCHER_PID}"
export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"

_CLUSTER_UP=false
if [[ -f "${KUBECONFIG}" ]]; then
    if oc get nodes --request-timeout=10s &>/dev/null 2>&1; then
        _CLUSTER_UP=true
    fi
fi

if [[ "${_CLUSTER_UP}" == "true" ]]; then
    skip "Cluster already installed and API is responding"
    oc get nodes
    kill "${WATCHER_PID}" 2>/dev/null || true
else
    info "Installation typically takes 45–90 minutes."
    info "kubeconfig will be written to: ${KUBECONFIG}"
    info "VM reboot watcher running (PID ${WATCHER_PID}) — do not kill it"
    echo ""
    openshift-install agent wait-for install-complete \
        --dir "${INSTALL_DIR}" --log-level=info
fi
# Stop the watcher once install is complete
kill "${WATCHER_PID}" 2>/dev/null || true

# =============================================================================
# STEP 12 — Enable workload scheduling (converged only)
# =============================================================================
if [[ "${IS_CONVERGED}" == "true" ]]; then
    banner "Step 12/13 — Enabling workload scheduling on control nodes"
    "${SCRIPT_DIR}/configure-converged-scheduling.sh"
else
    banner "Step 12/13 — Workload scheduling (SNO — skipping)"
    skip "SNO topology — control node is already schedulable"
fi

# =============================================================================
# STEP 13 — Post-install playbooks
# =============================================================================
if [[ "${SKIP_POST_INSTALL}" == "true" ]]; then
    banner "Step 13/13 — Post-install playbooks (SKIPPED)"
    skip "--skip-post-install set"
    echo ""
    echo "  Run manually when ready:"
    echo ""
    echo "    export KUBECONFIG=${KUBECONFIG}"
    echo "    export AWS_ACCESS_KEY_ID=\$(aws configure get aws_access_key_id)"
    echo "    export AWS_SECRET_ACCESS_KEY=\$(aws configure get aws_secret_access_key)"
    echo ""
    EXTRA_ARGS=""
    [[ "${SKIP_CERT_MANAGER}" == "true" ]] && EXTRA_ARGS=" \\"$'\n'"      -e skip_cert_manager=true"
    echo "    ansible-playbook playbooks/site-post-install.yml \\"
    echo "      -i ${ACTIVE_EXAMPLE}/inventory.yml \\"
    echo "      -e @${ACTIVE_EXAMPLE}/extra-vars.yml${EXTRA_ARGS}"
    echo ""
else
    banner "Step 13/13 — Running post-install playbooks"

    export AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY
    AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id 2>/dev/null) || \
        die "AWS credentials not found. Configure ~/.aws/credentials first."
    AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key 2>/dev/null) || \
        die "AWS secret key not found. Configure ~/.aws/credentials first."

    PLAYBOOK_EXTRA_ARGS=""
    if [[ "${SKIP_CERT_MANAGER}" == "true" ]]; then
        PLAYBOOK_EXTRA_ARGS="-e skip_cert_manager=true"
        warn "cert-manager skipped — set zerossl_account credentials in extra-vars.yml then run:"
        warn "  ansible-playbook playbooks/update-ocp-ingress-cert.yml \\"
        warn "    -i ${ACTIVE_EXAMPLE}/inventory.yml -e @${ACTIVE_EXAMPLE}/extra-vars.yml"
    fi

    # shellcheck disable=SC2086
    ansible-playbook playbooks/site-post-install.yml \
        -i "${ACTIVE_EXAMPLE}/inventory.yml" \
        -e "@${ACTIVE_EXAMPLE}/extra-vars.yml" \
        ${PLAYBOOK_EXTRA_ARGS}
fi

# =============================================================================
# Final summary
# =============================================================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Deployment Complete                                ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║  Cluster : ${CLUSTER_NAME}.${BASE_DOMAIN}${NC}"
echo -e "${BOLD}║  API     : https://api.${CLUSTER_NAME}.${BASE_DOMAIN}:6443${NC}"
echo -e "${BOLD}║  Console : https://console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  kubeconfig : ${KUBECONFIG}"
echo "  Password   : cat ${INSTALL_DIR}/auth/kubeadmin-password"
echo ""
info "Verify: oc get nodes && oc get co"
echo ""
