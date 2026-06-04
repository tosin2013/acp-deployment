#!/usr/bin/env bash
# setup-automation-hub.sh — Configure Red Hat Automation Hub token and install collections
#
# Usage: ./hack/setup-automation-hub.sh
#
# Prerequisites:
#   1. A Red Hat account with an active subscription (the same one used for pull-secret)
#   2. An Automation Hub API token from:
#      https://console.redhat.com/ansible/automation-hub/token
#      (Click "Load token" → copy the token string)
#
# What this script does:
#   - Prompts for your Automation Hub token (input is hidden)
#   - Writes the token into ansible.cfg (local to this repo, gitignored)
#   - Runs: ansible-galaxy collection install -r playbooks/collections/requirements.yml
#   - Verifies redhat.openshift is installed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
ANSIBLE_CFG="${REPO_ROOT}/ansible.cfg"
REQUIREMENTS="${REPO_ROOT}/playbooks/collections/requirements.yml"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
pass()  { echo -e "  ${GREEN}✓${NC} $*"; }

echo ""
echo -e "${BOLD}Red Hat Automation Hub — Collection Setup${NC}"
echo ""
echo "You need an Automation Hub API token. To get one:"
echo "  1. Go to: https://console.redhat.com/ansible/automation-hub/token"
echo "  2. Click 'Load token'"
echo "  3. Copy the token string"
echo ""

# Check if token is already set via environment variable
if [[ -n "${ANSIBLE_GALAXY_SERVER_AUTOMATION_HUB_TOKEN:-}" ]]; then
    info "Using token from ANSIBLE_GALAXY_SERVER_AUTOMATION_HUB_TOKEN environment variable"
    TOKEN="${ANSIBLE_GALAXY_SERVER_AUTOMATION_HUB_TOKEN}"
else
    # Check if token already set in ansible.cfg
    CURRENT_TOKEN=$(grep -A3 '\[galaxy_server.automation_hub\]' "${ANSIBLE_CFG}" | \
        awk -F= '/^token=/{print $2}' | tr -d ' ')
    
    if [[ -n "${CURRENT_TOKEN}" ]]; then
        warn "A token is already set in ansible.cfg."
        read -r -p "  Overwrite it? [y/N] " OVERWRITE
        [[ "${OVERWRITE}" =~ ^[Yy]$ ]] || { info "Keeping existing token. Running collection install..."; TOKEN="${CURRENT_TOKEN}"; }
    fi

    if [[ -z "${TOKEN:-}" ]]; then
        echo -n "Paste your Automation Hub token (input hidden): "
        read -r -s TOKEN
        echo ""
        [[ -n "${TOKEN}" ]] || die "No token provided. Exiting."
    fi
fi

# Write the token into ansible.cfg (replace the token= line under automation_hub section)
info "Writing token to ansible.cfg..."
# Use Python to safely update the ini file without mangling other sections
python3 - <<EOF
import configparser, os

cfg_path = "${ANSIBLE_CFG}"
config = configparser.ConfigParser()
config.read(cfg_path)

section = "galaxy_server.automation_hub"
if section not in config:
    config[section] = {}
config[section]["token"] = "${TOKEN}"

with open(cfg_path, "w") as f:
    config.write(f)

print("  Token written to ansible.cfg")
EOF

# Also export for this session in case ansible-galaxy reads env
export ANSIBLE_GALAXY_SERVER_AUTOMATION_HUB_TOKEN="${TOKEN}"

echo ""
info "Installing Ansible collections from ${REQUIREMENTS}..."
ansible-galaxy collection install -r "${REQUIREMENTS}" --upgrade

echo ""
info "Verifying installed collections..."
for collection in redhat.openshift kubernetes.core containers.podman amazon.aws; do
    VERSION=$(ansible-galaxy collection list "${collection}" 2>/dev/null | awk "/${collection}/{print \$2}" | head -1)
    if [[ -n "${VERSION}" ]]; then
        pass "${collection}: ${VERSION}"
    else
        warn "${collection}: not found"
    fi
done

echo ""
echo -e "${BOLD}━━━ Next step ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  ansible.cfg now has your Automation Hub token."
echo ""
echo -e "  ${YELLOW}IMPORTANT:${NC} ansible.cfg is NOT committed to git (contains a credential)."
echo "  Each developer must run this script once on their machine."
echo ""
echo "  Alternatively, export the token in your shell profile:"
echo "    export ANSIBLE_GALAXY_SERVER_AUTOMATION_HUB_TOKEN=<token>"
echo ""
