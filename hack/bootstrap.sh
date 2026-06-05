#!/usr/bin/env bash
# bootstrap.sh — Single-command developer environment setup for ACP deployment on IBM Cloud
#
# Usage:
#   sudo ./hack/bootstrap.sh [--skip-kvm] [--skip-networks] [--vm-disk /dev/vdb]
#
# What this script does (idempotent — safe to run multiple times):
#   1.  Pre-flight checks: OS, disk, RAM, AWS credentials
#   2.  Install missing system packages: nmstate, yq, bind-utils, jq
#   3.  Install AWS CLI (via pip3 if not in DNF repos)
#   4.  Install OpenShift CLI tools (oc, kubectl, openshift-install) if missing
#   5.  Install Ansible collections: redhat.openshift, containers.podman, amazon.aws
#   6.  Call hack/install-kvm-host.sh  (KVM stack + storage pool on VM disk)
#   7.  Call hack/setup-libvirt-networks.sh  (acp-provisioning + acp-storage)
#   8.  Print next steps
#
# After bootstrap, the developer must:
#   - Log out and back in (libvirt group membership)
#   - Fill in hack/env.sh (CLUSTER_NAME, BASE_DOMAIN, EXTERNAL_IP, HOSTED_ZONE_ID)
#   - Then run: source hack/env.sh && sudo -E ./hack/setup-dnsmasq.sh, etc.
#
# See docs/kvm-developer-guide.md for the full phase-by-phase walkthrough.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

# ── Argument parsing ───────────────────────────────────────────────────────────
SKIP_KVM=false
SKIP_NETWORKS=false
VM_DISK="/dev/vdb"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-kvm)       SKIP_KVM=true; shift;;
        --skip-networks)  SKIP_NETWORKS=true; shift;;
        --vm-disk)        VM_DISK="$2"; shift 2;;
        -h|--help)
            grep '^#' "$0" | head -20 | sed 's/^# \?//'
            exit 0;;
        *) echo "Unknown argument: $1"; exit 1;;
    esac
done

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
pass()   { echo -e "  ${GREEN}✓${NC} $*"; }
fail()   { echo -e "  ${RED}✗${NC} $*"; }
info()   { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()    { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section(){ echo ""; echo -e "${BOLD}━━━ $* ━━━${NC}"; }

# ── Root check ─────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "This script must be run as root (sudo $0)"

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo '')}"
[[ -n "${REAL_USER}" ]] || die "Could not determine the real user. Run with sudo, not as root directly."

# ── Section 1: Pre-flight checks ──────────────────────────────────────────────
section "Pre-flight Checks"

# OS check
OS_ID=$(. /etc/os-release && echo "${ID}")
OS_VER=$(. /etc/os-release && echo "${VERSION_ID}")
if [[ "${OS_ID}" == "centos" && "${OS_VER}" == "10" ]]; then
    pass "OS: CentOS Stream 10"
elif [[ "${OS_ID}" == "rhel" && "${OS_VER}" =~ ^9|^10 ]]; then
    pass "OS: RHEL ${OS_VER} (compatible)"
else
    warn "OS: ${OS_ID} ${OS_VER} — expected CentOS Stream 10 or RHEL 9/10. Proceeding anyway."
fi

# CPU count
CPU_COUNT=$(nproc)
if [[ ${CPU_COUNT} -ge 32 ]]; then
    pass "CPUs: ${CPU_COUNT} (≥ 32 required for HA cluster)"
else
    warn "CPUs: ${CPU_COUNT} — minimum 32 recommended for 3-node HA. SNO requires 8."
fi

# RAM check
RAM_GB=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
if [[ ${RAM_GB} -ge 96 ]]; then
    pass "RAM: ${RAM_GB} GB (≥ 96 GB required for HA cluster)"
else
    warn "RAM: ${RAM_GB} GB — minimum 96 GB recommended for HA (3 × 32 GB nodes)"
fi

