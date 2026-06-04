#!/usr/bin/env bash
# =============================================================================
# hack/generate-kvm-macs.sh
# =============================================================================
# Pre-generates valid 52:54:00:xx:xx:xx KVM MAC addresses for every
# <FILL_FROM_deploy-kvm-vms.sh> placeholder in extra-vars.yml, writing them
# BEFORE ISO generation so openshift-install receives valid MAC values.
#
# This matches the upstream developer guide pattern where MAC addresses are
# known before ISO generation:
#   - Bare metal: MACs come from hardware (nodes.yml)
#   - KVM: MACs are pre-generated here and then passed explicitly to virt-install
#
# Usage:
#   ./hack/generate-kvm-macs.sh [path/to/extra-vars.yml]
#   (defaults to examples/ibm-cloud-active/extra-vars.yml)
#
# Idempotent: if no <FILL_FROM_deploy-kvm-vms.sh> placeholders remain, exits 0.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
skip() { echo -e "${CYAN}[SKIP]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

CONFIG="${1:-${REPO_ROOT}/examples/ibm-cloud-active/extra-vars.yml}"

if [[ ! -f "${CONFIG}" ]]; then
    echo "ERROR: extra-vars.yml not found at ${CONFIG}" >&2
    exit 1
fi

# Count remaining placeholders
PLACEHOLDER_COUNT=$(grep -c "FILL_FROM_deploy-kvm-vms.sh" "${CONFIG}" 2>/dev/null || true)

if [[ "${PLACEHOLDER_COUNT}" -eq 0 ]]; then
    skip "MAC addresses already set in ${CONFIG} — skipping generation"
    exit 0
fi

info "Generating ${PLACEHOLDER_COUNT} KVM MAC addresses in ${CONFIG}..."

# Generate a unique 52:54:00:xx:xx:xx MAC (KVM OUI prefix)
_generate_mac() {
    printf '52:54:00:%02x:%02x:%02x' \
        $(( (RANDOM * RANDOM) % 256 )) \
        $(( (RANDOM * RANDOM) % 256 )) \
        $(( (RANDOM * RANDOM) % 256 ))
}

# Track generated MACs to ensure uniqueness within this run
declare -A _USED_MACS=()

_unique_mac() {
    local mac
    local attempts=0
    while true; do
        mac=$(_generate_mac)
        if [[ -z "${_USED_MACS[$mac]:-}" ]]; then
            _USED_MACS["$mac"]=1
            echo "$mac"
            return
        fi
        attempts=$(( attempts + 1 ))
        if [[ $attempts -gt 100 ]]; then
            echo "ERROR: Could not generate unique MAC after 100 attempts" >&2
            exit 1
        fi
    done
}

# Replace each placeholder one at a time with a unique MAC.
# Uses GNU sed's first-match substitution (0,/pattern/s/...) to replace
# exactly one placeholder per iteration, preserving node ordering.
COUNT=0
while grep -q "FILL_FROM_deploy-kvm-vms.sh" "${CONFIG}" 2>/dev/null; do
    MAC=$(_unique_mac)
    sed -i "0,/<FILL_FROM_deploy-kvm-vms.sh>/s/<FILL_FROM_deploy-kvm-vms.sh>/${MAC}/" "${CONFIG}"
    COUNT=$(( COUNT + 1 ))
    info "  [${COUNT}/${PLACEHOLDER_COUNT}] ${MAC}"
done

echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  MAC Generation Complete${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════${NC}"
info "  ${COUNT} MACs written to: ${CONFIG}"
info "  These MACs will be:"
info "    1. Embedded in the agent ISO by create-installation-media.yml"
info "    2. Assigned explicitly to KVM VMs by deploy-kvm-vms.sh"
echo ""
info "  To reset and regenerate MACs:"
warn "    git checkout -- ${CONFIG}"
warn "    ./hack/generate-kvm-macs.sh"
echo ""
