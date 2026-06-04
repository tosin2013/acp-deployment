# KVM Developer Guide: ACP Deployment on IBM Cloud Bare Metal

This guide walks through deploying an OpenShift Container Platform (OCP) cluster on an IBM Cloud bare-metal server using KVM virtual machines. The server acts as both the KVM hypervisor and the Ansible helper node.

> **Architecture decisions**: See [ADR-0014](adrs/adr-0014-ibm-cloud-bare-metal-as-kvm-host-and-helper.md) (combined host/helper), [ADR-0015](adrs/adr-0015-haproxy-external-access-ibm-cloud.md) (HAProxy), [ADR-0016](adrs/adr-0016-route53-external-dns-ibm-cloud.md) (Route53), [ADR-0017](adrs/adr-0017-dnsmasq-internal-kvm-cluster-dns.md) (dnsmasq), [ADR-0018](adrs/adr-0018-mandatory-dns-verification-gate.md) (DNS gate).

---

## Host Requirements

Edge topologies — choose based on your KVM host resources. `hack/select-cluster-topology.sh` auto-detects:

| Resource | SNO (minimum) | Converged (minimum) | Converged + OCP Virt |
|----------|--------------|---------------------|---------------------|
| OS | CentOS Stream 10 | CentOS Stream 10 | CentOS Stream 10 |
| CPUs | 8 cores | 24 cores | 24 cores |
| RAM | 32 GB | 96 GB | 128 GB |
| OS disk | `/dev/vda` ≥ 50 GB | `/dev/vda` ≥ 50 GB | `/dev/vda` ≥ 50 GB |
| VM disk | `/dev/vdb` ≥ 120 GB | `/dev/vdb` ≥ 360 GB | `/dev/vdb` ≥ 360 GB |
| Network | Public IP via NAT | Public IP via NAT | Public IP via NAT |
| AWS credentials | Route53 write access | Route53 write access | Route53 write access |

---

## Quick Start (Bootstrap)

For a **fresh machine**, two phases get you to a running cluster:

### Phase A — One-time host setup

```bash
# 1. Install tools, KVM stack, storage pool (log out and back in after this)
sudo ./hack/bootstrap.sh

# 2. Configure Red Hat Automation Hub credentials
./hack/setup-automation-hub.sh
# Get your token: https://console.redhat.com/ansible/automation-hub/token
```

> **Options:**
> ```bash
> sudo ./hack/bootstrap.sh --vm-disk /dev/vdb    # default; change if your disk differs
> sudo ./hack/bootstrap.sh --skip-kvm             # skip KVM install (already done)
> ```

### Phase B — Deploy the cluster (single command)

```bash
# Fill in hack/env.sh first, then:
source hack/env.sh

# Full deployment — SNO or Converged auto-selected, all steps run in order:
./hack/deploy-cluster.sh

# Common overrides:
./hack/deploy-cluster.sh --topology converged          # force converged topology
./hack/deploy-cluster.sh --topology converged --ocp-virt  # with OCP Virtualization
./hack/deploy-cluster.sh --skip-cert-manager           # skip ZeroSSL (configure later)
./hack/deploy-cluster.sh --skip-post-install           # stop after install-complete
```

`deploy-cluster.sh` runs all 13 steps in order (networks → DNS → VMs → install → post-install), pauses once for you to fill in MAC addresses after VM creation, then continues unattended. It is safe to re-run if interrupted.

> **Manual step-by-step path**: If you prefer to run each phase individually, see the numbered Phase sections below (Phase 1 through Phase 9).

---

## Environment Variables

All sensitive values are passed as environment variables. **Never hardcode real values in committed files.**

Create your local environment file (already in `.gitignore` by convention):

```bash
# Copy the template and fill in your values
cp hack/env.sh /tmp/my-acp-env.sh
```

Or export directly in your shell:

```bash
export CLUSTER_NAME="acp"
export BASE_DOMAIN="<YOUR_BASE_DOMAIN>"      # e.g. sandbox3377.opentlc.com
export EXTERNAL_IP="<YOUR_EXTERNAL_IP>"      # IBM Cloud public IP (NAT'd)
export HOSTED_ZONE_ID="<YOUR_ZONE_ID>"       # Route53 hosted zone ID
export API_VIP="192.168.50.253"              # Internal libvirt VIP (do not change)
export INGRESS_VIP="192.168.50.252"          # Internal libvirt VIP (do not change)
```