# VM disk check
if [[ -b "${VM_DISK}" ]]; then
    DISK_GB=$(lsblk -bnd -o SIZE "${VM_DISK}" 2>/dev/null | awk '{printf "%.0f", $1/1024/1024/1024}')
    if [[ ${DISK_GB} -ge 400 ]]; then
        pass "VM disk ${VM_DISK}: ${DISK_GB} GB (≥ 400 GB required)"
    else
        warn "VM disk ${VM_DISK}: ${DISK_GB} GB — minimum 400 GB recommended for HA + ODF"
    fi
else
    warn "VM disk ${VM_DISK} not found — KVM pool creation will be skipped or will fail"
fi

# AWS credentials check (non-fatal — may not be needed until Route53 step)
if [[ -f "${HOME}/.aws/credentials" ]] || [[ -f "/home/${REAL_USER}/.aws/credentials" ]]; then
    pass "AWS credentials: found"
else
    warn "AWS credentials not found at ~/.aws/credentials"
    warn "  Required for: hack/configure-route53-dns.sh and cert-manager Route53 DNS-01"
    warn "  Set up with: aws configure (or copy ~/.aws/credentials from your workstation)"
fi

# Pull secret check (non-fatal — needed for ISO generation)
PULL_SECRET_PATH="/home/${REAL_USER}/pull-secret.json"
if [[ -f "${PULL_SECRET_PATH}" ]]; then
    pass "Pull secret: found at ${PULL_SECRET_PATH}"
else
    warn "Pull secret not found at ~/pull-secret.json"
    warn "  Required for: ISO generation (hack/setup-cluster-vars.sh)"
    warn "  Download from: https://console.redhat.com/openshift/install/pull-secret"
fi

echo ""

# ── Section 2: System packages ────────────────────────────────────────────────
section "System Packages"

install_pkg() {
    local pkg="$1"
    local description="${2:-$1}"
    if rpm -q "${pkg}" &>/dev/null; then
        pass "${description}: already installed ($(rpm -q --queryformat '%{VERSION}' "${pkg}"))"
    else
        info "Installing ${description}..."
        dnf install -y "${pkg}" && pass "${description}: installed" || {
            warn "Failed to install ${pkg} via dnf"
            return 1
        }
    fi
}

# Core required packages
install_pkg "nmstate"       "nmstate (NIC config for agent-config.yaml)"
install_pkg "bind-utils"    "bind-utils (dig — required by verify-dns-resolution.sh)"
install_pkg "jq"            "jq (JSON processing)"
install_pkg "wget"          "wget"
install_pkg "curl"          "curl"
install_pkg "python3-pip"   "python3-pip"

# yq — not in standard CentOS Stream 10 repos, install via binary download
if command -v yq &>/dev/null; then
    YQ_VER=$(yq --version 2>&1 | awk '{print $NF}')
    pass "yq: already installed (${YQ_VER})"
else
    info "Installing yq (YAML processor)..."
    YQ_VERSION="v4.45.1"
    YQ_BINARY="yq_linux_amd64"
    YQ_URL="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY}"
    if wget -q "${YQ_URL}" -O /usr/local/bin/yq && chmod +x /usr/local/bin/yq; then
        pass "yq: installed (${YQ_VERSION})"
    else
        warn "Could not download yq from GitHub — network access may be restricted"
        warn "  Manual install: wget ${YQ_URL} -O /usr/local/bin/yq && chmod +x /usr/local/bin/yq"
    fi
fi

echo ""

# ── Section 3: AWS CLI ────────────────────────────────────────────────────────
section "AWS CLI"

if command -v aws &>/dev/null; then
    AWS_VER=$(aws --version 2>&1 | awk '{print $1}')
    pass "aws-cli: already installed (${AWS_VER})"
