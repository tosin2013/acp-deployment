# How to deploy an ACP cluster on bare-metal servers

**Goal:** Install a 3-node compact OpenShift cluster directly on physical servers using the Agent-Based Installer and Redfish BMC automation.

**Prerequisites:**
- 3 physical servers with Redfish-capable BMC (iDRAC 9+, iLO 5+, Supermicro BMC, or AMI MegaRAC)
- A separate helper server with RHEL 9 or CentOS Stream 10
- Layer 2 switch with LACP configured on the server-facing ports
- AWS Route53 hosted zone for your cluster domain
- Red Hat pull secret at `~/pull-secret.json`
- BMC credentials (IPMI/Redfish username + password)

---

## 1. Prepare the helper node

```bash
git clone https://github.com/tosin2013/acp-deployment.git
cd acp-deployment
sudo ./hack/bootstrap.sh
```

## 2. Select the bare-metal topology

```bash
# For 3-node compact HA
cp examples/bare-metal-converged/extra-vars.yml examples/bare-metal-converged/extra-vars.yml.bak
```

## 3. Fill in extra-vars.yml

```bash
vi examples/bare-metal-converged/extra-vars.yml
```

Replace all `<REPLACE_ME_*>` placeholders. Key fields:

```yaml
openshift:
  cluster_name: acp
  base_domain: edge.example.com
  pull_secret: ''         # paste your pull secret
  ssh_pub_key: ''         # paste your SSH public key

  api_address: 10.0.100.200       # floating VIP on provisioning network
  ingress_address: 10.0.100.201   # floating VIP for *.apps

  control_nodes:
    - name: control-0
      installation_device: /dev/nvme0n1    # primary NVMe — confirm in BIOS
      networking:
        interfaces:
          - name: bond0
            mac_address: aa:bb:cc:dd:ee:00  # from hardware label or BMC UI
            # ...
```

> **Key difference from KVM:** On bare-metal, set `odf_use_multus: true` (the default). Physical bonded NICs support macvlan. The ODF storage network uses `bond1`.

## 4. Fill in nodes.yml with BMC addresses

```bash
vi examples/bare-metal-converged/nodes.yml
```

```yaml
nodes:
  - name: control-0
    bmc:
      address: https://192.168.1.200   # BMC management IP
      username: root
    boot_iso_url: http://10.0.100.10:8080/agent.x86_64.iso   # helper IP
    mac_address: aa:bb:cc:dd:ee:00     # primary NIC MAC
```

Set `BAREMETAL_BMC_PASSWORD` in your environment:

```bash
export BAREMETAL_BMC_PASSWORD="your-bmc-password"
```

## 5. Generate the agent ISO

```bash
ansible-playbook playbooks/create-installation-media.yml \
  -i examples/bare-metal-converged/inventory.yml \
  -e @examples/bare-metal-converged/extra-vars.yml
```

The ISO is written to `~/cluster_acp/install/agent.x86_64.iso` and copied to `/var/www/html/` on the helper.

## 6. Boot nodes from the ISO via Redfish

```bash
./hack/deploy-on-baremetal.sh \
  --nodes examples/bare-metal-converged/nodes.yml \
  --iso ~/cluster_acp/install/agent.x86_64.iso
```

This mounts the ISO as Redfish virtual media on each BMC and sets a one-time boot from CD-ROM.

**Verify** each node received the boot request:

```bash
# The script prints power status for each node
# You should see: "Node control-0: Power state: On"
```

## 7. Wait for installation

```bash
export KUBECONFIG=~/cluster_acp/install/auth/kubeconfig

openshift-install agent wait-for install-complete \
  --dir ~/cluster_acp/install --log-level=info
```

Installation takes 45–90 minutes. Nodes boot RHCOS from the ISO, install to the NVMe drive, reboot, and join the cluster automatically.

> Unlike KVM, bare-metal nodes reboot themselves — no watcher script needed.

## 8. Enable workload scheduling (converged)

```bash
./hack/configure-converged-scheduling.sh
```

## 9. Run post-install services

```bash
ansible-playbook playbooks/site-post-install.yml \
  -i examples/bare-metal-converged/inventory.yml \
  -e @examples/bare-metal-converged/extra-vars.yml
```

---

**Expected outcome:** A 3-node compact cluster running on physical servers with all platform services installed.

**Key differences from KVM deployment:**

| Aspect | KVM | Bare-Metal |
|--------|-----|-----------|
| `odf_use_multus` | `false` | `true` |
| Node creation | `deploy-kvm-vms.sh` | `deploy-on-baremetal.sh` (Redfish) |
| VM reboot watcher | Required | Not needed |
| DNS | Route53 + dnsmasq via VyOS | BIND-in-Podman on helper |
| MAC addresses | Auto-generated | From hardware labels/BMC |
