# Reference: hack/ scripts

All scripts live in `hack/`. They are executable shell scripts (`chmod +x`).

---

## hack/deploy-cluster.sh

Master deployment orchestrator for IBM Cloud KVM. Runs all 13 steps in order.

**Usage:**
```bash
source hack/env.sh
./hack/deploy-cluster.sh [flags]
```

**Flags:**

| Flag | Description |
|------|-------------|
| `--topology converged\|sno` | Force topology selection. Default: auto-detected from host RAM. |
| `--ocp-virt` | Apply OpenShift Virtualization RAM thresholds to topology selection. |
| `--skip-haproxy` | Skip HAProxy configuration (already running). |
| `--skip-route53` | Skip Route53 DNS record creation (already configured). |
| `--skip-post-install` | Stop after `install-complete`; run post-install playbooks manually. |
| `--skip-cert-manager` | Pass `-e skip_cert_manager=true` to `site-post-install.yml`. |
| `--help` | Print usage. |

**Required environment variables:** `CLUSTER_NAME`, `BASE_DOMAIN`, `EXTERNAL_IP`, `HOSTED_ZONE_ID` (set in `hack/env.sh`).

**Prerequisites:** `~/pull-secret.json`, `ansible-playbook`, `openshift-install`, `virsh`, `aws` CLI.

**Idempotency:** Safe to re-run. Each step checks whether it has already been completed.

---

## hack/env.sh

Environment variable file. Source before running any `hack/` script.

**Usage:** `source hack/env.sh`

**Variables defined:**

| Variable | Example | Description |
|----------|---------|-------------|
| `CLUSTER_NAME` | `acp` | Short cluster name |
| `BASE_DOMAIN` | `example.com` | DNS domain |
| `EXTERNAL_IP` | `1.2.3.4` | Public IP of the IBM Cloud server |
| `HOSTED_ZONE_ID` | `Z0123...` | Route53 hosted zone ID |
| `API_VIP` | `192.168.50.253` | Internal API VIP (optional) |
| `INGRESS_VIP` | `192.168.50.252` | Internal ingress VIP (optional) |

---

## hack/bootstrap.sh

Installs all helper node prerequisites: Ansible, `openshift-install`, `oc`, `oc-mirror`, Python packages.

**Usage:** `sudo ./hack/bootstrap.sh`

**What it installs:** `ansible-core`, Red Hat Ansible collections, `python3-boto3`, `python3-botocore`, `openshift-install`, `oc`, `nmstate`.

---

## hack/install-kvm-host.sh

Installs and configures the KVM hypervisor stack on CentOS Stream 10 / RHEL 9.

**Usage:** `sudo ./hack/install-kvm-host.sh [--vm-disk /dev/vdb]`

**Arguments:**

| Argument | Default | Description |
|----------|---------|-------------|
| `--vm-disk PATH` | `/dev/vdb` | Block device to use as KVM VM storage pool |

**What it does:** Installs `qemu-kvm`, `libvirt`, `virt-install`, configures `acp-vms` storage pool on the specified disk, enables nested virtualisation (`kvm_intel`/`kvm_amd` with `nested=1`), adds the current user to the `libvirt` group.

---

## hack/deploy-kvm-vms.sh

Creates KVM virtual machines for the cluster nodes.

**Usage:** `./hack/deploy-kvm-vms.sh [flags]`

**Flags:**

| Flag | Description |
|------|-------------|
| `--sno` | Create a single SNO VM instead of 3 control-plane VMs |
| `--iso PATH` | Path to the agent ISO (default: `~/cluster_<name>/install/agent.x86_64.iso`) |
| `--config PATH` | Path to `extra-vars.yml` (default: `examples/ibm-cloud-active/extra-vars.yml`) |

**VM defaults (converged topology):**

| Parameter | Value |
|-----------|-------|
| vCPUs | 16 |
| RAM | 49152 MB (48 GiB) |
| OS disk | 120 GiB (`vda`) |
| ODF disk 1 | 100 GiB (`vdb`) |
| ODF disk 2 | 100 GiB (`vdc`) |
| NICs | 3 (VLAN 1925, 1924, acp-storage) |

**SNO defaults:** 16 vCPUs, 32768 MB (32 GiB) RAM, 1 OS disk.

**Idempotency:** Skips VMs that already exist.

---

## hack/deploy-on-baremetal.sh

Boots bare-metal servers from the agent ISO using Redfish virtual media.

**Usage:**
```bash
export BAREMETAL_BMC_PASSWORD=<password>
./hack/deploy-on-baremetal.sh --nodes examples/bare-metal-converged/nodes.yml \
  --iso ~/cluster_acp/install/agent.x86_64.iso
```

**Arguments:**

| Argument | Default | Description |
|----------|---------|-------------|
| `--nodes PATH` | — | Path to `nodes.yml` with BMC addresses. **Required.** |
| `--iso PATH` | — | Path to agent ISO file to serve. **Required.** |
| `--port PORT` | `8080` | HTTP port to serve the ISO on |
| `--dry-run` | — | Print Redfish requests without executing |

**Environment variables:**

| Variable | Description |
|----------|-------------|
| `BAREMETAL_BMC_PASSWORD` | BMC password (overrides per-node value in `nodes.yml`) |
| `BAREMETAL_BMC_INSECURE` | `true` to skip BMC TLS verification |

**Supported BMC vendors:** Dell iDRAC 9+, HPE iLO 5+, Supermicro BMC, AMI MegaRAC.

---

## hack/generate-kvm-macs.sh

Generates unique MAC addresses for KVM VM NICs and writes them into `extra-vars.yml`.

**Usage:** `./hack/generate-kvm-macs.sh [extra-vars.yml path]`

