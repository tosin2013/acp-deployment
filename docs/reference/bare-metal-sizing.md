# Bare-metal hardware sizing reference

Hardware sizing targets for ACP deployments on physical servers. Use these tables to assess whether your hardware can support each topology and platform service combination before starting a deployment.

> **Source:** Sizing is derived from the validated v4.21.0 reference deployment (3-node converged on physical servers with 256 GB RAM and 2× 3.84 TB NVMe ODF disks) and from Red Hat OpenShift and ODF minimum requirements documentation.

---

## Topology sizing at a glance

| Topology | Nodes | Min CPU (per node) | Min RAM (per node) | Min OS disk | ODF support |
|----------|-------|-------------------|-------------------|-----------|----|
| Converged (3-node HA) | 3 | 8 cores | 128 GB | 240 GB | Yes (3+ nodes) |
| SNO (Single-Node) | 1 | 8 cores | 32 GB | 120 GB | No (requires 3 nodes) |
| Helper node | 1 | 4 cores | 16 GB | 500 GB | N/A |

---

## Converged (3-node compact HA)

All three nodes run both control-plane and workload roles. ODF (Ceph) requires exactly 3 nodes minimum for quorum.

### CPU

| Tier | Spec | Notes |
|------|------|-------|
| Minimum | 8 physical cores per node | Enough for control-plane only; no workload headroom |
| Recommended | 16–28 physical cores per node | Allows concurrent AAP, Pipelines, and Virtualization workloads |
| Validated reference | 2× Xeon Silver 4310 (24 cores / 48 threads per node) | Used for v4.21.0 validation |

Hyper-Threading (SMT) should be enabled. OpenShift schedulers account for logical CPUs. ODF Ceph processes are CPU-intensive during recovery; more cores improve resilience.

For OpenShift Virtualization workloads, the CPU must support hardware virtualisation:

```bash
# Verify before deployment:
grep -E 'vmx|svm' /proc/cpuinfo | head -1
# vmx = Intel VT-x, svm = AMD-V
# Empty output means virtualisation is disabled in BIOS
```

### RAM

| Tier | RAM per node | Cluster total | Notes |
|------|-------------|--------------|-------|
| Minimum | 128 GB | 384 GB | Ceph MDS and NooBaa may be memory-pressured |
| Recommended | 192 GB | 576 GB | Comfortable headroom for all platform services |
| Validated reference | 256 GB | 768 GB | Used for v4.21.0 validation |

Memory pressure was observed with the following services running simultaneously on 32 GB nodes (KVM equivalent):

- Ceph MDS: requests 8 GB, limit 16 GB
- NooBaa core: requests 4 GB, limit 16 GB
- AAP operator + instance: requests 6 GB total

> The KVM path originally used 32 GB nodes and required an upgrade to 48 GB before ODF pods scheduled. For bare-metal with all platform services, 128 GB is the practical minimum and 256 GB is validated.

### OS disk

| Tier | Capacity | Notes |
|------|----------|-------|
| Minimum | 240 GB NVMe | Enough for OCP install and image pulls |
| Recommended | 480–960 GB NVMe | Allows for larger image caches and etcd growth |
| Validated reference | 960 GB NVMe | Used for v4.21.0 validation |

The OS disk must be **NVMe** for acceptable etcd write latency. SATA SSDs are technically supported but frequently cause etcd latency warnings. Spinning disks are not supported for the OS disk.

> **Stable device path:** NVMe numbering (`/dev/nvme0n1`) can shift after BIOS updates or hardware changes. Use `/dev/disk/by-path/` for the `installation_device` field in `extra-vars.yml`.

### ODF disks

ODF (Ceph) uses separate raw disks — not the OS disk. LSO (Local Storage Operator) discovers and provisions them.

| Configuration | Disks per node | Cluster total raw | Usable (replica-3) | Notes |
|--------------|---------------|-----------------|-------------------|-------|
| Minimum viable | 1× 1.92 TB NVMe | 5.76 TB | ~1.9 TB | replica-3 enforced by default |
| Minimum for production | 1× 3.84 TB NVMe | 11.52 TB | ~3.8 TB | |
| Validated reference | 2× 3.84 TB NVMe | 23.04 TB | ~7.7 TB | Used for v4.21.0 validation |
| High-capacity | 2× 7.68 TB NVMe | 46.08 TB | ~15.3 TB | |

