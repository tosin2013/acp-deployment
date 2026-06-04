#!/usr/bin/env bash
# =============================================================================
# hack/watch-and-reboot-kvm-vms.sh
# =============================================================================
# REQUIRED for KVM Agent-Based Installer deployments.
#
# The Agent-Based Installer writes RHCOS to disk and then shuts each VM down.
# VMs do not self-reboot after the disk write. Without this watcher, installation
# hangs permanently after the first reboot cycle.
#
# This script polls each VM every 15 seconds. When a VM transitions to
# "shut off", it restarts it with `virsh start`. It stops itself once
# the kubeconfig is written (cluster install complete) or after a timeout.
#
# Usage:
#   ./hack/watch-and-reboot-kvm-vms.sh [--config path/to/extra-vars.yml] [--timeout 7200]
#
# Run in the background during installation:
#   ./hack/watch-and-reboot-kvm-vms.sh &
#   WATCHER_PID=$!
#
# Reference: https://tosin2013.github.io/openshift-agent-install/developer-guide.html
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "$(date '+%H:%M:%S') ${GREEN}[WATCHER]${NC} $*"; }
warn()  { echo -e "$(date '+%H:%M:%S') ${YELLOW}[WATCHER]${NC} $*"; }
event() { echo -e "$(date '+%H:%M:%S') ${CYAN}[REBOOT ]${NC} $*"; }

# ── Parse args ────────────────────────────────────────────────────────────────
CONFIG="${REPO_ROOT}/examples/ibm-cloud-active/extra-vars.yml"
TIMEOUT=7200   # 2 hours max
POLL_INTERVAL=15

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)  CONFIG="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --poll)    POLL_INTERVAL="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# ── Determine VM names from config ────────────────────────────────────────────
mapfile -t VM_NAMES < <(
    python3 - "${CONFIG}" <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f:
    content = f.read()
cn = re.search(r'control_nodes:(.*?)(?=\n  [a-zA-Z]|\Z)', content, re.DOTALL)
if cn:
    print('\n'.join(re.findall(r'^\s{4}-\s+name:\s+(\S+)', cn.group(1), re.MULTILINE)))
PYEOF
)
[[ ${#VM_NAMES[@]} -gt 0 ]] || VM_NAMES=("control-0" "control-1" "control-2")

# ── Determine install dir for kubeconfig check ─────────────────────────────────
CLUSTER_NAME="${CLUSTER_NAME:-acp}"
INSTALL_DIR="${HOME}/cluster_${CLUSTER_NAME}/install"
KUBECONFIG_PATH="${INSTALL_DIR}/auth/kubeconfig"

# ── Track reboot counts ────────────────────────────────────────────────────────
declare -A REBOOT_COUNT=()
for VM in "${VM_NAMES[@]}"; do
    REBOOT_COUNT["$VM"]=0
done

echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  KVM VM Auto-Reboot Watcher — Agent-Based Installer  ${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════${NC}"
info "Watching VMs: ${VM_NAMES[*]}"
info "Poll interval: ${POLL_INTERVAL}s  |  Timeout: $((TIMEOUT / 60)) min"
info "Kubeconfig target: ${KUBECONFIG_PATH}"
info "This watcher MUST run until install-complete. Ctrl-C to stop early."
echo ""

START_TIME=$(date +%s)

while true; do
    ELAPSED=$(( $(date +%s) - START_TIME ))
    if [[ ${ELAPSED} -ge ${TIMEOUT} ]]; then
        warn "Timeout reached (${TIMEOUT}s) — stopping watcher"
        break
    fi

    # Stop once all nodes report Ready (install truly complete).
    # kubeconfig is written early during bootstrap — check node readiness instead.
    if [[ -f "${KUBECONFIG_PATH}" ]]; then
        NOT_READY=$(KUBECONFIG="${KUBECONFIG_PATH}" oc get nodes \
            --no-headers --request-timeout=5s 2>/dev/null | \
            grep -cv "Ready" || true)
        TOTAL=$(KUBECONFIG="${KUBECONFIG_PATH}" oc get nodes \
            --no-headers --request-timeout=5s 2>/dev/null | \
            wc -l || true)
        if [[ "${TOTAL}" -ge "${#VM_NAMES[@]}" ]] && [[ "${NOT_READY}" -eq 0 ]]; then
            info "All ${TOTAL} nodes Ready — cluster installation complete. Stopping watcher."
            break
        fi
    fi

    for VM in "${VM_NAMES[@]}"; do
        STATE=$(sudo virsh domstate "${VM}" 2>/dev/null || echo "missing")
        case "${STATE}" in
            "shut off")
                REBOOT_COUNT["$VM"]=$(( ${REBOOT_COUNT[$VM]} + 1 ))
                event "${VM} shut off → restarting (reboot #${REBOOT_COUNT[$VM]})"
                sudo virsh start "${VM}" 2>/dev/null && \
                    info "  ${VM} started" || \
                    warn "  ${VM} start failed — will retry"
                ;;
            "running")
                ;;
            "paused")
                warn "${VM} is paused — resuming"
                sudo virsh resume "${VM}" 2>/dev/null || true
                ;;
            "missing")
                warn "${VM} not found in virsh — may have been deleted"
                ;;
            *)
                info "${VM} state: ${STATE}"
                ;;
        esac
    done

    sleep "${POLL_INTERVAL}"
done

echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Watcher Summary                                     ${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════${NC}"
for VM in "${VM_NAMES[@]}"; do
    info "  ${VM}: ${REBOOT_COUNT[$VM]} reboot(s)"
done
info "Elapsed: $((ELAPSED / 60))m $((ELAPSED % 60))s"
echo ""