else
    info "Installing AWS CLI via pip3..."
    # Try dnf first (some RHEL variants have it)
    if dnf install -y awscli2 &>/dev/null 2>&1; then
        pass "aws-cli: installed via dnf (awscli2)"
    elif pip3 install --quiet awscli; then
        pass "aws-cli: installed via pip3"
    else
        warn "Could not install AWS CLI — required for hack/configure-route53-dns.sh"
        warn "  Manual install: pip3 install awscli"
    fi
fi

echo ""

# ── Section 4: OpenShift CLI tools ────────────────────────────────────────────
section "OpenShift CLI Tools"

install_openshift_tools() {
    # Detect RHEL-compatible major version
    RHEL_VER=$(rpm -E '%{rhel}' 2>/dev/null || echo "10")
    if [[ "${RHEL_VER}" -le 8 ]]; then
        OC_CHANNEL="stable-4.20"
    else
        OC_CHANNEL="stable-4.20"
    fi

    local OC_BASE_URL="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${OC_CHANNEL}"
    local BIN_DIR="/usr/local/bin"

    info "Downloading OpenShift CLI tools (channel: ${OC_CHANNEL})..."

    # oc + kubectl
    if wget -q "${OC_BASE_URL}/openshift-client-linux.tar.gz" -O /tmp/openshift-client.tar.gz; then
        tar -xzf /tmp/openshift-client.tar.gz -C /tmp/ oc kubectl 2>/dev/null || true
        install -m 755 /tmp/oc "${BIN_DIR}/oc"
        install -m 755 /tmp/kubectl "${BIN_DIR}/kubectl"
        rm -f /tmp/oc /tmp/kubectl /tmp/openshift-client.tar.gz
        pass "oc and kubectl installed to ${BIN_DIR}"
    else
        warn "Failed to download openshift-client — network or mirror access issue"
    fi

    # openshift-install
    if wget -q "${OC_BASE_URL}/openshift-install-linux.tar.gz" -O /tmp/openshift-install.tar.gz; then
        tar -xzf /tmp/openshift-install.tar.gz -C /tmp/ openshift-install 2>/dev/null || true
        install -m 755 /tmp/openshift-install "${BIN_DIR}/openshift-install"
        rm -f /tmp/openshift-install /tmp/openshift-install.tar.gz
        pass "openshift-install installed to ${BIN_DIR}"
    else
        warn "Failed to download openshift-install — network or mirror access issue"
    fi
}

if command -v oc &>/dev/null && command -v openshift-install &>/dev/null; then
    OC_VER=$(oc version --client 2>/dev/null | awk '/Client Version/{print $3}')
    OI_VER=$(openshift-install version 2>/dev/null | awk 'NR==1{print $2}')
    pass "oc: ${OC_VER}"
    pass "openshift-install: ${OI_VER}"

    # Warn if versions differ (can cause manifest incompatibility)
    if [[ "${OC_VER}" != "${OI_VER}" ]]; then
        warn "oc (${OC_VER}) and openshift-install (${OI_VER}) versions differ"
        warn "  This may cause manifest compatibility issues. Consider reinstalling with:"
        warn "  sudo ${0} --skip-kvm --skip-networks  (to re-run only the CLI install)"
    fi
else
    install_openshift_tools
fi

echo ""

# ── Section 5: Ansible collections ────────────────────────────────────────────
section "Ansible Collections"

REQUIREMENTS_FILE="${REPO_ROOT}/playbooks/collections/requirements.yml"

if [[ ! -f "${REQUIREMENTS_FILE}" ]]; then
    die "requirements.yml not found at ${REQUIREMENTS_FILE}"
fi

# Check if Automation Hub token is configured (required for redhat.openshift)
AH_TOKEN=$(grep -A5 '\[galaxy_server.automation_hub\]' "${REPO_ROOT}/ansible.cfg" 2>/dev/null | \
    awk -F= '/^token=/{print $2}' | tr -d ' ' || true)
AH_TOKEN_ENV="${ANSIBLE_GALAXY_SERVER_AUTOMATION_HUB_TOKEN:-}"