Replica factor and usable capacity:
- **replica-3** (default): data written to all 3 nodes. Usable = raw / 3.
- **replica-2**: data written to 2 of 3 nodes. Usable = raw / 2. Loses one protection copy.

ODF disks must be:
- Raw (no partition table, no filesystem)
- On separate physical drives from the OS disk
- Same capacity across all nodes (mixed sizes are supported but not recommended — Ceph uses the smallest size for PG placement)

### Network

| Interface | Minimum | Recommended | Purpose |
|-----------|---------|-------------|---------|
| bond0 (cluster traffic) | 2× 10 GbE | 2× 25 GbE | API, ingress, pod-to-pod, etcd |
| bond1 (ODF storage) | 2× 10 GbE | 2× 10 GbE | Ceph replication, OSD traffic |

ODF storage network throughput requirement:

- Minimum: 10 Gbps aggregate for OSD replication (1 GbE per OSD is a rule of thumb)
- Recommended: 2× 10 GbE bonded for ~20 Gbps aggregate on bond1

> Using Multus for ODF storage isolation (`odf_use_multus: true`) requires bond1 to support macvlan. This is the default for bare-metal. KVM does not support macvlan on virtio NICs — see [ADR-0005](../adrs/adr-0005-odf-on-local-nvme-with-multus-storage-network.md).

---

## SNO (Single-Node OpenShift)

SNO runs everything on one node. ODF is not supported because Ceph requires 3 nodes for quorum. Storage must be provided externally.

### CPU

| Tier | Spec | Notes |
|------|------|-------|
| Minimum | 8 physical cores | Sufficient for control-plane and light workloads |
| Recommended | 16+ physical cores | Allows AAP and Pipelines; Virtualization needs more |

### RAM

| Tier | RAM | Notes |
|------|-----|-------|
| Minimum | 32 GB | OpenShift installer requirement for SNO |
| Recommended | 64–128 GB | Comfortable for AAP + Pipelines without ODF overhead |
| With Virtualization | 128+ GB | KubeVirt VMs add RAM on top of platform services |

SNO does not run ODF, which saves approximately 40–80 GB of RAM compared to a converged node:
- No Ceph MGR, MDS, OSD processes
- No NooBaa (object storage gateway)

### Storage

SNO has no ODF. Options for persistent storage:

| Option | Notes |
|--------|-------|
| NFS (via helper) | Simple; adequate for AAP PostgreSQL and Pipelines artifacts |
| iSCSI (external SAN) | Production-grade; requires iSCSI initiator on the node |
| hostPath (development only) | No redundancy; data lost if node is rebuilt |
| External Ceph/ODF cluster | Full feature set; requires separate storage cluster |

### OS disk

Same requirements as converged: NVMe preferred, minimum 240 GB.

---

## Helper node sizing

The helper node runs: BIND DNS (`bind-in-podman`), HAProxy load balancer, the Ansible control machine, HTTP server for the ISO, and `openshift-install`. It does not need to be powerful.

| Resource | Minimum | Notes |
|----------|---------|-------|
| CPU | 4 cores | Ansible and HTTP serving are not CPU-intensive |
| RAM | 16 GB | `openshift-install` and `bind` are lightweight |
| Disk | 500 GB | ISO images (~1 GB) + install artifacts + Ansible logs |
| Network | 1 GbE | Connected to both the BMC management network and cluster provisioning network |

The helper can be:
- A separate physical server (recommended for production)
- A VM on the same rack (adequate for lab)
- The IBM Cloud bare-metal server itself (KVM path — not used for bare-metal direct)

---

## Platform service RAM budget

Use this table to estimate node RAM requirements before deployment. All figures are Kubernetes `requests` (what the scheduler uses for placement) and `limits` (the hard cap).

