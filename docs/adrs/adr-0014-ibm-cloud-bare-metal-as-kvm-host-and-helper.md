# ADR-0014: IBM Cloud Bare Metal as Combined KVM Host and Helper Node

## Date
2026-06-03

## Status
Accepted

## Context

The ACP deployment project (ADR-0003) uses a dedicated helper node as the single orchestration point for all deployment operations. The PRD for KVM-based development additionally requires a KVM hypervisor to host the OpenShift cluster VMs that simulate bare-metal nodes.

Historically these two roles — Ansible helper and KVM hypervisor — are fulfilled by separate machines. However, the primary deployment environment for this ACP instance is an IBM Cloud bare-metal server with the following characteristics:

- **OS**: CentOS Stream 10 (not RHEL 9 as assumed by the PRD)
- **CPU**: 48 vCPUs (Intel Xeon Cascadelake, 2 sockets)
- **RAM**: 188 GB
- **Storage**: `/dev/vda` 100 GB (OS) + `/dev/vdb` 1 TB (available for VMs)
- **Network**: Single `eth0` NIC with private IP `10.241.64.5`; IBM Cloud NAT provides a public IP for external access
- **No GUI**: SSH-only access; no browser available on this machine

The machine has significantly more than the minimum resources specified by the PRD (128 GB RAM, 32+ CPUs, 500 GB storage for HA). `/dev/vdb` (1 TB) is unformatted and available exclusively for KVM VM storage.

Provisioning a separate helper VM inside the cluster network would consume VM resources and add complexity. Since this machine has outbound internet access, direct access to the cluster API (via local libvirt networking), and persistent storage for artifacts, it is the natural choice for both roles.

## Decision

This IBM Cloud bare-metal server serves as both the Ansible helper node and the KVM hypervisor. The roles are:

**As KVM host:**
- KVM packages (`qemu-kvm`, `libvirt`, `virt-install`, `libvirt-client`) are installed on CentOS Stream 10.
- `/dev/vdb` (1 TB) is configured as a libvirt storage pool named `acp-vms`, providing backing storage for all VM disk images.
- Nested virtualisation is enabled (`options kvm_intel nested=1`) to support OpenShift Virtualization workloads inside the KVM VMs.
- Two libvirt NAT networks are created: `acp-provisioning` (`192.168.50.0/24`) and `acp-storage` (`192.168.52.0/24`).

**As helper node:**
- All Ansible playbooks target `localhost` with `ansible_connection: local` (the machine runs Ansible against itself).
- `openshift-install` and `oc` binaries are downloaded to this machine.
- The cluster kubeconfig is stored locally at `~/cluster_<name>/install/auth/kubeconfig`.
- Post-install playbooks execute from this machine against the cluster API, which is reachable via the `acp-provisioning` libvirt bridge.

The `examples/ibm-cloud-converged/inventory.yml (or ibm-cloud-sno/inventory.yml)` reflects this by targeting `localhost`.

## Consequences

**Positive:**
- Eliminates the need for a separate helper VM inside the cluster network, saving 32 GB RAM and 120 GB disk per the PRD's helper node sizing.
- All deployment artifacts (ISO, kubeconfig, binaries) are co-located with the hypervisor, simplifying the operational model.
- The 1 TB `/dev/vdb` pool provides sufficient space for 3 × 320 GB VM images (120 GB OS + 2 × 100 GB ODF) with significant headroom.
- CentOS Stream 10 is upstream of RHEL 10 and receives current packages; the KVM stack (`qemu-kvm`, `libvirt`) is fully compatible with the OpenShift agent installer requirements.

**Negative:**
- Combining helper and KVM host roles means the machine is a single point of failure for both cluster orchestration and hypervisor operations. If this machine is lost or rebooted, both the helper tooling and the running VMs are affected simultaneously.
- CentOS Stream 10 is not a supported OpenShift deployment platform by Red Hat; for production helper nodes, RHEL 9 is the documented choice. Script-level differences (package names, SELinux contexts) must be accounted for.
- `ansible_connection: local` means Ansible cannot take advantage of SSH agent forwarding or remote inventory; all operations run as `vpcuser` on this machine.
- The machine's single `eth0` NIC carries both management SSH traffic and KVM guest traffic simultaneously. Under heavy ODF replication load the storage network (`acp-storage`) and management traffic share the same physical uplink.

## Alternatives Considered

- **Separate helper VM inside libvirt** — Clean role separation but consumes RAM and disk from the cluster allocation; adds another VM to manage and boot from ISO.
- **Operator's local workstation as helper** — Eliminates IBM Cloud machine overhead but requires persistent connectivity during multi-hour installs and introduces version skew risk from the operator's local tool versions.
- **Cloud-native managed VMs (IBM Cloud VPC instances)** — VPC instances lack the nested virtualisation and multi-NIC flexibility needed for ODF storage network isolation. Also significantly more expensive for sustained development.
- **Separate IBM Cloud bare-metal for helper** — Full role separation at the cost of provisioning and maintaining a second IBM Cloud machine for a development environment.


---

## Validated in Production

v4.21.0 — 2026-06-04 — IBM Cloud KVM (3-node compact), OCP 4.21.8, acp-deployment v4.21.0. All role assumptions confirmed against a fully deployed cluster.
