#!/usr/bin/env bash
# =============================================================================
# hack/vyos-router.sh
# =============================================================================
# Forked from:
#   https://raw.githubusercontent.com/tosin2013/openshift-agent-install/refs/heads/main/hack/vyos-router.sh
# Adapted for acp-deployment:
#   - HARD REQUIREMENT: VyOS router VM is mandatory for ALL KVM deployments (ADR-0019)
#   - VNC graphics (upstream lesson: SPICE not available on all QEMU builds)
#   - VyOS nightly build ISO (more reliable URL pattern)
#   - show_manual_config_instructions() pause before deployment continues
#   - configure_router() polls until VyOS is reachable at 192.168.122.2
#   - hack/verify-dns-resolution.sh enforces VyOS VM running as a pre-deployment gate
#
# Actions:
#   ./hack/vyos-router.sh                  # create VLAN networks + VyOS VM + manual pause (DEFAULT)
#   ACTION=create ./hack/vyos-router.sh    # same as default
#   ACTION=create-networks ./hack/vyos-router.sh  # INTERNAL: VLAN networks only (CI/idempotency use)
#                                                  # WARNING: does NOT satisfy ADR-0019 gate
#   ACTION=delete ./hack/vyos-router.sh    # remove VM + networks
#
# VLAN-to-cluster mapping:
#   VLAN 1924  192.168.49.0/24  VyOS management
#   VLAN 1925  192.168.50.0/24  Converged cluster (examples/ibm-cloud-converged)
#   VLAN 1926  192.168.51.0/24  SNO cluster       (examples/ibm-cloud-sno)
#   acp-storage  192.168.52.0/24  ODF Multus storage
#
# Prerequisites:
#   - libvirt/KVM installed (run hack/bootstrap.sh first)
#   - Cockpit for VyOS console access (installed automatically if missing)
# =============================================================================

set -euo pipefail

ACTION="${ACTION:-create}"

VYOS_VM_NAME="vyos-router"
VYOS_DISK_PATH="/var/lib/libvirt/images/vyos-router.qcow2"
VYOS_DISK_SIZE="20G"
VYOS_RAM_MB=4096
VYOS_CPUS=2

# VyOS nightly build — upstream pattern, more reliable than rolling-release tags
# Auto-updated by upstream: https://github.com/vyos/vyos-nightly-build/releases
VYOS_VERSION="${VYOS_VERSION:-2026.05.30-0046-rolling}"
VYOS_ISO_URL="https://github.com/vyos/vyos-nightly-build/releases/download/${VYOS_VERSION}/vyos-${VYOS_VERSION}-generic-amd64.iso"
VYOS_ISO_PATH="${HOME}/vyos-${VYOS_VERSION}-generic-amd64.iso"
VYOS_ISO_LIBVIRT="/var/lib/libvirt/images/seed.iso"

# NAT VLAN networks — libvirt dnsmasq bridges provide internal DNS for cluster VMs.
# VyOS router VM is required for ALL deployments (ADR-0017, ADR-0019).
declare -A VLAN_NETWORKS=(
  ["1924"]="192.168.49"
  ["1925"]="192.168.50"
  ["1926"]="192.168.51"
)

STORAGE_NET_NAME="acp-storage"
STORAGE_BRIDGE="virbr-acp2"
STORAGE_PREFIX="192.168.52"

# ── Helpers ────────────────────────────────────────────────────────────────────
log()  { echo "$(date '+%H:%M:%S') $*"; }
warn() { echo "$(date '+%H:%M:%S') WARN: $*" >&2; }
err()  { echo "$(date '+%H:%M:%S') ERROR: $*" >&2; exit 1; }

check_prereqs() {
  for cmd in virsh virt-install curl; do
    command -v "$cmd" &>/dev/null || err "Required command not found: $cmd (run hack/bootstrap.sh first)"
  done
  if ! systemctl is-active --quiet libvirtd 2>/dev/null; then
    err "libvirtd is not running. Run: sudo systemctl start libvirtd"
  fi
}

