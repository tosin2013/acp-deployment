# ADR-0005: OpenShift Data Foundation on Local NVMe with Multus Storage Network Isolation

## Date
2026-06-03

## Status
Accepted — Amended

> **Amendment (2026-06-04, KVM macvlan exception):** KVM virtio interfaces (`eth2`) do not support
> macvlan in bridge mode — the Linux kernel refuses to create a macvlan subinterface on a tun/virtio
> device, producing `"Link not found"` from the Multus CNI shim. A new `odf_use_multus` flag in
> `openshift.all_node_settings` controls whether Multus is used:
>
> - `odf_use_multus: false` (KVM default) — StorageCluster `network:` block is omitted entirely;
>   Ceph uses the OVN-Kubernetes default pod network. The NAD creation task is skipped.
> - `odf_use_multus: true` (bare-metal default) — original Multus macvlan behaviour on `bond0`.
>
> A second fix corrects `odf_device_count` (was hardcoded `12`; KVM default is `6` = 2 disks × 3
> nodes). Both values are set in `openshift.all_node_settings` in `extra-vars.yml`.
> See `roles/openshift_data_foundation/vars/main.yml` and `tasks/main.yml`.

## Context

The ACP platform requires persistent block storage for platform services deployed on the cluster, including the Ansible Automation Platform's PostgreSQL database, future workload PVCs, and operator-managed volumes. In an HA bare-metal testbed without external SAN/NAS infrastructure, storage must be provisioned from locally attached disks on the cluster nodes.

The storage solution must satisfy:
- Block storage with ReadWriteOnce (RWO) and ReadWriteMany (RWX) access modes for platform operators.
- Storage traffic isolation to prevent storage replication I/O from competing with workload and cluster management traffic on the primary network.
- Automatic disk discovery and provisioning without pre-formatting or manual LVM setup.
- Integration with OpenShift's PersistentVolume subsystem via a StorageClass.

## Decision

OpenShift Data Foundation (ODF/Ceph) is deployed on top of the Local Storage Operator (LSO), using locally attached NVMe/SSD drives on the three control-plane nodes. Storage network traffic is isolated using a Multus `macvlan` NetworkAttachmentDefinition on a dedicated bonded interface (`bond0` by default), with a separate storage CIDR (default `192.168.2.0/24`).

The deployment sequence implemented across `roles/openshift_local_storage/` and `roles/openshift_data_foundation/`:

1. **Local Storage Operator** is installed via OLM subscription and a `LocalVolumeSet` CR automatically discovers NVMe/SSD devices matching a device class selector, creating a `local-disks` StorageClass.
2. **ODF StorageCluster** is deployed using the `local-disks` StorageClass as the backing store, with 12 device sets and host-level failure domain. The resulting default StorageClass is `ocs-storagecluster-ceph-rbd`.
3. **Multus NAD**: A `NetworkAttachmentDefinition` of type `macvlan` is created on the storage interface, and the ODF StorageCluster is configured to use this NAD for Ceph replication traffic, isolating storage I/O from the main cluster network.

This configuration is conditional on `architecture: ha` — ODF is not deployed in non-HA (SNO) mode.

## Consequences

**Positive:**
- ODF provides enterprise-grade Ceph storage with RWO, RWX, and object (S3) access modes natively on OpenShift without external infrastructure.
- LSO automatic disk discovery eliminates manual disk partitioning or LVM configuration prior to deployment.
- Multus/macvlan storage network isolation prevents Ceph replication traffic from saturating cluster management or workload networks — critical for industrial ACP workloads that require predictable latency.
- ODF integrates natively with OpenShift's PV/PVC subsystem and is used as the default StorageClass for platform operators (e.g., AAP PostgreSQL).
- Failure domain is set to host level, ensuring Ceph tolerates a single node failure in a 3-node cluster.

**Negative:**
- ODF requires significant resources: minimum 3 nodes, each with dedicated local disks and a separate storage NIC/bond. This limits the configuration to HA deployments.
- The ODF console plugin integration is explicitly commented out in the role (known issue deferred).
- Storage network configuration (`storage_interface`, storage CIDR) must be pre-planned and cabled before deployment — there is no post-install network reconfiguration path.
- 12 device sets is a fixed default; environments with fewer or differently-sized disks may need variable tuning that is not currently parameterized.
- ODF operator upgrades must be manually managed by bumping the `stable-4.13` channel pin (see ADR-0011).

## Alternatives Considered

- **NFS from helper node** — Simple to set up but creates a single point of failure on the helper, provides no HA for storage, and is unsuitable for production-representative workloads.
- **iSCSI from external SAN** — Provides enterprise HA storage but requires external SAN hardware not available in all ACP testbed environments; contradicts the self-contained testbed goal.
- **Longhorn** — Cloud-native distributed storage that runs on commodity hardware without dedicated storage NICs, but is not a supported Red Hat product and lacks the enterprise certification required for OPAF ACP validation.
- **AWS EBS / cloud-backed PVs** — Not applicable to bare-metal on-premises deployments.
- **hostPath / local PVs without LSO** — Requires manual disk preparation and does not provide Ceph's replication or multi-protocol access modes.
- **OVN-K pod network for Ceph (KVM)** — Not a performance isolation alternative for production bare metal, but fully functional for KVM lab deployments where virtio NICs prevent macvlan. Selected via `odf_use_multus: false`.


---

## Validated in Production

v4.21.0 — 2026-06-04 — IBM Cloud KVM (3-node compact), OCP 4.21.8, acp-deployment v4.21.0. All role assumptions confirmed against a fully deployed cluster.
