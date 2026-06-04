# Understanding ODF storage design

OpenShift Data Foundation (ODF) is the storage layer of the ACP platform. Understanding why it is deployed the way it is — using local disks, LSO, conditional Multus networking, and a specific device count — helps operators troubleshoot failures and make informed decisions when adapting the deployment to different hardware.

---

## Why Ceph?

ODF is built on Ceph, a distributed storage system that provides block (RBD), file (CephFS), and object (RGW/S3) storage from the same pool of disks. The ACP platform needs all three:

- **Block storage (RBD):** AAP's PostgreSQL database, operator PVCs, single-pod volumes
- **File storage (CephFS):** Shared volumes for multi-pod workloads (CI pipelines, build caches)
- **Object storage (S3/NooBaa):** Multi-Cloud Gateway for AAP artifact storage and future workload needs

An alternative would be to provision each storage type separately (e.g., NFS for file, MinIO for object, iSCSI for block). This approach requires additional infrastructure and management overhead. ODF provides all three from a single deployment on the cluster nodes' local disks, with no external SAN or NAS required.

---

## Why Local Storage Operator first?

Ceph requires raw block devices — it manages its own disk layout internally. It cannot use pre-formatted filesystems, LVM volumes, or partitions.

The Local Storage Operator (LSO) solves this by automatically discovering unformatted block devices that match a selector (size class, device type, availability) and creating PersistentVolumes from them. This eliminates the need for pre-deployment disk preparation.

The `LocalVolumeSet` CR in `roles/openshift_local_storage/vars/main.yml` uses these selector criteria:
- `deviceMechanicalProperties: [NonRotational, Rotational]` — matches both SSD/NVMe and spinning disks (the original `NonRotational`-only selector excluded KVM's virtio disks, which report as `Rotational`)
- `minSize: 1Gi` — excludes the OS disk
- `maxDeviceCount: 2` — limits to 2 devices per node, matching the KVM VM configuration

---

## Why odf_device_count matters

The `StorageCluster.spec.storageDeviceSets[0].count` field tells ODF how many device sets to create across the cluster. This number must match the actual number of PVs that LSO discovers.

On bare-metal with 4 NVMe drives per node and 3 nodes: `count = 12`.
On KVM with 2 virtual disks per node and 3 nodes: `count = 6`.

If `count` is set higher than the number of available PVs, ODF waits indefinitely for more disks to appear and the StorageCluster stays in `Progressing`. This is a silent failure mode — the cluster looks like it is installing but never completes.

The `odf_device_count` variable in `extra-vars.yml` (under `openshift.all_node_settings`) controls this value. It must be set explicitly. There is no safe default because the correct value is hardware-dependent.

---

## Why Multus for storage network isolation?

Ceph's replication protocol (RADOS) generates significant network traffic when writing data — every write is replicated to at least 2 (usually 3) OSDs. On a 3-node converged cluster where control-plane pods, workloads, and storage replication all share the same physical NIC, storage I/O can saturate the network and cause API request latency spikes.

Multus solves this by attaching a second network interface (via macvlan) directly to Ceph pods, bypassing the main cluster network bridge. Ceph replication traffic flows through this dedicated interface on a separate IP subnet (e.g., `192.168.52.0/24`), leaving the primary network uncontested.

For production ACP deployments on physical servers with LACP-bonded NICs, Multus storage network isolation is strongly recommended. The `odf_use_multus: true` setting enables it.

---

## Why Multus cannot be used on KVM

macvlan creates virtual interfaces that share a physical NIC's MAC but have their own IP. The kernel implements macvlan at the device driver level. The virtio NIC driver used by KVM does not implement the ioctl call that macvlan requires to create subinterfaces. This is a fundamental limitation of the virtio driver — it is not a configuration error or a version issue.

When ODF tries to create the `ocs-public-cluster` NetworkAttachmentDefinition and attach macvlan interfaces to Ceph pods on KVM nodes, every pod that needs the storage network interface fails with `Link not found`. The StorageCluster never reaches `HEALTH_OK`.

The `odf_use_multus: false` flag bypasses NAD creation entirely. The StorageCluster is created without a `network:` block, so Ceph uses the primary pod network for both client and replication traffic. On a testbed with light load, this is acceptable. On a production cluster with high I/O workloads, network contention can degrade both storage performance and cluster stability.

See [ADR-0005](../adrs/adr-0005-odf-on-local-nvme-with-multus-storage-network.md) for the full decision record.

---

## Memory requirements: why 48 GiB is the threshold

ODF's control plane components have substantial memory *requests* (not just limits):

| Component | Memory request |
|-----------|---------------|
| `rook-ceph-mds` (active) | 6 GiB |
| `rook-ceph-mds` (standby) | 6 GiB |
| `noobaa-db` | 4 GiB |
| `rook-ceph-osd` (×2) | 2 × 2 GiB |
| Other ODF pods | ~4 GiB |
| Base OCP components | ~14 GiB |
| **Total** | **~38 GiB** |

On a 32 GiB node, Kubernetes cannot schedule all these pods simultaneously — it sees `Insufficient memory` even though the actual memory *usage* is lower than the requests (because ODF pods often use less than they request). The pods go `Pending` and the cluster appears healthy while the storage layer is silently broken.

Increasing RAM to 48 GiB gives 10 GiB of headroom above the total request sum, which is sufficient for the ODF control plane to schedule and stabilise.

---

## The NooBaa Multi-Cloud Gateway

NooBaa is the object storage component of ODF. It provides an S3-compatible gateway that can aggregate storage from multiple backends (ODF's own Ceph RGW, AWS S3, IBM Cloud Object Storage, etc.). For the ACP platform, NooBaa serves as the local S3 endpoint for AAP and future multi-cloud storage workloads.

NooBaa's `noobaa-db` StatefulSet requires a PVC from the `ocs-storagecluster-ceph-rbd` storage class. This is why ODF must be deployed *before* AAP in the `site-post-install.yml` pipeline — AAP's database also needs storage, and both depend on the same storage class.

---

## Further reading

- [How to deploy ODF on a KVM cluster](../how-to/deploy-odf-on-kvm.md)
- [How to resolve ODF Multus macvlan failure](../how-to/resolve-odf-multus-kvm.md)
- [ADR-0005: ODF on Local NVMe with Multus Storage Network](../adrs/adr-0005-odf-on-local-nvme-with-multus-storage-network.md)
