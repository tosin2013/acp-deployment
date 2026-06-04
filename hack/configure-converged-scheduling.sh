#!/usr/bin/env bash
# =============================================================================
# hack/configure-converged-scheduling.sh
# =============================================================================
# Enables workload scheduling on converged control-plane nodes.
#
# On a standard OpenShift installation, control-plane nodes carry a
# NoSchedule taint that prevents user workloads (and operators like
# OpenShift Virtualization) from scheduling there. On a converged cluster
# (where control nodes ARE the workers), this taint must be removed.
#
# This script:
#   1. Patches the OpenShift Scheduler CR to set mastersSchedulable: true
#   2. Waits for all cluster operators to reach Available state
#   3. Verifies no control nodes still carry the NoSchedule taint
#
# Prerequisites:
#   - KUBECONFIG must point to a healthy converged cluster
#   - oc CLI must be in PATH
#
# Usage:
#   source hack/env.sh   # sets CLUSTER_NAME
#   ./hack/configure-converged-scheduling.sh
#
# Safe to re-run — idempotent.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

: "${CLUSTER_NAME:?ERROR: CLUSTER_NAME is not set. Source hack/env.sh first.}"

# ── Locate kubeconfig ──────────────────────────────────────────────────────────
KUBECONFIG="${KUBECONFIG:-${HOME}/cluster_${CLUSTER_NAME}/install/auth/kubeconfig}"
export KUBECONFIG

if [[ ! -f "${KUBECONFIG}" ]]; then
    die "kubeconfig not found at ${KUBECONFIG}
  Ensure the cluster has finished installing:
    openshift-install agent wait-for install-complete \\
      --dir ~/cluster_${CLUSTER_NAME}/install --log-level=info"
fi

# ── Verify oc is available ────────────────────────────────────────────────────
command -v oc &>/dev/null || die "oc CLI not found in PATH. Install OpenShift CLI first."

# ── Check cluster is reachable ────────────────────────────────────────────────
info "Checking cluster connectivity..."
oc cluster-info --kubeconfig "${KUBECONFIG}" &>/dev/null || \
    die "Cannot reach cluster API. Check KUBECONFIG and cluster health."

# ── Step 1: Patch scheduler for mastersSchedulable ────────────────────────────
CURRENT_SCHED=$(oc get scheduler cluster -o jsonpath='{.spec.mastersSchedulable}' 2>/dev/null || echo "false")

if [[ "${CURRENT_SCHED}" == "true" ]]; then
    info "Scheduler already has mastersSchedulable: true — skipping patch"
else
    info "Patching OpenShift scheduler: mastersSchedulable → true"
    oc patch scheduler cluster --type=merge \
        -p '{"spec":{"mastersSchedulable":true}}'
    info "  Scheduler patched"
fi

# ── Step 2: Wait for cluster operators to stabilize ───────────────────────────
echo ""
info "Waiting for all cluster operators to become Available (timeout: 15m)..."
info "  This may take several minutes after the scheduler change."
oc wait clusteroperators --all \
    --for=condition=Available=True \
    --timeout=15m || {
    warn "Some cluster operators are not yet Available. Current status:"
    oc get co
    warn "The scheduler change was applied. Operators may still be reconciling."
    warn "Re-run this script in a few minutes or check: oc get co"
    exit 1
}
info "  All cluster operators are Available"

# ── Step 3: Verify no control nodes have NoSchedule master taint ──────────────
echo ""
info "Verifying control nodes are schedulable..."
TAINTED_NODES=$(oc get nodes -l node-role.kubernetes.io/master \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.taints[*].effect}{"\n"}{end}' \
    2>/dev/null | grep -i "NoSchedule" || true)

if [[ -n "${TAINTED_NODES}" ]]; then
    warn "Some control nodes still have NoSchedule taint — this may clear on its own:"
    echo "${TAINTED_NODES}"
else
    info "  All control nodes are schedulable (no NoSchedule taint)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Converged Scheduling Configured                      ${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""
info "Control nodes can now schedule workloads."
echo ""
oc get nodes -o wide
echo ""
info "Next: Run post-install playbooks"
info "  ansible-playbook playbooks/site-post-install.yml \\"
info "    -i examples/ibm-cloud-active/inventory.yml \\"
info "    -e @examples/ibm-cloud-active/extra-vars.yml \\"
info "    -e skip_cert_manager=true   # remove when ZeroSSL is configured"
