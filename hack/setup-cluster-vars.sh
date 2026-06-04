#!/usr/bin/env bash
# setup-cluster-vars.sh — Populate extra-vars.yml with pull secret, SSH key, base_domain
#
# Usage: ./hack/setup-cluster-vars.sh
#
# Required environment variables (source hack/env.sh first):
#   CLUSTER_NAME  - OpenShift cluster name (e.g., "acp")
#   BASE_DOMAIN   - Base DNS domain (e.g., "sandbox3377.opentlc.com")
#
# What this script does:
#   1. Generates an Ed25519 SSH key at ~/.ssh/acp_id_ed25519 if none exists
#   2. Reads pull secret from ~/pull-secret.json (required)
#   3. Writes cluster_name, base_domain, pull_secret, ssh_pub_key into:
#      - examples/ibm-cloud-converged/extra-vars.yml
#      - examples/ibm-cloud-sno/extra-vars.yml
#   4. Gitignores both extra-vars files so secrets are never committed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
pass()  { echo -e "  ${GREEN}✓${NC} $*"; }

: "${CLUSTER_NAME:?ERROR: CLUSTER_NAME is not set. Source hack/env.sh first.}"
: "${BASE_DOMAIN:?ERROR: BASE_DOMAIN is not set. Source hack/env.sh first.}"

PULL_SECRET_FILE="${HOME}/pull-secret.json"
SSH_KEY_FILE="${HOME}/.ssh/acp_id_ed25519"
CONVERGED_VARS="${REPO_ROOT}/examples/ibm-cloud-converged/extra-vars.yml"
SNO_VARS="${REPO_ROOT}/examples/ibm-cloud-sno/extra-vars.yml"

echo ""
echo -e "${BOLD}━━━ Cluster Variable Setup ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "  Cluster : ${CLUSTER_NAME}.${BASE_DOMAIN}"
echo ""

# ── Step 1: SSH key ────────────────────────────────────────────────────────────
mkdir -p "${HOME}/.ssh" && chmod 700 "${HOME}/.ssh"

EXISTING_KEY=""
for candidate in "${SSH_KEY_FILE}.pub" "${HOME}/.ssh/id_ed25519.pub" "${HOME}/.ssh/id_rsa.pub"; do
    if [[ -f "${candidate}" ]]; then
        EXISTING_KEY="${candidate}"
        break
    fi
done

if [[ -n "${EXISTING_KEY}" ]]; then
    pass "SSH public key found: ${EXISTING_KEY}"
    SSH_PUB_KEY=$(cat "${EXISTING_KEY}")
else
    info "No SSH key found — generating Ed25519 key pair at ${SSH_KEY_FILE}..."
    ssh-keygen -t ed25519 -f "${SSH_KEY_FILE}" -N "" -C "acp-deployment@${HOSTNAME}" -q
    chmod 600 "${SSH_KEY_FILE}"
    chmod 644 "${SSH_KEY_FILE}.pub"
    SSH_PUB_KEY=$(cat "${SSH_KEY_FILE}.pub")
    pass "SSH key generated: ${SSH_KEY_FILE}"
    info "  Public key: ${SSH_PUB_KEY}"
fi

# ── Step 2: Pull secret ────────────────────────────────────────────────────────
[[ -f "${PULL_SECRET_FILE}" ]] || \
    die "Pull secret not found at ${PULL_SECRET_FILE}\n  Download from: https://console.redhat.com/openshift/install/pull-secret"

python3 -c "import json; json.load(open('${PULL_SECRET_FILE}'))" 2>/dev/null || \
    die "${PULL_SECRET_FILE} is not valid JSON"

# Compact to single line (required by agent installer); write to temp file to avoid quoting issues
PULL_SECRET_TMP=$(mktemp)
python3 -c "import json; print(json.dumps(json.load(open('${PULL_SECRET_FILE}'))))" > "${PULL_SECRET_TMP}"
pass "Pull secret loaded from ${PULL_SECRET_FILE}"