# Returns true if the named network is already active (upstream pattern)
network_active() {
  sudo bash -c "virsh net-list --all | grep -q '^ *$1 *active'"
}

# Returns true if the named network is defined (active or inactive)
network_defined() {
  sudo virsh net-info "$1" &>/dev/null 2>&1
}

vm_exists() {
  sudo virsh dominfo "$1" &>/dev/null 2>&1
}

# ── create_libvirt_networks ────────────────────────────────────────────────────
# Creates VLAN NAT networks and acp-storage. Idempotent — skips active networks.
create_libvirt_networks() {
  log "Creating VLAN libvirt networks..."

  for vlan_id in "${!VLAN_NETWORKS[@]}"; do
    local prefix="${VLAN_NETWORKS[$vlan_id]}"
    local gateway="${prefix}.1"
    local dhcp_start="${prefix}.100"
    local dhcp_end="${prefix}.199"

    if network_active "$vlan_id"; then
      log "Network $vlan_id already active — skipping"
      continue
    fi

    if network_defined "$vlan_id"; then
      log "Network $vlan_id defined but inactive — starting"
      sudo virsh net-start "$vlan_id"
      continue
    fi

    log "Creating NAT network: $vlan_id (${prefix}.0/24, gateway: $gateway)"
    sudo virsh net-define /dev/stdin <<EOF
<network>
  <name>${vlan_id}</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='virbr-${vlan_id}' stp='on' delay='0'/>
  <ip address='${gateway}' netmask='255.255.255.0'>
    <dhcp>
      <range start='${dhcp_start}' end='${dhcp_end}'/>
    </dhcp>
  </ip>
</network>
EOF
    sudo virsh net-autostart "$vlan_id"
    sudo virsh net-start "$vlan_id"
    log "Network $vlan_id created and started"
  done

  # acp-storage — ODF Multus storage network
  if network_active "$STORAGE_NET_NAME"; then
    log "Network $STORAGE_NET_NAME already active — skipping"
  elif network_defined "$STORAGE_NET_NAME"; then
    log "Network $STORAGE_NET_NAME defined but inactive — starting"
    sudo virsh net-start "$STORAGE_NET_NAME"
  else
    log "Creating NAT network: $STORAGE_NET_NAME (${STORAGE_PREFIX}.0/24)"
    sudo virsh net-define /dev/stdin <<EOF
<network>
  <name>${STORAGE_NET_NAME}</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='${STORAGE_BRIDGE}' stp='on' delay='0'/>
  <ip address='${STORAGE_PREFIX}.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='${STORAGE_PREFIX}.10' end='${STORAGE_PREFIX}.50'/>
    </dhcp>
  </ip>
</network>
EOF
    sudo virsh net-autostart "$STORAGE_NET_NAME"
    sudo virsh net-start "$STORAGE_NET_NAME"
    log "Network $STORAGE_NET_NAME created and started"
  fi

  echo ""
  log "Active networks:"
  sudo virsh net-list --all
}