> **IBM Cloud NAT note**: `EXTERNAL_IP` is the public IP assigned by IBM Cloud, not the private `eth0` IP (`10.x.x.x`). Route53 records and HAProxy references use the public IP.

Source the template before running any script:

```bash
source hack/env.sh
```

---

## Phase -1: Prerequisites and Tool Installation

> **Skip this phase if you ran `sudo ./hack/bootstrap.sh`** — it performs all of the steps below automatically.

Install the developer tools required to run Ansible playbooks, interact with the OpenShift cluster, and manage Route53 DNS.

### System packages

```bash
sudo dnf install -y nmstate bind-utils jq wget curl python3-pip
```

| Package | Required by |
|---------|-------------|
| `nmstate` | Agent ISO NIC configuration (`agent-config.yaml`) |
| `bind-utils` | `dig` — used by `verify-dns-resolution.sh` |
| `jq` | JSON processing in scripts |

### yq (YAML processor)

```bash
sudo wget https://github.com/mikefarah/yq/releases/download/v4.45.1/yq_linux_amd64 \
  -O /usr/local/bin/yq && sudo chmod +x /usr/local/bin/yq
```

### AWS CLI

```bash
pip3 install awscli   # if not available via: sudo dnf install -y awscli2
aws --version         # verify
```

### OpenShift CLI tools

`oc`, `kubectl`, and `openshift-install` are downloaded from the Red Hat mirror. The bootstrap script detects the RHEL major version and selects `stable-4.21`:

```bash
OC_URL="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable-4.21"
wget "${OC_URL}/openshift-client-linux.tar.gz" -O /tmp/oc.tar.gz
sudo tar -xzf /tmp/oc.tar.gz -C /usr/local/bin/ oc kubectl
wget "${OC_URL}/openshift-install-linux.tar.gz" -O /tmp/oi.tar.gz
sudo tar -xzf /tmp/oi.tar.gz -C /usr/local/bin/ openshift-install

oc version --client && openshift-install version
```

### Ansible collections

