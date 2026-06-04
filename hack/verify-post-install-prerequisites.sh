#!/usr/bin/env bash
# verify-post-install-prerequisites.sh — Post-install pipeline preflight validation
#
# Catches configuration gaps that caused the 2026-06-04 post-install pipeline incident:
#   - ansible_user undefined for local connections
#   - cert-manager CRD registered and CSV Succeeded before operand CRs are applied
#   - kubeconfig certificate-authority-data not stripped after API cert rotation
#
# Exit codes: 0 = all checks pass, 1 = one or more failures
#
# Usage:
#   ./hack/verify-post-install-prerequisites.sh \
#     --inventory examples/ibm-cloud-active/inventory.yml \
#     [--kubeconfig ~/cluster_acp/install/auth/kubeconfig]
#
# Checks:
#   1. ansible_user resolves correctly for the helper host (local connection safety)
#   2. cert-manager CSV is Succeeded (safe to apply operand CRs)
#   3. kubeconfig has no stale certificate-authority-data (safe to run after TLS rotation)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── helpers ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; RESET='\033[0m'
BOLD='\033[1m'
PASS=0; WARN=0; FAIL=0

info()  { echo -e "  ${GREEN}[PASS]${RESET} $*"; ((PASS++)) || true; }
warn()  { echo -e "  ${YELLOW}[WARN]${RESET} $*"; ((WARN++)) || true; }
fail()  { echo -e "  ${RED}[FAIL]${RESET} $*"; ((FAIL++)) || true; }
header(){ echo -e "\n${BOLD}$*${RESET}"; }

INVENTORY="${REPO_ROOT}/examples/ibm-cloud-active/inventory.yml"
KUBECONFIG_PATH="${KUBECONFIG:-${HOME}/cluster_acp/install/auth/kubeconfig}"

usage() {
  echo "Usage: $0 [--inventory <path>] [--kubeconfig <path>]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --inventory|-i) INVENTORY="$2"; shift 2 ;;
    --kubeconfig)   KUBECONFIG_PATH="$2"; shift 2 ;;
    --help|-h)      usage ;;
    *) echo "Unknown argument: $1"; usage ;;
  esac
done

# Locate oc binary
OC_BIN=$(command -v oc 2>/dev/null || ls "${HOME}"/cluster_acp/install/oc 2>/dev/null || echo "")
if [[ -z "${OC_BIN}" ]]; then
  echo "ERROR: oc binary not found. Add it to PATH or place it in ~/cluster_acp/install/"
  exit 1
fi
export KUBECONFIG="${KUBECONFIG_PATH}"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  POST-INSTALL PREREQUISITES CHECK"
echo "  Inventory : ${INVENTORY}"
echo "  Kubeconfig: ${KUBECONFIG_PATH}"
echo "════════════════════════════════════════════════════════════════"

# ── CHECK 1: ansible_user resolves for the helper host ───────────────────────
header "Check 1: ansible_user resolves for local connections"

if [[ ! -f "${INVENTORY}" ]]; then
  fail "Inventory file not found: ${INVENTORY}"
else
  ANSIBLE_USER_VALUE=$(ansible \
    -i "${INVENTORY}" helper \
    -m debug \
    -a 'var=ansible_user' \
    --one-line 2>/dev/null \
    | grep -o '"ansible_user": "[^"]*"' \
    | head -1 || echo "")

  if echo "${ANSIBLE_USER_VALUE}" | grep -q "VARIABLE IS NOT DEFINED\|undefined\|\"\""; then
    fail "ansible_user is UNDEFINED for the helper host."
    fail "  Fix: add 'ansible_user: \"{{ lookup('env', 'USER') }}\"' to ${INVENTORY}"
    fail "  See ADR-0003 amendment 2026-06-04."
  elif [[ -z "${ANSIBLE_USER_VALUE}" ]]; then
    warn "Could not determine ansible_user (ansible may not be installed or inventory unreachable)."
    warn "  Manually verify: ansible -i ${INVENTORY} helper -m debug -a 'var=ansible_user'"
  else
    RESOLVED_USER=$(echo "${ANSIBLE_USER_VALUE}" | grep -o '"[^"]*"$' | tr -d '"')
    info "ansible_user resolves to: ${RESOLVED_USER}"
  fi