# ── show_manual_config_instructions ───────────────────────────────────────────
# Forked from upstream show_manual_config_instructions() — displays the 8-step
# manual VyOS configuration guide and pauses for user acknowledgment.
show_manual_config_instructions() {
  local host_ip
  host_ip=$(hostname -I | awk '{print $1}')
  local instructions_file="/tmp/vyos-manual-config-instructions.txt"

  cat > "$instructions_file" <<EOFINSTRUCTIONS
============================================================================
⚠️  MANUAL CONFIGURATION REQUIRED — VyOS Router
============================================================================
VyOS boots from a live ISO and requires interactive installation to disk
before network configuration can be applied.
Time required: ~10-15 minutes

📋 STEP 1: Open Cockpit Web Console
   URL:  https://${host_ip}:9090
   Login with your system credentials (${USER})

📋 STEP 2: Open VyOS VM Console
   Virtual Machines → vyos-router → Console tab
   You should see the VyOS live boot prompt.

📋 STEP 3: Install VyOS to disk (in the console)
   Login: vyos / vyos
   Run:
     install image
   Accept all defaults (press ENTER through prompts).
   VM reboots automatically after install.

📋 STEP 4: Restart the VM after reboot
   In Cockpit: Power Off → Run → Console tab
   Wait for the VyOS login prompt (~30-60 s).

📋 STEP 5: Configure network interfaces
   Login: vyos / vyos
   Run:
     configure
     set interfaces ethernet eth0 address 192.168.122.2/24
     set interfaces ethernet eth0 description Internet-Facing
     set protocols static route 0.0.0.0/0 next-hop 192.168.122.1
     commit
     save
     exit

📋 STEP 6: Enable SSH
     configure
     set service ssh port 22
     set service ssh listen-address 0.0.0.0
     commit
     save
     exit
   Test from host: ping -c 3 192.168.122.2

📋 STEP 7: Copy and apply the VyOS config script from the host
   (Run these commands on the hypervisor, not inside VyOS)
     curl -sSL https://raw.githubusercontent.com/tosin2013/demo-virt/rhpds/demo.redhat.com/vyos-config-1.5.sh \\
       -o ~/vyos-config.sh
     sed -i 's/1.1.1.1/192.168.122.1/g' ~/vyos-config.sh
     chmod +x ~/vyos-config.sh
     scp ~/vyos-config.sh vyos@192.168.122.2:/tmp/
     ssh vyos@192.168.122.2 'chmod +x /tmp/vyos-config.sh && vbash /tmp/vyos-config.sh'

📋 STEP 8: Verify VyOS configuration
   ping -c 3 192.168.122.2
   ping -c 3 192.168.50.1

   Full guide: https://tosin2013.github.io/openshift-agent-install/vyos-manual-configuration.html
============================================================================
EOFINSTRUCTIONS

  cat "$instructions_file"
  echo ""
  echo "Instructions saved to: $instructions_file"
  echo ""
  echo "════════════════════════════════════════════════════════════════════"
  echo "  After completing Steps 1-7, this script will automatically"
  echo "  detect VyOS at 192.168.122.2 and continue."
  echo "════════════════════════════════════════════════════════════════════"
  echo ""
  if [[ -t 0 ]]; then
    read -rp "Press ENTER to launch the VyOS VM and begin manual configuration..."
  else
    log "Non-interactive mode — proceeding to VM creation."
  fi
  echo ""
}

# ── configure_router ───────────────────────────────────────────────────────────
# Forked from upstream configure_router() — polls until VyOS is accessible at
# 192.168.122.2, then adds host routes so VLAN networks are reachable via VyOS.
configure_router() {
  local max_wait=1800    # 30 minutes
  local interval=300     # check every 5 minutes
  local vyos_ip="192.168.122.2"
  local start_time end_time

  start_time=$(date +%s)
  end_time=$((start_time + max_wait))

  echo ""
  log "Waiting for VyOS at ${vyos_ip} (up to 30 min — complete Steps 1-7 above)..."
  echo ""

  local check=0
  while true; do
    if ping -c 1 -W 2 "$vyos_ip" &>/dev/null 2>&1; then
      echo ""
      log "✅ VyOS is accessible at ${vyos_ip} — adding host routes..."
      break
    fi

    local remaining=$(( end_time - $(date +%s) ))
    if [[ $remaining -le 0 ]]; then
      echo ""
      echo "════════════════════════════════════════════════════════════════════"
      echo "❌ Timeout after 30 minutes — VyOS still not accessible."
      echo "   Troubleshooting:"
      echo "     sudo virsh list                    # verify VM is running"
      echo "     https://$(hostname -I | awk '{print $1}'):9090   # Cockpit console"
      echo "   Re-run after manual config: ACTION=create ./hack/vyos-router.sh"
      echo "════════════════════════════════════════════════════════════════════"
      return 1
    fi

    check=$((check + 1))
    log "Check #${check}: VyOS not yet reachable. ${remaining}s remaining."
    log "  Access Cockpit: https://$(hostname -I | awk '{print $1}'):9090"
    sleep "$interval"
  done

  # Add host routes so the hypervisor can reach VLAN networks through VyOS
  local vlan_networks=("192.168.49.0/24" "192.168.50.0/24" "192.168.51.0/24" "192.168.52.0/24")
  for net in "${vlan_networks[@]}"; do
    if ! ip route show | grep -q "$net"; then
      sudo ip route add "$net" via "$vyos_ip" && log "Route added: $net via $vyos_ip"
    else
      log "Route already present: $net via $vyos_ip"
    fi
  done

  log "✅ VyOS router configuration complete."
}