All post-install roles (`openshift_data_foundation`, `ansible_automation_platform`, `update_ocp_ingress_cert`, etc.) use the `redhat.openshift.k8s` module, which is only available from [Red Hat Automation Hub](https://cloud.redhat.com/ansible/automation-hub/) — not Ansible Galaxy. A Red Hat subscription is required.

**Step 1: Get your Automation Hub token**

1. Go to [console.redhat.com/ansible/automation-hub/token](https://console.redhat.com/ansible/automation-hub/token)
2. Click **Load token**
3. Copy the token string

**Step 2: Configure and install**

```bash
./hack/setup-automation-hub.sh
# Prompts for your token, writes it to ansible.cfg, then installs all collections
```

This is equivalent to running manually:
```bash
# Write token to ansible.cfg (ansible.cfg is gitignored — token never committed)
# Then:
ansible-galaxy collection install -r playbooks/collections/requirements.yml --upgrade
```

Collections installed:

| Collection | Source | Used by |
|-----------|--------|---------|
| `redhat.openshift` | Automation Hub (subscription) | All post-install roles (`k8s` module) |
| `kubernetes.core` | Ansible Galaxy | Dependency of redhat.openshift |
| `containers.podman` | Ansible Galaxy | DNS role (BIND-in-Podman for bare-metal) |
| `amazon.aws` | Ansible Galaxy | cert-manager Route53 DNS-01 solver |

Verify:

```bash
ansible-galaxy collection list | grep -E "redhat|containers|amazon|kubernetes"
```

> **Note**: `ansible.cfg` is listed in `.gitignore` because it contains your Automation Hub token. Each developer must run `./hack/setup-automation-hub.sh` once on their machine. Alternatively, export `ANSIBLE_GALAXY_SERVER_AUTOMATION_HUB_TOKEN=<token>` in your shell profile.

---

## Phase 0: KVM Host Installation

> **Skip if you ran `sudo ./hack/bootstrap.sh`** — it calls `install-kvm-host.sh` automatically.

Install the KVM/libvirt stack on CentOS Stream 10 and configure `/dev/vdb` as the VM storage pool.

```bash
sudo ./hack/install-kvm-host.sh
```

This script:
- Installs `qemu-kvm`, `libvirt`, `virt-install`, `libvirt-client`, `dnsmasq`, `haproxy`
- Creates libvirt storage pool `acp-vms` on `/dev/vdb` (ext4-formatted, mounted at `/var/lib/libvirt/acp-vms`)
- Enables nested virtualisation (`kvm_intel nested=1`) for OpenShift Virtualization workloads
- Adds your user to the `libvirt` group

**Important:** Log out and back in after this step for the `libvirt` group to take effect.

Verify:

```bash
virsh version
virsh pool-list --all    # Should show 'acp-vms' as active
cat /sys/module/kvm_intel/parameters/nested  # Should be 'Y'
```

---

## Phase 1: libvirt Network Setup (VyOS-First)

> **VyOS-first architecture**: Provisioning VLANs are now created by `hack/vyos-router.sh`.
> `hack/setup-libvirt-networks.sh` is **deprecated for provisioning** and now creates the ODF storage network only.

Create the VLAN networks and the ODF storage network:

```bash
# Creates provisioning VLANs + acp-storage + VyOS router VM
sudo ./hack/vyos-router.sh

# acp-storage only (idempotent — already created by vyos-router.sh; kept for clarity)
# sudo ./hack/setup-libvirt-networks.sh
```

Networks created by `vyos-router.sh`:

| Network | Bridge | CIDR | Purpose |
|---------|--------|------|---------|
| `1924` | `virbr-1924` | `192.168.49.0/24` | VyOS management |
| `1925` | `virbr-1925` | `192.168.50.0/24` | Converged cluster provisioning (API `.253`, Ingress `.252`) |
| `1926` | `virbr-1926` | `192.168.51.0/24` | SNO cluster provisioning (API `.253`, Ingress `.252`) |
| `acp-storage` | `virbr-acp2` | `192.168.52.0/24` | ODF Multus storage network |

The `deploy-kvm-vms.sh` script auto-detects which VLAN to use based on the active topology symlink:
- `examples/ibm-cloud-active` → `ibm-cloud-converged` → VMs on VLAN `1925`
- `examples/ibm-cloud-active` → `ibm-cloud-sno` → VMs on VLAN `1926`

> **VyOS VM — HARD REQUIREMENT**: The VyOS router VM must be configured via Cockpit before any cluster VMs are created. Follow `docs/vyos-setup.md` (~10–15 min). `hack/verify-dns-resolution.sh` (called automatically by `deploy-kvm-vms.sh`) will fail with a clear error if `vyos-router` is not running. See ADR-0019.

Verify:

```bash
virsh net-list --all    # Should show 1924, 1925, 1926, acp-storage as active
ip -br addr show | grep virbr    # Bridge IPs visible
```

---

## Phase 2: Internal DNS Setup (dnsmasq)

Configure dnsmasq to serve cluster FQDNs to VMs on the active VLAN network.
`setup-dnsmasq.sh` auto-detects the active topology from the `ibm-cloud-active` symlink:
- Converged → injects records into VLAN `1925` dnsmasq (gateway `192.168.50.1`)
- SNO → injects records into VLAN `1926` dnsmasq (gateway `192.168.51.1`)

```bash
source hack/env.sh
sudo -E ./hack/setup-dnsmasq.sh
```

Records injected into the libvirt network's built-in dnsmasq:
- `api.${CLUSTER_NAME}.${BASE_DOMAIN}` → API VIP
- `api-int.${CLUSTER_NAME}.${BASE_DOMAIN}` → API VIP
- `*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}` → Ingress VIP

Verify internal DNS (converged example):

```bash
dig @192.168.50.1 api.${CLUSTER_NAME}.${BASE_DOMAIN} +short
# Expected: 192.168.50.253
```

---

## Phase 3: External DNS (Route53)

Create Route53 A records so developer workstations and CI can reach the cluster through HAProxy.

```bash
source hack/env.sh
./hack/configure-route53-dns.sh add
```

Records created:

| FQDN | Value | Purpose |
|------|-------|---------|
| `api.<cluster>.<domain>` | `<EXTERNAL_IP>` | Kubernetes API access |
| `api-int.<cluster>.<domain>` | `<EXTERNAL_IP>` | Machine Config Server |
| `*.apps.<cluster>.<domain>` | `<EXTERNAL_IP>` | Application ingress |

> TTL is 60 seconds for fast development iteration.

Verify external DNS (after ~60 seconds):

```bash
dig @8.8.8.8 api.${CLUSTER_NAME}.${BASE_DOMAIN} +short
# Expected: <EXTERNAL_IP>
```

**Teardown**: Remove records when the cluster is no longer needed:

```bash
./hack/configure-route53-dns.sh delete
```

---

## Phase 4: HAProxy External Access

Install and configure HAProxy as the TCP load balancer for external cluster access.

```bash
source hack/env.sh
sudo -E ./hack/configure-haproxy-forwarder.sh
```

> **IBM Cloud NAT critical detail**: HAProxy binds to `0.0.0.0`, not to the private IP. IBM Cloud's NAT translates the public IP to the private IP before the packet reaches `eth0`, so a process bound to the private IP only will not receive the traffic.

Ports configured:

| Port | Destination | Purpose |
|------|-------------|---------|
| `6443` | `192.168.50.253:6443` | Kubernetes API |
| `22623` | `192.168.50.253:22623` | Machine Config Server |
| `80` | `192.168.50.252:80` | HTTP application routes |
| `443` | `192.168.50.252:443` | HTTPS application routes |
| `8404` | localhost | HAProxy stats dashboard |

Verify:

```bash
systemctl is-active haproxy
# Open in browser: http://<EXTERNAL_IP>:8404/ (stats dashboard)
```

---

## Phase 5: DNS Verification Gate

Before creating any VMs, validate that both DNS systems are configured correctly. **This is a mandatory step** — DNS failures discovered during install require full VM teardown and ISO regeneration (30–60 minute recovery cycle).

```bash
source hack/env.sh
./hack/verify-dns-resolution.sh
```

Expected output:

```
═══════════════════════════════════════════════════════
   ACP DNS Verification Gate
═══════════════════════════════════════════════════════
  ✓ dnsmasq.service is active
  ✓ api.<cluster>.<domain> → 192.168.50.253
  ✓ api-int.<cluster>.<domain> → 192.168.50.253
  ✓ test.apps.<cluster>.<domain> → 192.168.50.252
  ✓ api.<cluster>.<domain> → <EXTERNAL_IP>
  ✓ test.apps.<cluster>.<domain> → <EXTERNAL_IP>

   ALL DNS CHECKS PASSED — safe to deploy VMs
```

If any check fails, fix the indicated issue and re-run before proceeding.

---

## Phase 6: Populate Cluster Variables

Run the setup script — it handles the pull secret, SSH key, and base domain automatically:

```bash
# Prerequisites:
#   ~/pull-secret.json  — from https://console.redhat.com/openshift/install/pull-secret
#   hack/env.sh sourced — provides CLUSTER_NAME and BASE_DOMAIN

source hack/env.sh
./hack/setup-cluster-vars.sh
```

What `setup-cluster-vars.sh` does:
- **SSH key**: generates `~/.ssh/acp_id_ed25519` if no SSH key exists; uses the first found key if one is already present
- **Pull secret**: reads and compacts `~/pull-secret.json` into a single-line JSON string
- **`examples/ibm-cloud-converged/extra-vars.yml`**: writes `cluster_name`, `base_domain`, `pull_secret`, `ssh_pub_key`
- **`examples/ibm-cloud-sno/extra-vars.yml`**: same
- **`.gitignore`**: adds both `extra-vars.yml` files so secrets are never committed

> MAC addresses remain as `<FILL_FROM_deploy-kvm-vms.sh>` placeholders — these are filled in Phase 7 after VMs are created.

**Select topology** (auto-detects host resources, sets `examples/ibm-cloud-active` symlink):

```bash
./hack/select-cluster-topology.sh
# Or with OCP Virt sizing: OPENSHIFT_VIRT=true ./hack/select-cluster-topology.sh
```

**Generate the agent ISO** (before VM creation — MACs filled in after):

```bash
ansible-playbook playbooks/create-installation-media.yml \
  -i examples/ibm-cloud-active/inventory.yml \
  -e @examples/ibm-cloud-active/extra-vars.yml
```

The ISO is generated at `~/cluster_acp/install/agent.x86_64.iso`.

---

## Phase 7: Deploy VMs and Install OpenShift

Create the three KVM VMs and begin cluster installation:

```bash
source hack/env.sh
./hack/deploy-kvm-vms.sh
```

> The script automatically runs `verify-dns-resolution.sh` as the first step. VM creation is blocked if DNS checks fail.

After VM creation, the script prints MAC addresses (network auto-detected from symlink):

```
═══════════════════════════════════════════════════════
   VM MAC Addresses — copy into extra-vars.yml
═══════════════════════════════════════════════════════

  Node: control-0
    eth0 (VLAN 1925) mac_address: 52:54:00:xx:xx:xx
    eth2 (acp-storage) mac_address: 52:54:00:yy:yy:yy
  ...
```

Update `examples/ibm-cloud-active/extra-vars.yml` with the actual MAC addresses, then regenerate the ISO:

```bash
ansible-playbook playbooks/create-installation-media.yml \
  -i examples/ibm-cloud-active/inventory.yml \
  -e @examples/ibm-cloud-active/extra-vars.yml
```

The VMs detect the updated ISO and will reboot into cluster installation automatically (if using a virtio CDROM that updates on the fly), or manually restart the VMs:

```bash
for vm in control-0 control-1 control-2; do virsh reboot $vm; done
```

---

## Phase 8: Monitor Installation

```bash
export KUBECONFIG=~/cluster_acp/install/auth/kubeconfig

# Wait for install to complete (45–90 minutes)
openshift-install agent wait-for install-complete \
  --dir ~/cluster_acp/install --log-level=info
```

Monitor individual VMs:

```bash
virsh console control-0   # Ctrl+] to exit
```

Watch API availability:

```bash
watch -n 30 "oc get nodes 2>/dev/null || echo 'API not yet available'"
```

---

## Phase 8a: Enable Workload Scheduling (Converged only)

> **Skip this phase for SNO** — single node is already schedulable.

On a converged cluster, OpenShift's default `NoSchedule` taint on control-plane nodes prevents any workloads (including OCP Virt, AAP, ODF) from scheduling. This must be removed before running post-install playbooks.

```bash
source hack/env.sh
./hack/configure-converged-scheduling.sh
```

This script:
1. Patches the OpenShift Scheduler CR: `mastersSchedulable: true`
2. Waits for all cluster operators to become `Available` (up to 15 min)
3. Verifies no control nodes retain the `NoSchedule` taint

---

## Phase 9: Post-Install Playbooks

All post-install playbooks require the kubeconfig and AWS credentials (for cert-manager Route53 DNS-01):

```bash
export KUBECONFIG=~/cluster_acp/install/auth/kubeconfig
export AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id)
export AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key)
```

### Option A: All-in-one (recommended)

Run every post-install playbook in a single command using the master orchestrator:

```bash
ansible-playbook playbooks/site-post-install.yml \
  -i examples/ibm-cloud-active/inventory.yml \
  -e @examples/ibm-cloud-active/extra-vars.yml
```

> **ZeroSSL not yet configured?** Pass `-e skip_cert_manager=true` to bypass cert-manager. Remove the flag once ZeroSSL EAB credentials are set in `extra-vars.yml`.
> ```bash
> ansible-playbook playbooks/site-post-install.yml \
>   -i examples/ibm-cloud-active/inventory.yml \
>   -e @examples/ibm-cloud-active/extra-vars.yml \
>   -e skip_cert_manager=true
> ```

Playbooks run in this dependency order:
1. `setup-openshift-storage.yml` — Local Storage Operator + ODF (must run first; AAP depends on its storage class)
2. `update-ocp-ingress-cert.yml` — cert-manager + ZeroSSL TLS for ingress and API (skipped when `skip_cert_manager=true`)
3. `setup-openshift-pipelines.yml` — Tekton Pipelines operator
4. `setup-ansible-automation-platform.yml` — AAP (uses ODF `ocs-storagecluster-ceph-rbd` storage class)
5. `setup-openshift-virtualization.yml` — KubeVirt (only runs when `install_openshift_virtualization: true` in extra-vars.yml)

> **SNO note**: ODF requires 3 nodes and does not install on SNO. AAP needs persistent storage — configure an NFS or hostPath StorageClass before running AAP on SNO.

### Option B: Individual playbooks

Run each playbook separately if you need to re-run or skip specific steps:

```bash
# 1. Storage (LSO + ODF) — must be first
ansible-playbook playbooks/setup-openshift-storage.yml \
  -i examples/ibm-cloud-active/inventory.yml \
  -e @examples/ibm-cloud-active/extra-vars.yml

# 2. Cert-manager and TLS (ZeroSSL via Route53 DNS-01)
ansible-playbook playbooks/update-ocp-ingress-cert.yml \
  -i examples/ibm-cloud-active/inventory.yml \
  -e @examples/ibm-cloud-active/extra-vars.yml

# 3. OpenShift Pipelines (Tekton)
ansible-playbook playbooks/setup-openshift-pipelines.yml \
  -i examples/ibm-cloud-active/inventory.yml \
  -e @examples/ibm-cloud-active/extra-vars.yml

# 4. Ansible Automation Platform
ansible-playbook playbooks/setup-ansible-automation-platform.yml \
  -i examples/ibm-cloud-active/inventory.yml \
  -e @examples/ibm-cloud-active/extra-vars.yml

# 5. OpenShift Virtualization (optional — set install_openshift_virtualization: true first)
ansible-playbook playbooks/setup-openshift-virtualization.yml \
  -i examples/ibm-cloud-active/inventory.yml \
  -e @examples/ibm-cloud-active/extra-vars.yml
```

---

## Cluster Access

```bash
# API access (from any machine with Route53 resolution)
export KUBECONFIG=~/cluster_acp/install/auth/kubeconfig
oc get nodes

# Console URL
oc whoami --show-console

# Default admin password (kubeadmin)
cat ~/cluster_acp/install/auth/kubeadmin-password
```

---

## Cleanup

When the cluster is no longer needed:

```bash
# 1. Delete VMs
for vm in control-0 control-1 control-2; do
  virsh destroy $vm 2>/dev/null; virsh undefine $vm --remove-all-storage 2>/dev/null
done

# 2. Remove Route53 DNS records
source hack/env.sh
./hack/configure-route53-dns.sh delete

# 3. Stop HAProxy (optional — leave running for next cluster)
sudo systemctl stop haproxy

# 4. Clean cluster artifacts
rm -rf ~/cluster_acp/
```

---

## Bare-Metal Transition Checklist

Ready-to-fill reference configurations are in:
- [`examples/bare-metal-converged/`](../examples/bare-metal-converged/) — 3-node converged, bonded NICs, NVMe ODF, BIND-in-Podman DNS
- [`examples/bare-metal-sno/`](../examples/bare-metal-sno/) — Single node SNO, bonded NIC option, NVMe OS disk

| Item | KVM (ibm-cloud-*) | Bare Metal (bare-metal-*) |
|------|-----------------|------------|
| `installation_device` | `/dev/vda` (virtio) | `/dev/nvme0n1` or `by-path` stable path |
| Primary NIC | `eth0` (virtio) | `eno1` or bonded `bond0` (LACP 802.3ad) |
| Bonding | Not configured | `mode=802.3ad` (switch LACP) or `mode=active-backup` |
| Storage NIC | `eth2` | `bond1` (`ens3f0`+`ens3f1`) or `ens3f0` |
| `api_address` / `ingress_address` | `192.168.50.253/252` (VyOS VLAN 1925) | Real network VIPs from your IP plan |
| `machine_network.cidr` | `192.168.50.0/24` | Physical provisioning network CIDR |
| HAProxy | On KVM host (`0.0.0.0` binding) | Dedicated LB or MetalLB |
| DNS | libvirt dnsmasq on VLAN bridge + Route53 | BIND-in-Podman on helper (ADR-0008) or enterprise DNS |
| `external_dns` | `true` (Route53) | `false` (BIND-in-Podman handles both internal + external) |
| Helper node | `localhost` (`ansible_connection: local`) | Dedicated RHEL helper (`ansible_connection: ssh`) |
| ISO boot | libvirt CDROM | Redfish virtual media (iDRAC/iLO) |
| ISO delivery | `deploy-kvm-vms.sh` | `deploy-on-baremetal.sh` + `nodes.yml` BMC config |
| ODF disks | `vdb`, `vdc` qcow2 — Converged only | Physical NVMe, no partition table |

**Key gotchas:**
- MAC addresses come from hardware labels/BIOS on bare metal — fill into `extra-vars.yml` before generating the ISO (no `deploy-kvm-vms.sh` MAC discovery step).
- Bare-metal NIC names vary by vendor (`ens3f0`, `eno1`, `enp3s0f0`); verify with `ip link` on each node via BMC serial console before generating the ISO.
- ODF on bare metal requires at least 3 dedicated NVMe drives per node with **no partition table** — wipe with `wipefs -a` before install.
- ISO delivery: `deploy-on-baremetal.sh` serves the ISO via HTTP and uses Redfish to mount it as virtual media. BMC addresses go in `nodes.yml` (see the bare-metal example directories).
- Run `hack/configure-converged-scheduling.sh` after install on bare-metal converged too — same taint-removal requirement as KVM.

---

## Troubleshooting

### VMs not booting

```bash
virsh list --all                     # Check VM state
virsh console control-0              # View console output
journalctl -u libvirtd -n 50         # libvirt errors
ls -lh ~/cluster_acp/install/agent.x86_64.iso  # Confirm ISO exists
```

### DNS failures

Internal DNS is managed by libvirt's built-in dnsmasq on the VLAN bridge (not a standalone service).
VyOS-first: provisioning network is `1925` (converged) or `1926` (SNO).

```bash
# Check the active VLAN network DNS config (records injected by setup-dnsmasq.sh)
virsh net-dumpxml 1925 | grep -A5 dns     # converged
virsh net-dumpxml 1926 | grep -A5 dns     # SNO

# Test internal resolution from the KVM host (converged)
dig @192.168.50.1 api.${CLUSTER_NAME}.${BASE_DOMAIN} +short
# Expected: 192.168.50.253 (internal VIP)

# If internal resolution fails, re-run DNS setup:
source hack/env.sh
sudo -E ./hack/setup-dnsmasq.sh    # auto-detects active VLAN from symlink
./hack/verify-dns-resolution.sh

# Test external resolution (Route53)
dig @8.8.8.8 api.${CLUSTER_NAME}.${BASE_DOMAIN} +short
# Expected: <EXTERNAL_IP> (IBM Cloud public IP)

# If external resolution fails:
source hack/env.sh
./hack/configure-route53-dns.sh add
```

### HAProxy not forwarding traffic

```bash
systemctl status haproxy
ss -tlnp | grep haproxy        # Confirm 0.0.0.0 bindings
# Check firewalld is not blocking:
firewall-cmd --list-ports
# Must include: 6443/tcp 22623/tcp 80/tcp 443/tcp
```

### API not reachable from workstation

```bash
# 1. Verify Route53 resolves to correct IP
dig api.${CLUSTER_NAME}.${BASE_DOMAIN} +short

# 2. Verify HAProxy is running and forwarding
curl -k https://api.${CLUSTER_NAME}.${BASE_DOMAIN}:6443/version

    # 3. Check if cluster API VIP is reachable internally
    virsh net-dhcp-leases 1925   # converged — check node IPs
    virsh net-dhcp-leases 1926   # SNO
```

### Install timeout / bootstrap failure

```bash
openshift-install agent wait-for bootstrap-complete \
  --dir ~/cluster_acp/install --log-level=debug

# Check individual node logs
virsh console control-0
# Look for: 'bootkube.service' errors, DNS failures in journalctl
```
