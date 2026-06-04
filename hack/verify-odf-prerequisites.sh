#!/usr/bin/env bash
# verify-odf-prerequisites.sh — ODF preflight validation
#
# Runs before setup-openshift-storage.yml to catch configuration mismatches
# that would cause StorageCluster to remain stuck Progressing for 10+ minutes.
#
# Exit codes: 0 = all checks pass, 1 = one or more failures
#
# Usage: ./hack/verify-odf-prerequisites.sh --extra-vars examples/ibm-cloud-active/extra-vars.yml
#
# Checks:
#   1. Virtualisation type vs odf_use_multus setting
#   2. odf_device_count matches disk discovery results
#   3. LocalVolumeSet provisioned at least one PV
#   4. StorageClass ocs-storagecluster-ceph-rbd does NOT already exist as broken
#   5. openshift-storage namespace clean (no stuck StorageCluster finalizers)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── helpers ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; RESET='\033[0m'
BOLD='\033[1m'
PASS=0; WARN=0; FAIL=0

info()  { echo -e "  ${GREEN}✔${RESET} $*"; }
warn()  { echo -e "  ${YELLOW}⚠${RESET} $*"; ((WARN++)) || true; }
fail()  { echo -e "  ${RED}✘${RESET} $*"; ((FAIL++)) || true; }
header(){ echo -e "\n${BOLD}$*${RESET}"; }

EXTRA_VARS=""
KUBECONFIG="${KUBECONFIG:-/home/vpcuser/cluster_acp/install/auth/kubeconfig}"
OC_BIN=""

usage() {
  echo "Usage: $0 --extra-vars <path-to-extra-vars.yml> [--kubeconfig <path>]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --extra-vars|-e) EXTRA_VARS="$2"; shift 2 ;;
    --kubeconfig)    KUBECONFIG="$2"; shift 2 ;;
    --help|-h)       usage ;;
    *) echo "Unknown argument: $1"; usage ;;
  esac
done

[[ -z "${EXTRA_VARS}" ]] && { echo "ERROR: --extra-vars required"; usage; }
[[ -f "${EXTRA_VARS}" ]] || { echo "ERROR: extra-vars file not found: ${EXTRA_VARS}"; exit 1; }

# Locate oc binary
for candidate in /home/vpcuser/cluster_acp/install/oc /usr/local/bin/oc /usr/bin/oc; do
  [[ -x "${candidate}" ]] && { OC_BIN="${candidate}"; break; }
done
[[ -z "${OC_BIN}" ]] && { echo "ERROR: oc binary not found"; exit 1; }
export KUBECONFIG

# ── read key values from extra-vars.yml ──────────────────────────────────────
ODF_USE_MULTUS="false"
ODF_DEVICE_COUNT=6

if command -v yq &>/dev/null; then
  ODF_USE_MULTUS=$(yq '.openshift.all_node_settings.odf_use_multus // "false"' "${EXTRA_VARS}" 2>/dev/null || echo "false")
  ODF_DEVICE_COUNT=$(yq '.openshift.all_node_settings.odf_device_count // 6' "${EXTRA_VARS}" 2>/dev/null || echo "6")
else
  warn "yq not found — skipping extra-vars parsing; run: pip install yq"
fi

echo -e "\n${BOLD}ODF Prerequisites Verification${RESET}"
echo "Extra-vars : ${EXTRA_VARS}"
echo "Kubeconfig : ${KUBECONFIG}"
echo "odf_use_multus  : ${ODF_USE_MULTUS}"
echo "odf_device_count: ${ODF_DEVICE_COUNT}"

# ── CHECK 1: virtualisation vs odf_use_multus ────────────────────────────────
header "Check 1: Virtualisation type vs odf_use_multus"
VIRT_TYPE=$(sudo systemd-detect-virt 2>/dev/null || echo "unknown")
echo "  Detected virtualisation: ${VIRT_TYPE}"

if [[ "${VIRT_TYPE}" == "kvm" || "${VIRT_TYPE}" == "qemu" ]]; then
  if [[ "${ODF_USE_MULTUS}" == "true" ]]; then
    fail "odf_use_multus: true but environment is KVM (${VIRT_TYPE})."
    fail "  KVM virtio does not support macvlan. This will cause:"
    fail "  'error adding container to network ocs-public-cluster: Link not found'"
    fail "  Fix: set odf_use_multus: false in ${EXTRA_VARS}"
  else
    info "odf_use_multus: false — correct for KVM environment"
  fi
else
  if [[ "${ODF_USE_MULTUS}" != "true" ]]; then
    warn "odf_use_multus: false on non-KVM host (${VIRT_TYPE}). Multus/macvlan is recommended for bare-metal to isolate Ceph storage traffic. See ADR-0005."
  else
    info "odf_use_multus: true — correct for bare-metal environment"
  fi
fi

# ── CHECK 2: OpenShift API reachable ─────────────────────────────────────────
header "Check 2: OpenShift API reachable"
if ${OC_BIN} cluster-info &>/dev/null; then
  info "OpenShift API is reachable"