if [[ -z "${AH_TOKEN}" && -z "${AH_TOKEN_ENV}" ]]; then
    warn "No Automation Hub token found in ansible.cfg or ANSIBLE_GALAXY_SERVER_AUTOMATION_HUB_TOKEN"
    warn "  redhat.openshift collection (required by all post-install roles) will not be installed"
    warn "  Run after bootstrap: ./hack/setup-automation-hub.sh"
    warn "  Token: https://console.redhat.com/ansible/automation-hub/token"
    INSTALL_GALAXY_ONLY=true
else
    INSTALL_GALAXY_ONLY=false
fi

# Run as the real user so collections install into their home, not root's
GALAXY_CMD="ansible-galaxy collection install -r ${REQUIREMENTS_FILE} --upgrade"

info "Installing Ansible collections from ${REQUIREMENTS_FILE}..."
if sudo -u "${REAL_USER}" ${GALAXY_CMD} 2>/dev/null; then
    pass "Ansible collections installed (including redhat.openshift from Automation Hub)"
elif [[ "${INSTALL_GALAXY_ONLY}" == "true" ]]; then
    # Install only the Galaxy collections (skip redhat.openshift)
    info "Installing Galaxy-only collections (redhat.openshift skipped — no token)..."
    for collection in kubernetes.core containers.podman amazon.aws; do
        sudo -u "${REAL_USER}" ansible-galaxy collection install "${collection}" --upgrade 2>/dev/null && \
            pass "Collection ${collection}: installed" || warn "Collection ${collection}: install failed"
    done
else
    warn "ansible-galaxy collection install encountered errors — check ansible.cfg token"
fi

# Verify key collections
for collection in redhat.openshift kubernetes.core containers.podman amazon.aws; do
    if sudo -u "${REAL_USER}" ansible-galaxy collection list "${collection}" 2>/dev/null | grep -q "${collection}"; then
        COLL_VER=$(sudo -u "${REAL_USER}" ansible-galaxy collection list "${collection}" 2>/dev/null | awk "/${collection}/{print \$2}")
        pass "Collection ${collection}: ${COLL_VER}"
    else
        if [[ "${collection}" == "redhat.openshift" ]]; then
            warn "Collection ${collection}: not installed (run ./hack/setup-automation-hub.sh)"
        else
            warn "Collection ${collection}: not found"
        fi
    fi
done

echo ""

# ── Section 6: KVM host setup ─────────────────────────────────────────────────
if [[ "${SKIP_KVM}" == "true" ]]; then
    warn "Skipping KVM host installation (--skip-kvm)"
else
    section "KVM Host Setup"
    info "Calling hack/install-kvm-host.sh ${VM_DISK}..."
    # Pass the vm-disk as argument; script accepts it as $1
    bash "${SCRIPT_DIR}/install-kvm-host.sh" "${VM_DISK}"
fi

echo ""

# ── Section 7: libvirt networks ───────────────────────────────────────────────
if [[ "${SKIP_NETWORKS}" == "true" ]]; then
    warn "Skipping libvirt network setup (--skip-networks)"
else
    section "libvirt Networks"
    info "Calling hack/setup-libvirt-networks.sh..."
    bash "${SCRIPT_DIR}/setup-libvirt-networks.sh"
fi

echo ""

# ── Section 8: Summary and next steps ─────────────────────────────────────────
section "Bootstrap Complete"

echo ""
echo -e "${BOLD}Machine state after bootstrap:${NC}"
echo ""

# Quick status summary
for check in \
    "virsh version >/dev/null 2>&1 && echo installed || echo missing" \
    "virsh pool-list --all 2>/dev/null | grep -q acp-vms && echo active || echo missing" \
    "virsh net-list --all 2>/dev/null | grep -q acp-provisioning && echo active || echo missing" \
    "systemctl is-active libvirtd 2>/dev/null || echo inactive"; do
    true  # placeholders; print inline below
done

