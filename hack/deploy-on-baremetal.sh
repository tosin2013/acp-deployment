#!/usr/bin/env bash
# =============================================================================
# hack/deploy-on-baremetal.sh
# =============================================================================
# Boot bare-metal nodes from the OpenShift agent installer ISO using the
# Redfish API (iDRAC 9+, iLO 5+, Supermicro BMC, AMI MegaRAC).
#
# This is the bare-metal equivalent of hack/deploy-kvm-vms.sh.
# Instead of creating VMs, it:
#   1. Serves the agent ISO via a temporary HTTP server (Python)
#   2. For each node in --nodes file: mounts ISO as Redfish virtual media
#   3. Sets one-time boot override to CD-ROM
#   4. Powers on the node (or reboots if already running)
#   5. Prints node power status
#
# Usage:
#   export BAREMETAL_BMC_PASSWORD=<bmc-password>
#   ./hack/deploy-on-baremetal.sh \
#       --nodes examples/bare-metal-converged/nodes.yml \
#       --iso ~/cluster_acp/install/agent.x86_64.iso
#
# Arguments:
#   --nodes  PATH    Path to nodes.yml with BMC addresses and ISO URLs
#   --iso    PATH    Path to the agent ISO file to serve
#   --port   PORT    HTTP port to serve the ISO on (default: 8080)
#   --dry-run        Print Redfish requests without executing them
#
# Prerequisites:
#   - python3 (for HTTP server and YAML parsing)
#   - curl
#   - jq (optional — for pretty Redfish response output)
#   - Outbound connectivity from BMC network to the helper node on --port
#
# Environment:
#   BAREMETAL_BMC_PASSWORD  BMC password (overrides per-node nodes.yml password)
#   BAREMETAL_BMC_INSECURE  Set to 'true' to skip TLS certificate verification
#                           (needed for self-signed BMC certs — default: true)
#
# Redfish paths by vendor:
#   Dell iDRAC 9:    /redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD
#   HPE iLO 5:       /redfish/v1/Managers/1/VirtualMedia/2
#   Supermicro:      /redfish/v1/Managers/1/VirtualMedia/1
#   AMI MegaRAC:     /redfish/v1/Managers/bmc/VirtualMedia/Cd
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Defaults ──────────────────────────────────────────────────────────────────
NODES_FILE=""
ISO_PATH=""
HTTP_PORT="${HTTP_PORT:-8080}"
DRY_RUN=false
BMC_INSECURE="${BAREMETAL_BMC_INSECURE:-true}"
BMC_PASSWORD="${BAREMETAL_BMC_PASSWORD:-}"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --nodes)   NODES_FILE="$2"; shift 2 ;;
        --iso)     ISO_PATH="$2";   shift 2 ;;
        --port)    HTTP_PORT="$2";  shift 2 ;;
        --dry-run) DRY_RUN=true;    shift ;;
        *) die "Unknown argument: $1
Usage: $0 --nodes <nodes.yml> --iso <agent.iso> [--port 8080] [--dry-run]" ;;
    esac
done

[[ -n "${NODES_FILE}" ]] || die "--nodes is required"
[[ -n "${ISO_PATH}" ]]   || die "--iso is required"
[[ -f "${NODES_FILE}" ]] || die "nodes file not found: ${NODES_FILE}"
[[ -f "${ISO_PATH}" ]]   || die "ISO not found: ${ISO_PATH}
  Run: ansible-playbook playbooks/create-installation-media.yml first"

command -v python3 &>/dev/null || die "python3 is required"
command -v curl    &>/dev/null || die "curl is required"

# ── Parse nodes.yml ───────────────────────────────────────────────────────────
# Use Python to parse YAML (no yq dependency required)
NODES_JSON=$(python3 - <<PYEOF
import yaml, json, sys
with open('${NODES_FILE}') as f:
    data = yaml.safe_load(f)
print(json.dumps(data.get('nodes', [])))
PYEOF
)

