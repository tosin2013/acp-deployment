# Changelog

All notable changes to `acp-deployment` are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Version numbers track the target OpenShift Container Platform major.minor version.

---

## [v4.21.0] — 2026-06-04

First fully-deployed and hardened release on the OCP 4.21 track.
Validated on IBM Cloud bare-metal (KVM host) with a 3-node compact HA cluster.

### Added

- **IBM Cloud KVM deployment path** — complete end-to-end automation for deploying OCP on KVM VMs
  hosted on IBM Cloud bare-metal. Covers: libvirt network setup, VyOS router, dnsmasq DNS,
  HAProxy external access, Route53 DNS, KVM VM lifecycle. (ADR-0014 through ADR-0019)
- **`hack/deploy-cluster.sh`** — 13-step master orchestrator that runs the full deployment pipeline
- **`hack/deploy-kvm-vms.sh`** — VM creation with configurable RAM/CPU/disk, correct boot order,
  and automatic MAC address integration
- **`hack/verify-odf-prerequisites.sh`** — 5-check ODF preflight: virt type vs `odf_use_multus`,
  OpenShift API, LSO disk count, StorageCluster finalizers, NAD state
- **`hack/verify-post-install-prerequisites.sh`** — 3-check post-install preflight: `ansible_user`
  resolution, cert-manager CSV phase, kubeconfig stale CA detection
- **`hack/generate-kvm-macs.sh`** — deterministic MAC address generation for KVM VMs
- **`hack/watch-and-reboot-kvm-vms.sh`** — automated VM reboot during agent-based install
- **`hack/configure-haproxy-forwarder.sh`** — HAProxy external access for OCP API/ingress
- **`hack/configure-route53-dns.sh`** — Route53 DNS record management for cluster endpoints
- **`hack/setup-dnsmasq.sh`** — internal KVM cluster DNS via dnsmasq
- **ODF role** (`roles/openshift_data_foundation/`) — StorageCluster, LSO, Ceph, NooBaa automation
  with conditional Multus network block (`odf_use_multus` flag). (ADR-0005)
- **cert-manager role** (`roles/update_ocp_ingress_cert/`) — ZeroSSL TLS issuance via DNS-01/Route53
  for ingress wildcard and API server. (ADR-0009)
- **AAP role** (`roles/ansible_automation_platform/`) — Ansible Automation Platform operator
  and AutomationController CR. (ADR-0010)
- **OpenShift Virtualization role** (`roles/openshift_virtualization/`) — HyperConverged operator
  with nested virt support. (ADR-0012)
- **OpenShift Pipelines role** — Tekton Pipelines operator installation
- **`CLAUDE.md`** — AI agent session guide with 6 known failure patterns
- **`docs/adrs/`** — 19 Architectural Decision Records covering all major design choices
- **`docs/hardening/`** — Post-incident hardening reports for all resolved issues
- **`docs/releases/v4.21.0.md`** — Full release notes
- **`playbooks/site-post-install.yml`** — Master post-install orchestrator (5 playbooks in order)
- **`examples/ibm-cloud-converged/`** and **`examples/ibm-cloud-sno/`** — IBM Cloud topology configs
- **`examples/bare-metal-converged/`** and **`examples/bare-metal-sno/`** — bare-metal topology configs

### Fixed

- **ODF macvlan/Multus incompatibility on KVM virtio** — KVM virtio interfaces do not support macvlan.
  Added `odf_use_multus: false` flag to gate Multus NAD creation and StorageCluster network block.
  Preflight guard in `setup-openshift-storage.yml` fails fast with actionable message. (ADR-0005 amendment)
- **LSO LocalVolumeSet zero PVs on KVM** — KVM qcow2 disks report as `Rotational`; LSO's default
  `deviceMechanicalProperties: [NonRotational]` excluded all virtual disks. Added `Rotational` to the
  allowed list in `roles/openshift_local_storage/vars/main.yml`.
- **StorageCluster count integer coercion** — Ansible `combine()` coerces `{{ x | int }}` to string.
  Fixed by forcing `| int` at the `redhat.openshift.k8s: definition:` call site in `tasks/main.yml`.
- **`ansible_user` undefined for local connections** — `ansible_connection: local` does not populate
  `ansible_user`. Added `ansible_user: "{{ lookup('env', 'USER') }}"` to inventory; all 5 post-install
  playbooks now use `ansible_user | default(ansible_user_id)`. (ADR-0003 amendment)
- **CertManager CR wrong `apiVersion`** — OCP cert-manager operator uses `operator.openshift.io/v1alpha1`,
  not `acme.cert-manager.io/v1`. Fixed in `roles/update_ocp_ingress_cert/defaults/main.yml`.
  (ADR-0006/ADR-0009 amendments)
- **Missing OLM CSV wait in cert-manager role** — `cert-manager-operator.yml` applied operand CR before
  OLM finished registering CRDs. Added `Wait for cert-manager-operator CSV to succeed` task.
- **kubeconfig CA not stripped after API cert rotation** — `Update KUBECONFIG` handler failed due to
  undefined `ansible_user`, leaving old self-signed `certificate-authority-data`. Fixed via
  `ansible_user | default(ansible_user_id)` fallback in handler. (ADR-0009 amendment)
- **VM boot order** — `virt-install --cdrom` sets ISO as boot order 1; post-install XML patch now
  sets OS disk (`vda`) to boot order 1. Prevents RHCOS reinstall loop on every reboot.
- **dnsmasq network teardown** — `virsh net-destroy` disrupts running VMs. Fixed to use SIGHUP
  for dnsmasq config reload without network teardown.

### Changed

- **OCP version track updated from 4.13 to 4.21** — All playbooks, roles, and docs updated.
  Agent-Based Installer and operator channels pinned to 4.21.x. (ADR-0013)
- **VM RAM default raised from 32 GiB to 48 GiB** in `hack/deploy-kvm-vms.sh` — ODF MDS standby
  (6 GiB request) and NooBaa DB (4 GiB request) require headroom beyond the 32 GiB base OCP footprint.
- **StorageCluster `count` parameterised** via `odf_device_count` variable (default: 6 for KVM,
  configurable for bare-metal). Previously hardcoded to 12 (bare-metal only).
- **`odf_device_count` added to `extra-vars.yml`** — `6` for KVM (2 disks × 3 nodes),
  configurable for bare-metal NVMe setups.
- **Hardware requirements updated** — minimum 48 GiB RAM per node for HA deployments with ODF + Virt.
- **README completely rewritten** — updated from 4.13 references to 4.21, added IBM Cloud KVM path,
  accurate hardware requirements, Quick Start guide, repository structure map.

### Deprecated

- None

### Removed

- Hardcoded `count: 12` in StorageCluster definition (replaced by `odf_device_count` variable)
- Hardcoded `startingCSV` in operator subscriptions (OLM now selects latest on channel; see ADR-0013)

---

## Pre-v4.21.0

Prior to v4.21.0 this repository was unversioned and targeted OCP 4.13.
No formal changelog was maintained. See git history for individual commit-level changes.