command -v oc &>/dev/null && pass "oc $(oc version --client 2>/dev/null | awk '/Client/{print $3}')" || fail "oc not in PATH"
command -v openshift-install &>/dev/null && pass "openshift-install $(openshift-install version 2>/dev/null | awk 'NR==1{print $2}')" || fail "openshift-install not in PATH"
command -v ansible-playbook &>/dev/null && pass "ansible-playbook $(ansible-playbook --version | awk 'NR==1{print $NF}')" || fail "ansible-playbook not in PATH"
( command -v yq &>/dev/null || [[ -x /usr/local/bin/yq ]] ) && pass "yq $(/usr/local/bin/yq --version 2>&1 | awk '{print $NF}' || yq --version 2>&1 | awk '{print $NF}')" || warn "yq not in PATH"
command -v aws &>/dev/null && pass "aws-cli $(aws --version 2>&1 | awk '{print $1}')" || warn "aws-cli not in PATH"
systemctl is-active libvirtd &>/dev/null && pass "libvirtd: active" || warn "libvirtd: not active"
virsh pool-list --all 2>/dev/null | grep -q "acp-vms" && pass "libvirt pool acp-vms: present" || warn "libvirt pool acp-vms: not found"
virsh net-list --all 2>/dev/null | grep -q "acp-provisioning" && pass "libvirt net acp-provisioning: present" || warn "libvirt net acp-provisioning: not found"

echo ""
echo -e "${BOLD}━━━ Next Steps ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${BOLD}1. Log out and back in${NC} (required for libvirt group membership)"
echo ""
echo -e "  ${BOLD}2. Configure Automation Hub (required for redhat.openshift collection)${NC}"
echo "     Get your token: https://console.redhat.com/ansible/automation-hub/token"
echo "     Then run:  ./hack/setup-automation-hub.sh"
echo ""
echo -e "  ${BOLD}3. Fill in your environment variables${NC}"
echo "     Edit hack/env.sh and set:"
echo "       CLUSTER_NAME   — your cluster name (e.g. acp)"
echo "       BASE_DOMAIN    — your Route53 domain"
echo "       EXTERNAL_IP    — this machine's public IP (IBM Cloud NAT)"
echo "       HOSTED_ZONE_ID — Route53 hosted zone ID"
echo ""
echo "     Then source it:  source ./hack/env.sh"
echo ""
echo -e "  ${BOLD}3. Configure internal DNS (dnsmasq)${NC}"
echo "     sudo -E ./hack/setup-dnsmasq.sh"
echo ""
echo -e "  ${BOLD}4. Create Route53 DNS records${NC}"
echo "     ./hack/configure-route53-dns.sh add"
echo ""
echo -e "  ${BOLD}5. Configure HAProxy (IBM Cloud NAT load balancer)${NC}"
echo "     sudo -E ./hack/configure-haproxy-forwarder.sh"
echo ""
echo -e "  ${BOLD}6. Verify DNS (mandatory gate before VM deployment)${NC}"
echo "     ./hack/verify-dns-resolution.sh"
echo ""
echo -e "  ${BOLD}7. Populate cluster variables (pull secret + SSH key)${NC}"
echo "     Place pull secret at ~/pull-secret.json, then:"
echo "     ./hack/setup-cluster-vars.sh"
echo "     (auto-generates SSH key if missing; populates extra-vars.yml)"
echo ""
echo -e "  ${BOLD}8. Generate agent ISO and deploy VMs${NC}"
echo "     ansible-playbook playbooks/create-installation-media.yml \\"
echo "       -i examples/ibm-cloud-active/inventory.yml \\"
echo "       -e @examples/ibm-cloud-active/extra-vars.yml"
echo "     ./hack/deploy-kvm-vms.sh"
echo ""
echo -e "  See ${BOLD}docs/kvm-developer-guide.md${NC} for the full phase-by-phase walkthrough."
echo ""
if [[ -n "${REAL_USER}" && "${REAL_USER}" != "root" ]]; then
    warn "Remember: log out and back in as '${REAL_USER}' before running virsh/virt-install"
fi