# ── do_create_networks ─────────────────────────────────────────────────────────
# Creates VLAN libvirt networks only — no VyOS VM. Used by deploy-cluster.sh
# by default because VLAN networks (with libvirt dnsmasq NAT) are sufficient
# for single-cluster deployment without cross-cluster routing.
do_create_networks() {
  log "Creating VLAN networks (VyOS VM skipped — use ACTION=create for full setup)"
  check_prereqs
  create_libvirt_networks
  echo ""
  echo "============================================================"
  echo "  VLAN Networks Ready"
  echo "============================================================"
  echo "  1924  192.168.49.0/24  (VyOS management — unused without VM)"
  echo "  1925  192.168.50.0/24  (Converged cluster)"
  echo "  1926  192.168.51.0/24  (SNO cluster)"
  echo "  acp-storage  192.168.52.0/24  (ODF Multus)"
  echo ""
  echo "  To set up the VyOS router VM for cross-cluster routing:"
  echo "    ACTION=create ./hack/vyos-router.sh"
  echo "============================================================"
}

# ── do_create ─────────────────────────────────────────────────────────────────
# Full setup: networks + VyOS VM + manual configuration pause + route injection.
do_create() {
  check_prereqs

  # Install Cockpit if not present (needed for VyOS console)
  if ! systemctl is-active --quiet cockpit.socket 2>/dev/null; then
    log "Installing Cockpit for VyOS console access..."
    sudo dnf install -y cockpit cockpit-machines --quiet
    sudo systemctl enable --now cockpit.socket
    # Only touch firewalld if it is running
    if systemctl is-active --quiet firewalld 2>/dev/null; then
      sudo firewall-cmd --add-service=cockpit --permanent --quiet
      sudo firewall-cmd --reload --quiet
    else
      log "firewalld not running — skipping firewall-cmd (Cockpit still accessible)"
    fi
  fi
  log "Cockpit accessible at: https://$(hostname -I | awk '{print $1}'):9090"

  create_libvirt_networks

  # Download VyOS nightly ISO (cached to ~/vyos-*.iso)
  if [[ ! -f "${VYOS_ISO_PATH}" ]]; then
    log "Downloading VyOS nightly ISO: ${VYOS_VERSION}"
    log "URL: ${VYOS_ISO_URL}"
    curl -L --progress-bar -o "${VYOS_ISO_PATH}" "${VYOS_ISO_URL}" || {
      echo ""
      log "Download failed. Check releases at: https://github.com/vyos/vyos-nightly-build/releases"
      log "Override version: VYOS_VERSION=<tag> ./hack/vyos-router.sh"
      err "VyOS ISO download failed"
    }
    log "VyOS ISO downloaded: ${VYOS_ISO_PATH}"
  else
    log "VyOS ISO cached: ${VYOS_ISO_PATH}"
  fi

  # Copy to libvirt images (virt-install uses the libvirt path)
  if [[ ! -f "${VYOS_ISO_LIBVIRT}" ]]; then
    sudo cp "${VYOS_ISO_PATH}" "${VYOS_ISO_LIBVIRT}"
    log "ISO staged: ${VYOS_ISO_LIBVIRT}"
  fi

  # Create VM disk
  if [[ ! -f "${VYOS_DISK_PATH}" ]]; then
    log "Creating VyOS VM disk: ${VYOS_DISK_PATH} (${VYOS_DISK_SIZE})"
    sudo qemu-img create -f qcow2 "${VYOS_DISK_PATH}" "${VYOS_DISK_SIZE}" -q
  else
    log "VyOS VM disk already exists: ${VYOS_DISK_PATH}"
  fi

  # Show manual config instructions and pause
  show_manual_config_instructions

  # Create VyOS VM (upstream uses debian10 + VNC — avoids SPICE requirement)
  if vm_exists "${VYOS_VM_NAME}"; then
    log "VyOS VM already exists: ${VYOS_VM_NAME}"
  else
    log "Creating VyOS VM: ${VYOS_VM_NAME}"
    # MAC address generation mirrors upstream pattern
    local vyos_mac
    vyos_mac=$(date +%s | md5sum | head -c 6 | sed -e 's/\([0-9A-Fa-f]\{2\}\)/\1:/g' -e 's/\(.*\):$/\1/' | sed -e 's/^/52:54:00:/')
    sudo virt-install \
      --name "${VYOS_VM_NAME}" \
      --ram "${VYOS_RAM_MB}" \
      --vcpus "${VYOS_CPUS}" \
      --disk "path=${VYOS_DISK_PATH},format=qcow2,bus=virtio" \
      --cdrom "${VYOS_ISO_LIBVIRT}" \
      --os-variant debian10 \
      --network "network=default,model=e1000e,mac=${vyos_mac}" \
      --network "network=1924,model=e1000e" \
      --network "network=1925,model=e1000e" \
      --network "network=1926,model=e1000e" \
      --graphics vnc \
      --hvm \
      --virt-type kvm \
      --noautoconsole \
      --boot cdrom,hd
    log "VyOS VM created — access via Cockpit console to complete installation"
  fi

  # Poll until VyOS is accessible (user completes manual steps)
  configure_router

  echo ""
  echo "============================================================"
  echo "  VyOS Router Setup Complete"
  echo "============================================================"
  echo "  VM:           ${VYOS_VM_NAME}"
  echo "  VyOS IP:      192.168.122.2"
  echo "  Networks:     1924, 1925, 1926, acp-storage"
  echo "  Cockpit:      https://$(hostname -I | awk '{print $1}'):9090"
  echo ""
  echo "  Guide: https://tosin2013.github.io/openshift-agent-install/vyos-manual-configuration.html"
  echo "============================================================"
}

