# Advanced Computing Platform Deployment Automation

[![Version](https://img.shields.io/badge/version-v4.21.0-blue)](https://github.com/tosin2013/acp-deployment/releases/tag/v4.21.0)
[![OCP](https://img.shields.io/badge/OpenShift-4.21-red)](https://docs.openshift.com/container-platform/4.21/)
[![License](https://img.shields.io/badge/license-Apache%202.0-green)](LICENSE)

Ansible-first automation toolkit for deploying an **Advanced Computing Platform (ACP)** reference implementation on Red Hat OpenShift Container Platform. Covers full cluster lifecycle: KVM host preparation, cluster installation via Agent-Based Installer, and complete post-install platform service deployment.

> This repository represents an opinionated, validated reference implementation. Feedback and contributions are welcome.

---

## Terminology

| Term | Definition |
|------|-----------|
| **ACP** | Advanced Computing Platform — a component of the [OPAF](https://www.opengroup.org/forum/open-process-automation-forum) architecture |
| **DCN** | Distributed Control Node — small purpose-built device managed by the ACP |
| **Testbed** | An ACP implementation used for testing and evaluation of industrial/realtime workloads |
| **Helper** | The Linux host that runs all Ansible playbooks and serves as the deployment control node |

---

## Architecture

![OPAF Architecture](images/testbed-architecture.jpg)

This repository covers the **Advanced Computing Platform** (top left of the OPAF diagram). Two deployment topologies are supported:

| Topology | Nodes | ODF | Use case |
|----------|-------|-----|---------|
| **HA (converged)** | 3 control-plane nodes also running workloads | Yes | Full ACP testbed |
| **Non-HA (SNO)** | 1 single-node OpenShift | No | Development / edge evaluation |

---

## Platform Services Deployed

| Service | Version | Role |
|---------|---------|------|
| OpenShift Container Platform | 4.21.x | Container orchestration |
| OpenShift Data Foundation (ODF) | 4.21 | Block, file, and object storage |
| cert-manager + ZeroSSL | v1.19.0 | Automated TLS for ingress and API |
| OpenShift Pipelines (Tekton) | v1.22.x | CI/CD pipelines |
| Ansible Automation Platform | 2.6.x | DCN management and automation |
| OpenShift Virtualization (KubeVirt) | 4.21.x | VM workload support |
| Local Storage Operator | 4.21 | NVMe/disk discovery for ODF |

---

## Hardware Requirements

### HA Deployment (Validated — v4.21.0)

**3 × OCP nodes (IBM Cloud bare-metal or equivalent):**

| Resource | Minimum | Recommended (with ODF + Virt) |
|----------|---------|-------------------------------|
| CPU | 8 cores / socket | 16+ cores |
| RAM | 32 GiB | **48 GiB** per node |
| OS disk | 120 GiB | 120 GiB (vda) |
| ODF disks | 2 × 100 GiB | 2 × 100 GiB (vdb, vdc) |
| NICs | 2 (minimum) | 4 (cluster + storage + app + BMC) |

> **Note:** 48 GiB RAM per node is required when deploying ODF + OpenShift Virtualization together.
> ODF MDS standby (6 GiB request) and NooBaa DB (4 GiB request) exceed the headroom on 32 GiB nodes.

**IBM Cloud KVM host (bare-metal server hosting the VMs):**
- Total RAM: 128 GiB minimum, 192 GiB recommended
- Nested virtualisation enabled (required for OpenShift Virt on KVM)

### Non-HA Deployment (SNO)

- 1 × server: 16 cores, 32 GiB RAM, 120 GiB disk
- No ODF (single-node does not meet ODF quorum requirements)

---

## Deployment Paths

### IBM Cloud KVM (Validated — v4.21.0)

The IBM Cloud bare-metal server acts as both KVM hypervisor and Ansible helper.
OpenShift runs inside KVM VMs.

```
IBM Cloud bare-metal
├── KVM host (libvirt)
│   ├── control-0 (48 GiB, 16 vCPU)
│   ├── control-1 (48 GiB, 16 vCPU)
│   ├── control-2 (48 GiB, 16 vCPU)
│   └── vyos-router (4 GiB, VyOS 1.x)
└── Ansible helper (runs on the bare-metal host itself)
```

See: [`docs/kvm-developer-guide.md`](docs/kvm-developer-guide.md), ADR-0014 through ADR-0019.

### Bare-Metal Direct

OpenShift installs directly on physical servers via Agent-Based Installer booted from the agent ISO
using Redfish virtual media (iDRAC 9+, iLO 5+, Supermicro BMC, AMI MegaRAC).

```
Physical server rack
├── control-0  (physical, bond0 + bond1)
├── control-1  (physical, bond0 + bond1)
├── control-2  (physical, bond0 + bond1)
└── helper     (separate server or VM running Ansible + ISO HTTP server)
```

See: [`examples/bare-metal-converged/`](examples/bare-metal-converged/), [`hack/deploy-on-baremetal.sh`](hack/deploy-on-baremetal.sh).

---

## Quick Start — IBM Cloud KVM

### Prerequisites

- IBM Cloud bare-metal server provisioned (RHEL 9 or CentOS Stream 10)
- Red Hat pull secret from [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret)
- Route53 hosted zone (for external DNS and ZeroSSL DNS-01 TLS)
- ZeroSSL account with EAB credentials from [zerossl.com/developer](https://app.zerossl.com/developer)
- AWS IAM credentials with Route53 write access

### 1. Prepare the KVM host

```bash
git clone https://github.com/tosin2013/acp-deployment.git
cd acp-deployment

# Install libvirt, QEMU, required packages
./hack/bootstrap.sh

# Install and configure KVM networking
./hack/install-kvm-host.sh
./hack/setup-libvirt-networks.sh
```

### 2. Configure your environment

```bash
# Select the IBM Cloud HA topology
./hack/select-cluster-topology.sh ibm-cloud-converged

# Populate SSH key and pull secret
./hack/setup-cluster-vars.sh

# Edit your environment-specific variables
vi examples/ibm-cloud-active/extra-vars.yml
```

Key variables to set:

```yaml
# Cluster identity
openshift:
  cluster_name: acp
  base_domain: sandbox3377.opentlc.com

# Node MACs (generated below)
# ZeroSSL EAB credentials
zerossl_account:
  email: you@example.com
  kid: <EAB Key ID>
  key: <EAB HMAC key>
```

### 3. Create and boot VMs

```bash
# Generate unique MAC addresses for your nodes
./hack/generate-kvm-macs.sh

# Create the VMs (48 GiB RAM default)
./hack/deploy-kvm-vms.sh --iso /path/to/agent.x86_64.iso
```

### 4. Run the full deployment pipeline

```bash
# Run all steps: ISO creation → cluster install → post-install services
./hack/deploy-cluster.sh \
  -i examples/ibm-cloud-active/inventory.yml \
  -e @examples/ibm-cloud-active/extra-vars.yml
```

Or run stages individually:

```bash
# 1. Generate and burn the Agent-Based Installer ISO
ansible-playbook playbooks/create-installation-media.yml \
  -i examples/ibm-cloud-active/inventory.yml \
  -e @examples/ibm-cloud-active/extra-vars.yml

# 2. Post-install services (storage → TLS → pipelines → AAP → virt)
ansible-playbook playbooks/site-post-install.yml \
  -i examples/ibm-cloud-active/inventory.yml \
  -e @examples/ibm-cloud-active/extra-vars.yml
```

### 5. Validate

```bash
# Pre-storage preflight
./hack/verify-odf-prerequisites.sh \
  -e examples/ibm-cloud-active/extra-vars.yml

# Pre-post-install preflight
./hack/verify-post-install-prerequisites.sh \
  -i examples/ibm-cloud-active/inventory.yml

# Cluster status
export KUBECONFIG=~/cluster_acp/install/auth/kubeconfig
oc get nodes
oc get storagecluster -n openshift-storage
oc get hyperconverged -n openshift-cnv
```

---

## Quick Start — Bare-Metal Direct

### Prerequisites

- 3 physical servers with Redfish-capable BMC (iDRAC 9+, iLO 5+, Supermicro BMC, or AMI MegaRAC)
- Separate helper host (RHEL 9 / CentOS Stream 10) on the same network
- Red Hat pull secret from [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret)
- Layer 2 switch with LACP (for bonded NIC configuration)
- Optional: Route53 + ZeroSSL for automated TLS (same as IBM Cloud path)

### Hardware per Node (reference configuration)

| Resource | Spec |
|----------|------|
| CPU | 2× Intel Xeon Silver (24+ cores total) |
| RAM | 256 GiB DDR4 ECC |
| OS disk | 1× NVMe 960 GiB |
| ODF disks | 2× NVMe 3.84 TiB |
| NICs | 2× 25 GbE (bond0, provisioning) + 2× 10 GbE (bond1, ODF storage) |
| BMC | iDRAC 9 / iLO 5 / AMI MegaRAC |

> Note: `odf_use_multus: true` is the default for bare-metal (bond1 acts as the dedicated
> Multus storage network). This is the opposite of the KVM path.

### 1. Prepare the helper node

```bash
git clone https://github.com/tosin2013/acp-deployment.git
cd acp-deployment
./hack/bootstrap.sh
```

### 2. Configure for bare-metal

```bash
# Select the bare-metal HA topology
./hack/select-cluster-topology.sh bare-metal-converged

./hack/setup-cluster-vars.sh

# Fill placeholders in extra-vars.yml (MACs, IPs, domain, BMC addresses)
vi examples/bare-metal-converged/extra-vars.yml

# Fill BMC addresses and credentials in nodes.yml
vi examples/bare-metal-converged/nodes.yml
```

Key differences from KVM in `extra-vars.yml`:

```yaml
# DNS is handled by BIND-in-Podman on the helper (not dnsmasq/Route53)
external_dns: false

# Multus IS used on bare-metal (dedicated bond1 storage network)
# odf_use_multus defaults to true — do NOT set it to false

all_node_settings:
  storage_interface: bond1           # physical NIC bond for ODF traffic
  storage_network: 192.168.100.0/24  # dedicated storage CIDR
```

### 3. Generate the install ISO

```bash
ansible-playbook playbooks/create-installation-media.yml \
  -i examples/bare-metal-converged/inventory.yml \
  -e @examples/bare-metal-converged/extra-vars.yml
```

### 4. Boot nodes from the ISO via Redfish

```bash
export BAREMETAL_BMC_PASSWORD=<your-bmc-password>

./hack/deploy-on-baremetal.sh \
  --nodes examples/bare-metal-converged/nodes.yml \
  --iso ~/cluster_acp/install/agent.x86_64.iso
```

This mounts the ISO as Redfish virtual media and sets a one-time boot from CD-ROM.
Nodes will boot, install RHCOS, and join the cluster automatically.

### 5. Monitor installation and run post-install

```bash
export KUBECONFIG=~/cluster_acp/install/auth/kubeconfig

# Watch install progress
openshift-install agent wait-for install-complete \
  --dir ~/cluster_acp/install --log-level debug

# Enable workload scheduling on control nodes (converged topology)
./hack/configure-converged-scheduling.sh

# Post-install services
ansible-playbook playbooks/site-post-install.yml \
  -i examples/bare-metal-converged/inventory.yml \
  -e @examples/bare-metal-converged/extra-vars.yml
```

---

## Repository Structure

```
acp-deployment/
├── hack/                    # Shell scripts (KVM host, VM lifecycle, validation)
│   ├── deploy-cluster.sh    # Master 13-step deployment pipeline
│   ├── deploy-kvm-vms.sh    # Create/destroy KVM VMs
│   ├── verify-odf-prerequisites.sh
│   └── verify-post-install-prerequisites.sh
├── playbooks/               # Ansible playbooks
│   ├── create-installation-media.yml
│   ├── site-post-install.yml          # Master post-install (runs all below)
│   ├── setup-openshift-storage.yml
│   ├── update-ocp-ingress-cert.yml
│   ├── setup-openshift-pipelines.yml
│   ├── setup-ansible-automation-platform.yml
│   └── setup-openshift-virtualization.yml
├── roles/                   # Ansible roles (one per platform service)
├── examples/                # Environment-specific variable files
│   ├── ibm-cloud-converged/ # IBM Cloud KVM HA
│   ├── ibm-cloud-sno/       # IBM Cloud KVM SNO
│   ├── bare-metal-converged/
│   └── bare-metal-sno/
├── docs/
│   ├── adrs/                # 19 Architectural Decision Records
│   ├── hardening/           # Post-incident hardening reports
│   ├── releases/            # Per-version release notes
│   └── kvm-developer-guide.md
├── CLAUDE.md                # AI agent guidance and known failure patterns
└── CHANGELOG.md
```

---

## Architectural Decision Records

All key design decisions are documented in [`docs/adrs/`](docs/adrs/). Key ADRs for this release:

| ADR | Title | Status |
|-----|-------|--------|
| [ADR-0001](docs/adrs/adr-0001-use-ansible-as-primary-automation-tool.md) | Ansible as primary automation tool | Accepted |
| [ADR-0003](docs/adrs/adr-0003-helper-node-centric-deployment-model.md) | Helper-node deployment model | Accepted |
| [ADR-0005](docs/adrs/adr-0005-odf-on-local-nvme-with-multus-storage-network.md) | ODF on local NVMe (KVM exception) | Accepted |
| [ADR-0006](docs/adrs/adr-0006-operator-driven-post-install-configuration-via-olm.md) | OLM operator pattern | Accepted |
| [ADR-0009](docs/adrs/adr-0009-zerossl-cert-manager-dns01-tls.md) | ZeroSSL + cert-manager TLS | Accepted |
| [ADR-0013](docs/adrs/adr-0013-update-openshift-version-track-to-4-21.md) | OCP 4.21 version track | Accepted |
| [ADR-0014](docs/adrs/adr-0014-ibm-cloud-bare-metal-as-kvm-host-and-helper.md) | IBM Cloud KVM host | Accepted |

---

## Known Limitations (v4.21.0)

- **Nested virtualisation required:** OpenShift Virtualization on a KVM host requires nested KVM (`kvm_intel/kvm_amd` with nested=1). IBM Cloud bare-metal supports this; most cloud VMs do not.
- **ODF not supported on SNO:** OpenShift Data Foundation requires 3 nodes for Ceph quorum. SNO deployments use no ODF.
- **odf_use_multus must be false on KVM:** KVM virtio interfaces do not support macvlan. See ADR-0005 amendment.
- **ZeroSSL EAB credentials required:** TLS automation requires a pre-created ZeroSSL account with External Account Binding credentials.

---

## Known Failure Patterns

See [`CLAUDE.md`](CLAUDE.md) for a catalogue of failure patterns encountered during development and their fixes, including:
- ODF macvlan/Multus incompatibility on KVM
- `ansible_user` undefined for local connections
- cert-manager `CertManager` CR wrong `apiVersion`

---

## Contributing

1. Fork the repository
2. Create a feature branch
3. Run preflight checks: `./hack/verify-odf-prerequisites.sh` and `./hack/verify-post-install-prerequisites.sh`
4. Submit a pull request

---

## License

Apache License 2.0 — see [LICENSE](LICENSE).