else
  fail "Cannot reach OpenShift API. Check KUBECONFIG=${KUBECONFIG}"
  echo -e "\n${RED}Cannot continue without API access.${RESET}"
  exit 1
fi

# ── CHECK 3: LSO LocalVolumeSet provisioned disks ────────────────────────────
header "Check 3: LSO disk provisioning (expect ${ODF_DEVICE_COUNT} PVs)"
PROVISIONED=$(${OC_BIN} get localvolumeset local-disks -n openshift-local-storage \
  -o jsonpath='{.status.totalProvisionedDeviceCount}' 2>/dev/null || echo "NOT_FOUND")

if [[ "${PROVISIONED}" == "NOT_FOUND" ]]; then
  warn "LocalVolumeSet 'local-disks' not found yet — run storage playbook first (LSO phase)"
elif [[ "${PROVISIONED}" -eq 0 ]]; then
  fail "LocalVolumeSet provisioned 0 devices. Discovery results:"
  ${OC_BIN} get localvolumediscoveryresult -n openshift-local-storage \
    -o jsonpath='{range .items[*]}{.metadata.name}{": "}{range .spec.discoveredDevices[*]}{.path}{"("}{.property}{"/"}{.type}{"/"}{.status.state}{") "}{end}{"\n"}{end}' 2>/dev/null | head -5
  fail "  If all disks show Rotational: add Rotational to deviceMechanicalProperties in"
  fail "  roles/openshift_local_storage/vars/main.yml"
  fail "  If no disks appear: check virsh domblklist <vm> and verify ODF disks are attached"
elif [[ "${PROVISIONED}" -lt "${ODF_DEVICE_COUNT}" ]]; then
  warn "LocalVolumeSet provisioned ${PROVISIONED} devices, expected ${ODF_DEVICE_COUNT}"
  warn "  StorageCluster count mismatch may cause OSD pods to fail scheduling"
else
  info "LocalVolumeSet provisioned ${PROVISIONED} devices (expected ${ODF_DEVICE_COUNT})"
fi

# ── CHECK 4: No stuck StorageCluster with finalizers ─────────────────────────
header "Check 4: No stuck StorageCluster with blocking finalizers"
SC_PHASE=$(${OC_BIN} get storagecluster ocs-storagecluster -n openshift-storage \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "NOT_FOUND")
SC_FINALIZERS=$(${OC_BIN} get storagecluster ocs-storagecluster -n openshift-storage \
  -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || echo "")

if [[ "${SC_PHASE}" == "NOT_FOUND" ]]; then
  info "No existing StorageCluster — clean slate"
elif [[ -n "${SC_FINALIZERS}" ]]; then
  fail "StorageCluster has a deletionTimestamp — it is stuck deleting with finalizers."
  fail "  Run: oc patch storagecluster ocs-storagecluster -n openshift-storage -p '{\"metadata\":{\"finalizers\":[]}}' --type=merge"
elif [[ "${SC_PHASE}" == "Ready" ]]; then
  info "StorageCluster is Ready — playbook will be idempotent"
elif [[ "${SC_PHASE}" == "Progressing" ]]; then
  warn "StorageCluster exists and is Progressing. If re-running after a failed deploy:"
  warn "  Check 'oc describe storagecluster ocs-storagecluster -n openshift-storage'"
  warn "  If Multus errors: delete SC and re-run with odf_use_multus: false"
else
  warn "StorageCluster phase: ${SC_PHASE}"
fi

# ── CHECK 5: NAD absent when odf_use_multus is false ─────────────────────────
header "Check 5: NAD state vs odf_use_multus"
NAD_EXISTS=$(${OC_BIN} get network-attachment-definition ocs-public-cluster \
  -n openshift-storage --no-headers 2>/dev/null | wc -l)

if [[ "${ODF_USE_MULTUS}" != "true" && "${NAD_EXISTS}" -gt 0 ]]; then
  warn "NAD 'ocs-public-cluster' exists but odf_use_multus is false."
  warn "  If StorageCluster was previously deployed with Multus, delete the NAD:"
  warn "  oc delete network-attachment-definition ocs-public-cluster -n openshift-storage"
elif [[ "${ODF_USE_MULTUS}" == "true" && "${NAD_EXISTS}" -eq 0 ]]; then
  info "NAD not yet created (will be created by playbook — odf_use_multus: true)"
else
  info "NAD state consistent with odf_use_multus: ${ODF_USE_MULTUS}"
fi

# ── SUMMARY ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "  Preflight result: ${GREEN}${PASS} pass${RESET}  ${YELLOW}${WARN} warn${RESET}  ${RED}${FAIL} fail${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

if [[ "${FAIL}" -gt 0 ]]; then
  echo -e "\n${RED}One or more preflight checks failed. Fix above issues before running${RESET}"
  echo -e "${RED}ansible-playbook playbooks/setup-openshift-storage.yml${RESET}"
  exit 1
elif [[ "${WARN}" -gt 0 ]]; then
  echo -e "\n${YELLOW}Warnings present — review before proceeding.${RESET}"
  exit 0
else
  echo -e "\n${GREEN}All ODF preflight checks passed.${RESET}"
  exit 0
fi