fi

# ── CHECK 2: cert-manager CSV is Succeeded ────────────────────────────────────
header "Check 2: cert-manager-operator CSV phase"

if ! "${OC_BIN}" get namespace cert-manager-operator &>/dev/null; then
  warn "cert-manager-operator namespace does not exist — cert-manager not yet installed."
  warn "  This is expected before running update-ocp-ingress-cert.yml."
else
  CSV_PHASE=$("${OC_BIN}" get csv \
    -n cert-manager-operator \
    -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null \
    | head -1 || echo "")

  if [[ -z "${CSV_PHASE}" ]]; then
    fail "No CSV found in cert-manager-operator namespace."
    fail "  OLM may still be installing. Wait and retry, or check:"
    fail "  oc get csv -n cert-manager-operator"
  elif [[ "${CSV_PHASE}" == "Succeeded" ]]; then
    CSV_NAME=$("${OC_BIN}" get csv -n cert-manager-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    info "cert-manager CSV is Succeeded: ${CSV_NAME}"
    info "  Safe to apply CertManager operand CR."
  else
    fail "cert-manager CSV phase is '${CSV_PHASE}' (expected: Succeeded)."
    fail "  Applying CertManager CR before CSV succeeds causes:"
    fail "  'Failed to find exact match for operator.openshift.io/v1alpha1.CertManager'"
    fail "  Wait for: oc get csv -n cert-manager-operator"
    fail "  See ADR-0006 amendment 2026-06-04."
  fi
fi

# ── CHECK 3: kubeconfig has no stale certificate-authority-data ──────────────
header "Check 3: kubeconfig stale CA data (after TLS rotation)"

if [[ ! -f "${KUBECONFIG_PATH}" ]]; then
  warn "kubeconfig not found at: ${KUBECONFIG_PATH}"
  warn "  Skipping CA check — cluster may not yet be installed."
else
  # grep -c exits 1 when count is 0 — use set +e to avoid triggering || echo "0" twice
  set +e
  CA_COUNT=$(grep -c "certificate-authority-data" "${KUBECONFIG_PATH}" 2>/dev/null); CA_COUNT="${CA_COUNT:-0}"
  CERT_ROTATED=$("${OC_BIN}" get secret router-cert -n openshift-ingress \
    --no-headers 2>/dev/null | wc -l | tr -d '[:space:]'); CERT_ROTATED="${CERT_ROTATED:-0}"
  set -e

  if [[ "${CERT_ROTATED}" -gt 0 && "${CA_COUNT}" -gt 0 ]]; then
    fail "kubeconfig contains certificate-authority-data (${CA_COUNT} occurrence(s)) BUT"
    fail "TLS rotation has already been applied (router-cert secret exists)."
    fail "The old self-signed CA will cause CERTIFICATE_VERIFY_FAILED in subsequent playbooks."
    fail "Fix:"
    fail "  sed -i '/^    certificate-authority-data:/d' ${KUBECONFIG_PATH}"
    fail "See ADR-0009 amendment 2026-06-04."
  elif [[ "${CERT_ROTATED}" -eq 0 && "${CA_COUNT}" -gt 0 ]]; then
    info "kubeconfig has certificate-authority-data (expected before TLS rotation)."
  elif [[ "${CA_COUNT}" -eq 0 ]]; then
    info "kubeconfig has no certificate-authority-data — clean for post-TLS-rotation use."
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════"
echo -e "  Results: ${GREEN}${PASS} passed${RESET}  ${YELLOW}${WARN} warnings${RESET}  ${RED}${FAIL} failed${RESET}"
echo "════════════════════════════════════════════════════════════════"
echo ""

if [[ "${FAIL}" -gt 0 ]]; then
  echo "One or more checks FAILED. Resolve issues before running site-post-install.yml."
  exit 1
elif [[ "${WARN}" -gt 0 ]]; then
  echo "All critical checks passed with warnings. Review warnings above."
  exit 0
else
  echo "All checks passed. Safe to run site-post-install.yml."
  exit 0
fi