| Service | Component | RAM request | RAM limit | Nodes |
|---------|-----------|------------|----------|-------|
| ODF — Ceph MON | `rook-ceph-mon` | 1 GB | 2 GB | All 3 |
| ODF — Ceph MGR | `rook-ceph-mgr` | 512 MB | 1 GB | 1 (active) |
| ODF — Ceph OSD | `rook-ceph-osd` | 4 GB | 4 GB | 1 per OSD disk per node |
| ODF — Ceph MDS | `rook-ceph-mds` | 8 GB | 16 GB | 2 (active+standby) |
| ODF — NooBaa core | `noobaa-core` | 4 GB | 16 GB | 1 |
| ODF — NooBaa DB | `noobaa-db-pg` | 1 GB | 4 GB | 1 |
| OpenShift Pipelines | `tekton-pipelines-*` | 100 MB | 200 MB | — |
| AAP operator | `aap-operator` | 200 MB | 400 MB | — |
| AAP controller | `automation-controller` | 2 GB | 4 GB | — |
| AAP hub | `private-automation-hub` | 1 GB | 2 GB | — |
| cert-manager | `cert-manager` + `cainjector` | 128 MB | 512 MB | — |
| OpenShift Virtualization | `virt-operator` + `virt-handler` | 256 MB | 512 MB | All 3 |
| Control-plane (etcd) | `etcd` | 600 MB | 16 GB | All 3 |
| Control-plane (API server) | `kube-apiserver` | 1 GB | 8 GB | All 3 |

### Estimated total RAM usage per converged node (all services, steady state)

| Category | Approx RAM per node |
|----------|---------------------|
| OpenShift control-plane | ~8–12 GB |
| ODF (Ceph, distributed across 3 nodes) | ~15–25 GB |
| Platform services (AAP, Pipelines, cert-manager) | ~5–10 GB |
| Operating system + kubelet overhead | ~4–6 GB |
| **Total (steady state)** | **~32–53 GB** |
| **Recommended node RAM** | **128 GB** (leaves 75+ GB headroom for workloads) |

> Ceph OSD processes are the dominant RAM consumers. Each OSD uses 4 GB request. With 2 OSD disks per node, ODF alone consumes ~8 GB per node in requests, plus MDS and MGR distributed overhead.

---

## Network bandwidth guidance

### Inter-node bandwidth requirements

| Traffic type | Minimum | Recommended | Notes |
|-------------|---------|-------------|-------|
| Cluster (API, etcd, pod-to-pod) | 10 Gbps | 25 Gbps | etcd is latency-sensitive; use low-latency switches |
| ODF storage (Ceph replication) | 10 Gbps | 10 Gbps | Saturates with large RWX workloads; dedicated bond1 recommended |
| BMC management | 100 Mbps | 1 Gbps | ISO mount and power control; shared with OOB switch |

### Switch port recommendations

| Topology | Cluster switch | Storage switch | BMC/OOB switch |
|----------|---------------|----------------|----------------|
| Converged (3-node) | 10 GbE minimum, 25 GbE recommended | 10 GbE per node | 1 GbE per BMC |
| SNO | 1 GbE adequate, 10 GbE recommended | N/A (no ODF) | 1 GbE per BMC |

> A common practice is to use a single 25 GbE ToR (top-of-rack) switch for both cluster and storage traffic, with VLANs separating them. A separate 1 GbE OOB switch for BMC access is strongly recommended — it allows you to power-cycle and troubleshoot nodes even when the cluster switch is misconfigured.

### etcd latency requirement

etcd requires low write latency to the OS disk for stable cluster operation. Red Hat recommends:

- Disk write latency: < 10 ms p99 (use `fio` to verify before deployment)
- Network latency (between etcd members): < 10 ms RTT

```bash
# Test disk latency on a node before deploying:
fio --rw=write --ioengine=sync --fdatasync=1 --directory=/var/lib/etcd \
    --size=22m --bs=2300 --name=etcd-test 2>&1 | grep -E 'lat|iops'

# Test network latency between nodes:
ping -c 100 <node-ip> | tail -1
```