# ── Step 3: Update extra-vars.yml via Python (reads secrets from files) ───────
update_extra_vars() {
    local vars_file="$1"
    local cluster_name="$2"
    local ssh_pub_key_tmp="$3"
    local pull_secret_tmp="$4"

    [[ -f "${vars_file}" ]] || { warn "File not found: ${vars_file} — skipping"; return; }

    info "Updating ${vars_file}..."

    python3 - "${vars_file}" "${cluster_name}" "${BASE_DOMAIN}" \
              "${ssh_pub_key_tmp}" "${pull_secret_tmp}" <<'PYEOF'
import re, sys

path, cluster_name, base_domain, ssh_key_file, pull_secret_file = sys.argv[1:]

with open(path) as f:
    content = f.read()

with open(ssh_key_file) as f:
    ssh_pub_key = f.read().strip()

with open(pull_secret_file) as f:
    pull_secret = f.read().strip()

# Replace cluster_name
content = re.sub(r"(cluster_name:\s*)\S+", r"\g<1>" + cluster_name, content)

# Replace base_domain
content = re.sub(r"(base_domain:\s*)\S+", r"\g<1>" + base_domain, content)

# Replace pull_secret (the whole line, handles placeholders and real values)
content = re.sub(r"  pull_secret:.*", "  pull_secret: '" + pull_secret.replace("'", "'\"'\"'") + "'", content)

# Replace ssh_pub_key
content = re.sub(r"  ssh_pub_key:.*", "  ssh_pub_key: '" + ssh_pub_key + "'", content)

with open(path, "w") as f:
    f.write(content)

print("  Updated: cluster_name, base_domain, pull_secret, ssh_pub_key")
PYEOF
}

# Write SSH key to temp file so Python reads it without shell quoting issues
SSH_KEY_TMP=$(mktemp)
echo "${SSH_PUB_KEY}" > "${SSH_KEY_TMP}"

update_extra_vars "${CONVERGED_VARS}" "${CLUSTER_NAME}"      "${SSH_KEY_TMP}" "${PULL_SECRET_TMP}"
update_extra_vars "${SNO_VARS}"       "${CLUSTER_NAME}-sno"  "${SSH_KEY_TMP}" "${PULL_SECRET_TMP}"

rm -f "${PULL_SECRET_TMP}" "${SSH_KEY_TMP}"

# ── Step 4: Gitignore the extra-vars files ────────────────────────────────────
GITIGNORE="${REPO_ROOT}/.gitignore"
for pattern in "examples/ibm-cloud-converged/extra-vars.yml" "examples/ibm-cloud-sno/extra-vars.yml"; do
    if ! grep -qF "${pattern}" "${GITIGNORE}" 2>/dev/null; then
        echo "${pattern}" >> "${GITIGNORE}"
        info "  Added to .gitignore: ${pattern}"
    fi
done

# ── Step 5: Verify ────────────────────────────────────────────────────────────
echo ""
info "Verifying ${CONVERGED_VARS}..."
python3 - "${CONVERGED_VARS}" "${BASE_DOMAIN}" <<'PYEOF'
import re, sys

path, base_domain = sys.argv[1:]
with open(path) as f:
    content = f.read()

checks = [
    ("cluster_name",  r'cluster_name:\s*\S+'),
    ("base_domain",   r'base_domain:\s*' + re.escape(base_domain)),
    ("pull_secret",   r"pull_secret:\s*'\{"),
    ("ssh_pub_key",   r"ssh_pub_key:\s*'(ssh-|ecdsa-|sk-)"),
]

ok = True
for name, pattern in checks:
    if re.search(pattern, content):
        print(f"  \033[0;32m✓\033[0m {name}: set")
    else:
        print(f"  \033[0;31m✗\033[0m {name}: NOT set correctly")
        ok = False

sys.exit(0 if ok else 1)
PYEOF

echo ""
echo -e "${BOLD}━━━ Next Steps ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${BOLD}1. Select topology (if not already done)${NC}"
echo "     ./hack/select-cluster-topology.sh"
echo ""
echo -e "  ${BOLD}2. Generate the agent ISO${NC}"
echo "     ansible-playbook playbooks/create-installation-media.yml \\"
echo "       -i examples/ibm-cloud-active/inventory.yml \\"
echo "       -e @examples/ibm-cloud-active/extra-vars.yml"
echo ""
echo -e "  ${BOLD}3. Deploy VMs (DNS gate runs automatically)${NC}"
echo "     export CLUSTER_NAME=${CLUSTER_NAME} BASE_DOMAIN=${BASE_DOMAIN} EXTERNAL_IP=\$EXTERNAL_IP"
echo "     ./hack/deploy-kvm-vms.sh"
echo ""
echo -e "  ${BOLD}4. After VMs print MACs → update extra-vars.yml MACs → re-generate ISO${NC}"
echo ""
warn "examples/ibm-cloud-converged/extra-vars.yml and ibm-cloud-sno/extra-vars.yml contain secrets — both are gitignored"