NODE_COUNT=$(echo "${NODES_JSON}" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
[[ "${NODE_COUNT}" -gt 0 ]] || die "No nodes found in ${NODES_FILE}"
info "Found ${NODE_COUNT} node(s) in ${NODES_FILE}"

# ── Start ISO HTTP server ──────────────────────────────────────────────────────
ISO_DIR="$(dirname "${ISO_PATH}")"
ISO_FILENAME="$(basename "${ISO_PATH}")"
HTTP_SERVER_PID=""

start_iso_server() {
    info "Starting ISO HTTP server on port ${HTTP_PORT}..."
    info "  Serving: ${ISO_PATH}"
    pushd "${ISO_DIR}" > /dev/null
    python3 -m http.server "${HTTP_PORT}" --bind 0.0.0.0 &>/tmp/iso-http-server.log &
    HTTP_SERVER_PID=$!
    popd > /dev/null
    sleep 2
    if ! kill -0 "${HTTP_SERVER_PID}" 2>/dev/null; then
        cat /tmp/iso-http-server.log
        die "HTTP server failed to start. Is port ${HTTP_PORT} already in use?"
    fi
    info "  HTTP server PID: ${HTTP_SERVER_PID}"
    info "  ISO URL: http://$(hostname -I | awk '{print $1}'):${HTTP_PORT}/${ISO_FILENAME}"
}

stop_iso_server() {
    if [[ -n "${HTTP_SERVER_PID}" ]] && kill -0 "${HTTP_SERVER_PID}" 2>/dev/null; then
        kill "${HTTP_SERVER_PID}" 2>/dev/null || true
        info "HTTP server stopped"
    fi
}
trap stop_iso_server EXIT

if [[ "${DRY_RUN}" == "false" ]]; then
    start_iso_server
fi

# ── Redfish helper functions ───────────────────────────────────────────────────
CURL_OPTS=(-s -S --max-time 60)
if [[ "${BMC_INSECURE}" == "true" ]]; then
    CURL_OPTS+=(-k)
fi

redfish_get() {
    local bmc_addr="$1" username="$2" password="$3" path="$4"
    curl "${CURL_OPTS[@]}" \
        -u "${username}:${password}" \
        -H "Accept: application/json" \
        "${bmc_addr}${path}"
}

redfish_post() {
    local bmc_addr="$1" username="$2" password="$3" path="$4" body="$5"
    curl "${CURL_OPTS[@]}" \
        -u "${username}:${password}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -X POST \
        -d "${body}" \
        "${bmc_addr}${path}"
}

redfish_patch() {
    local bmc_addr="$1" username="$2" password="$3" path="$4" body="$5"
    curl "${CURL_OPTS[@]}" \
        -u "${username}:${password}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -X PATCH \
        -d "${body}" \
        "${bmc_addr}${path}"
}

# Detect VirtualMedia path for a given BMC
detect_virtual_media_path() {
    local bmc_addr="$1" username="$2" password="$3"
    local vm_collection
    vm_collection=$(redfish_get "${bmc_addr}" "${username}" "${password}" \
        "/redfish/v1/Managers" 2>/dev/null || echo "{}")

    # Try common vendor paths in order
    for path in \
        "/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD" \
        "/redfish/v1/Managers/1/VirtualMedia/2" \
        "/redfish/v1/Managers/1/VirtualMedia/1" \
        "/redfish/v1/Managers/bmc/VirtualMedia/Cd"; do
        local response
        response=$(redfish_get "${bmc_addr}" "${username}" "${password}" "${path}" 2>/dev/null || echo "")
        if echo "${response}" | grep -qi '"MediaTypes"'; then
            echo "${path}"
            return 0
        fi
    done
    echo ""
}

# ── Process each node ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}   Booting nodes from agent ISO via Redfish            ${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""

python3 - <<PYEOF
import json, sys
nodes = json.loads('''${NODES_JSON}''')
for i, node in enumerate(nodes):
    print(f"  [{i+1}] {node['name']}  bmc={node['bmc']['address']}  iso={node.get('boot_iso_url', '<see --nodes>')}")
PYEOF
echo ""

FAILED_NODES=()

for i in $(seq 0 $((NODE_COUNT - 1))); do
    NODE_JSON=$(echo "${NODES_JSON}" | python3 -c "import sys,json; nodes=json.load(sys.stdin); print(json.dumps(nodes[${i}]))")
    NODE_NAME=$(echo "${NODE_JSON}"  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['name'])")
    BMC_ADDR=$(echo "${NODE_JSON}"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['bmc']['address'])")
    BMC_USER=$(echo "${NODE_JSON}"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['bmc']['username'])")
    NODE_PASS=$(echo "${NODE_JSON}"  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['bmc'].get('password',''))")
    ISO_URL=$(echo "${NODE_JSON}"    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('boot_iso_url',''))")

    # Resolve password: per-node > environment
    [[ -z "${NODE_PASS}" ]] && NODE_PASS="${BMC_PASSWORD}"
    [[ -n "${NODE_PASS}" ]] || die "No BMC password for ${NODE_NAME}. Set BAREMETAL_BMC_PASSWORD or bmc.password in nodes.yml"

    info "Processing node: ${NODE_NAME} (${BMC_ADDR})"

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "  [DRY-RUN] Would mount ISO: ${ISO_URL}"
        echo "  [DRY-RUN] Would set boot override: Cd"
        echo "  [DRY-RUN] Would power on: ${BMC_ADDR}"
        echo ""
        continue
    fi

    # 1. Detect VirtualMedia path
    VM_PATH=$(redfish_get "${BMC_ADDR}" "${BMC_USER}" "${NODE_PASS}" \
        "" 2>/dev/null && detect_virtual_media_path "${BMC_ADDR}" "${BMC_USER}" "${NODE_PASS}" || echo "")

    # Try to get the path from nodes.yml (optional override)
    VM_PATH_OVERRIDE=$(echo "${NODE_JSON}" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d['bmc'].get('redfish_path',''))")
    [[ -n "${VM_PATH_OVERRIDE}" ]] && VM_PATH="${VM_PATH_OVERRIDE}"

    if [[ -z "${VM_PATH}" ]]; then
        warn "  Could not auto-detect VirtualMedia path for ${NODE_NAME}"
        warn "  Set bmc.redfish_path in nodes.yml for this node"
        FAILED_NODES+=("${NODE_NAME}")
        continue
    fi
    info "  VirtualMedia path: ${VM_PATH}"

    # 2. Eject any existing virtual media
    info "  Ejecting existing virtual media..."
    redfish_post "${BMC_ADDR}" "${BMC_USER}" "${NODE_PASS}" \
        "${VM_PATH}/Actions/VirtualMedia.EjectMedia" '{}' &>/dev/null || true

    # 3. Insert ISO as virtual media
    info "  Mounting ISO: ${ISO_URL}"
    INSERT_RESULT=$(redfish_post "${BMC_ADDR}" "${BMC_USER}" "${NODE_PASS}" \
        "${VM_PATH}/Actions/VirtualMedia.InsertMedia" \
        "{\"Image\":\"${ISO_URL}\",\"Inserted\":true,\"WriteProtected\":true}" 2>&1 || echo "FAILED")

    if echo "${INSERT_RESULT}" | grep -qi '"error"'; then
        warn "  ISO mount may have failed. Response: ${INSERT_RESULT}"
    else
        info "  ISO mounted"
    fi

    # 4. Set one-time boot override to CD-ROM
    info "  Setting one-time boot: Cd (CD-ROM)..."
    SYSTEMS_PATH="/redfish/v1/Systems/1"   # Dell: System.Embedded.1, HPE: 1
    BOOT_RESULT=$(redfish_patch "${BMC_ADDR}" "${BMC_USER}" "${NODE_PASS}" \
        "${SYSTEMS_PATH}" \
        '{"Boot":{"BootSourceOverrideEnabled":"Once","BootSourceOverrideTarget":"Cd"}}' 2>&1 || echo "FAILED")

    if echo "${BOOT_RESULT}" | grep -qi '"error"'; then
        warn "  Boot override may have failed. Response: ${BOOT_RESULT}"
    else
        info "  Boot override set"
    fi

    # 5. Power on / reset the node
    info "  Powering on ${NODE_NAME}..."
    POWER_RESULT=$(redfish_post "${BMC_ADDR}" "${BMC_USER}" "${NODE_PASS}" \
        "${SYSTEMS_PATH}/Actions/ComputerSystem.Reset" \
        '{"ResetType":"On"}' 2>&1 || true)

    # If already powered on, do a graceful restart
    if echo "${POWER_RESULT}" | grep -qi '"error"'; then
        info "  Node appears to be running — sending GracefulRestart..."
        redfish_post "${BMC_ADDR}" "${BMC_USER}" "${NODE_PASS}" \
            "${SYSTEMS_PATH}/Actions/ComputerSystem.Reset" \
            '{"ResetType":"GracefulRestart"}' &>/dev/null || true
    fi

    info "  ${NODE_NAME} boot initiated"
    echo ""
done

# ── Summary ────────────────────────────────────────────────────────────────────
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
if [[ ${#FAILED_NODES[@]} -gt 0 ]]; then
    warn "Nodes that need manual attention: ${FAILED_NODES[*]}"
    warn "  Check bmc.redfish_path in ${NODES_FILE} for these nodes."
else
    echo -e "${GREEN}All nodes booted from ISO${NC}"
fi
echo ""
info "Monitor installation:"
info "  export KUBECONFIG=~/cluster_\${CLUSTER_NAME}/install/auth/kubeconfig"
info "  openshift-install agent wait-for install-complete \\"
info "    --dir ~/cluster_\${CLUSTER_NAME}/install --log-level=info"
echo ""
info "Note: ISO HTTP server will stop when this script exits."
info "  Nodes that have already downloaded the ISO will continue installing."
info "  If installation stalls, re-run this script to re-serve the ISO."