**Default path:** `examples/ibm-cloud-active/extra-vars.yml`

**Output:** Updates the `mac_address:` fields under `openshift.control_nodes[].networking.interfaces[]`.

**Idempotency:** Skips interfaces that already have MAC addresses set.

---

## hack/configure-haproxy-forwarder.sh

Configures HAProxy to forward external traffic to internal cluster VIPs.

**Usage:** `sudo -E ./hack/configure-haproxy-forwarder.sh`

**Requires:** `CLUSTER_NAME`, `BASE_DOMAIN`, `EXTERNAL_IP`, `API_VIP`, `INGRESS_VIP` from `env.sh`.

**Ports forwarded:**

| Port | Target |
|------|--------|
| 6443 | `API_VIP:6443` (Kubernetes API) |
| 443 | `INGRESS_VIP:443` (HTTPS ingress) |
| 80 | `INGRESS_VIP:80` (HTTP ingress) |

---

## hack/configure-route53-dns.sh

Creates or deletes Route53 DNS A records for the cluster.

**Usage:**
```bash
./hack/configure-route53-dns.sh add     # create records
./hack/configure-route53-dns.sh delete  # remove records
```

**Records managed:**

| Record | Value |
|--------|-------|
| `api.<CLUSTER>.<DOMAIN>` | `EXTERNAL_IP` |
| `api-int.<CLUSTER>.<DOMAIN>` | `EXTERNAL_IP` |
| `*.apps.<CLUSTER>.<DOMAIN>` | `EXTERNAL_IP` |

**Requires:** `CLUSTER_NAME`, `BASE_DOMAIN`, `EXTERNAL_IP`, `HOSTED_ZONE_ID`, `~/.aws/credentials`.

---

## hack/verify-odf-prerequisites.sh

Runs 5 preflight checks before the ODF storage playbook.

**Usage:** `./hack/verify-odf-prerequisites.sh [-e extra-vars.yml]`

**Checks:**

| # | Check |
|---|-------|
| 1 | Virtualisation type vs `odf_use_multus` — fails if KVM + Multus |
| 2 | OpenShift API server is reachable |
| 3 | LSO `LocalVolumeSet` has provisioned at least 1 PV |
| 4 | No StorageCluster with stuck finalizers |
| 5 | NAD state matches `odf_use_multus` |

---

## hack/verify-post-install-prerequisites.sh

Runs 3 preflight checks before the post-install pipeline.

**Usage:** `./hack/verify-post-install-prerequisites.sh [-i inventory.yml]`

**Checks:**

| # | Check |
|---|-------|
| 1 | `ansible_user` resolves correctly for the helper host |
| 2 | cert-manager CSV is in `Succeeded` phase |
| 3 | Kubeconfig has no stale `certificate-authority-data` |

---

## hack/verify-dns-resolution.sh

Validates that both internal and external DNS resolve correctly.

**Usage:** `./hack/verify-dns-resolution.sh`

**What it checks:** `api.<cluster>.<domain>`, `api-int.<cluster>.<domain>`, `*.apps.<cluster>.<domain>` resolve to the correct IPs via both `8.8.8.8` (external) and the internal dnsmasq.

---

## hack/setup-dnsmasq.sh

Injects cluster DNS records into the libvirt dnsmasq for internal VLAN resolution.

**Usage:** `sudo -E ./hack/setup-dnsmasq.sh`

Uses SIGHUP to reload dnsmasq without tearing down the network bridge. Safe to run on a cluster with running VMs.

---

## hack/select-cluster-topology.sh

Sets the `examples/ibm-cloud-active` symlink to point to the chosen topology directory.

**Usage:** `./hack/select-cluster-topology.sh [topology]`

**Valid topologies:** `ibm-cloud-converged`, `ibm-cloud-sno`, `bare-metal-converged`, `bare-metal-sno`.

Without arguments, auto-detects based on available host RAM (converged if ≥ 128 GiB).

---

## hack/setup-cluster-vars.sh

Copies `~/.ssh/id_rsa.pub` and `~/pull-secret.json` into all `extra-vars.yml` files in the repository.

**Usage:** `./hack/setup-cluster-vars.sh`

---

## hack/configure-converged-scheduling.sh

Removes the `node-role.kubernetes.io/master:NoSchedule` taint from all control-plane nodes to enable workload scheduling on a compact cluster.

**Usage:** `./hack/configure-converged-scheduling.sh` (requires `KUBECONFIG` set)

---

## hack/watch-and-reboot-kvm-vms.sh

Monitors KVM VMs and reboots them after RHCOS installation (required because the Agent-Based Installer shuts VMs down rather than rebooting).

**Usage:**
```bash
./hack/watch-and-reboot-kvm-vms.sh \
  --config examples/ibm-cloud-active/extra-vars.yml \
  --timeout 7200 &
```

**Arguments:**

| Argument | Default | Description |
|----------|---------|-------------|
| `--config PATH` | `examples/ibm-cloud-active/extra-vars.yml` | extra-vars.yml with node names |
| `--timeout SECONDS` | `7200` | Maximum time to watch before exiting |

---

## hack/destroy-kvm-vms.sh

Deletes all cluster KVM VMs and their disk images.

**Usage:** `./hack/destroy-kvm-vms.sh`

> **Warning:** This is destructive and irreversible. All VM data is lost.

---

## hack/vyos-router.sh

Creates or destroys the VyOS router VM and its VLAN libvirt networks.

**Usage:** `ACTION=create ./hack/vyos-router.sh` or `ACTION=destroy ./hack/vyos-router.sh`

Creates: `virbr-1924`, `virbr-1925`, `virbr-1926`, `acp-storage` libvirt networks; `vyos-router` VM.