# ── do_delete ─────────────────────────────────────────────────────────────────
do_delete() {
  log "Removing VyOS VM and all VLAN networks..."

  if vm_exists "${VYOS_VM_NAME}"; then
    sudo virsh destroy "${VYOS_VM_NAME}" 2>/dev/null || true
    sudo virsh undefine "${VYOS_VM_NAME}" --remove-all-storage 2>/dev/null || true
    log "VM removed: ${VYOS_VM_NAME}"
  fi
  [[ -f "${VYOS_DISK_PATH}" ]]      && sudo rm -f "${VYOS_DISK_PATH}"      && log "Disk removed"
  [[ -f "${VYOS_ISO_LIBVIRT}" ]]    && sudo rm -f "${VYOS_ISO_LIBVIRT}"    && log "Staged ISO removed"

  for vlan_id in "${!VLAN_NETWORKS[@]}"; do
    if network_defined "$vlan_id"; then
      sudo virsh net-destroy "$vlan_id" 2>/dev/null || true
      sudo virsh net-undefine "$vlan_id" 2>/dev/null || true
      log "Network removed: $vlan_id"
    fi
  done

  if network_defined "$STORAGE_NET_NAME"; then
    sudo virsh net-destroy "$STORAGE_NET_NAME" 2>/dev/null || true
    sudo virsh net-undefine "$STORAGE_NET_NAME" 2>/dev/null || true
    log "Network removed: $STORAGE_NET_NAME"
  fi

  log "VyOS cleanup complete."
}

# ── Main ───────────────────────────────────────────────────────────────────────
case "${ACTION}" in
  create)          do_create ;;
  create-networks) do_create_networks ;;
  delete)          do_delete ;;
  *)               err "Unknown ACTION: ${ACTION}. Use 'create', 'create-networks', or 'delete'." ;;
esac
