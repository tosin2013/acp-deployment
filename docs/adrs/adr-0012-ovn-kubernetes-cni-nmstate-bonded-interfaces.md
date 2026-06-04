# ADR-0012: OVN-Kubernetes CNI with nmstate-Managed Bonded Interfaces

## Date
2026-06-03

## Status
Accepted

## Context

The ACP cluster nodes require a well-defined network configuration covering three distinct traffic types:
1. **Cluster/workload traffic**: Pod-to-pod, service, and external traffic managed by the CNI plugin.
2. **Storage traffic**: Ceph replication and OSD communication between nodes (see ADR-0005).
3. **Management traffic**: OpenShift API, etcd, and node management.

Bare-metal cluster nodes in the ACP testbed typically have multiple physical NICs (network interface cards) that can be bonded for link aggregation and redundancy. OpenShift's agent-based installer (ADR-0002) requires network configuration to be embedded in the agent ISO via `agent-config.yaml` using the nmstate declarative network configuration API.

The choice of CNI plugin has significant downstream implications: it affects network policy support, performance, multi-tenancy, egress firewall capability, and compatibility with OpenShift's platform operators (e.g., Multus for additional network interfaces).

## Decision

**OVN-Kubernetes** is selected as the CNI plugin, configured via `networkType: OVNKubernetes` in `install-config.yaml`. This is the default and recommended CNI for OpenShift 4.13.

**nmstate** is used for per-node network configuration, embedded in `agent-config.yaml` via the `agent-config.yaml.j2` Jinja2 template. Each node's network configuration specifies:

- **Compute/management bond** (`bond0` or similar): Two physical NICs bonded in LACP/active-backup mode, carrying cluster traffic, with a static IP address per node.
- **Storage bond** (`bond0` with macvlan, or a separate dedicated bond): A separate bonded interface (or macvlan sub-interface) dedicated to Ceph storage replication traffic, using the storage CIDR (default `192.168.2.0/24`).
- **DNS, gateway, and routing** configured per node via nmstate `routes` and `dns-resolver` stanzas.

The storage network isolation uses a Multus `macvlan` NetworkAttachmentDefinition (NAD) created by the ODF role, which directs Ceph traffic to the dedicated storage bond. This requires OVN-Kubernetes (which supports Multus secondary networks) rather than OpenShift SDN (which does not support Multus in the same manner).

## Consequences

**Positive:**
- OVN-Kubernetes provides full Kubernetes NetworkPolicy support, egress IP, egress firewall, and hybrid overlay networking — all required for future ACP workloads.
- nmstate's declarative model ensures consistent, repeatable network configuration across cluster nodes. Static IP assignment via nmstate eliminates DHCP dependency during installation.
- Bond interfaces provide NIC redundancy and link aggregation, improving both reliability and bandwidth for cluster and storage traffic.
- Storage network isolation via Multus/macvlan prevents Ceph replication I/O from saturating the primary network, critical for predictable industrial workload performance.
- OVN-Kubernetes is the strategic CNI for OpenShift and receives active development; OpenShift SDN is in maintenance mode.

**Negative:**
- Per-node nmstate network configuration in `agent-config.yaml.j2` is verbose and complex. Each node requires explicit MAC address, IP, bond, and routing configuration — a single misconfiguration can prevent a node from joining the cluster.
- Bond configuration requires physical NIC pairing to be correctly reflected in the template variables (`mac_address_1`, `mac_address_2` per node). Hardware changes require regenerating the agent ISO.
- OVN-Kubernetes has higher resource consumption (CPU/memory) than OpenShift SDN due to its distributed control plane, which may be relevant for resource-constrained nodes.
- Multus secondary network configuration for ODF storage adds setup complexity beyond a basic single-NIC cluster. Debugging Ceph connectivity issues requires understanding Multus NAD configuration.
- The storage CIDR and interface names (`storage_interface`) are configurable but must be pre-planned and cabled before deployment; post-install network reconfiguration is not supported.

## Alternatives Considered

- **OpenShift SDN (OpenShift-SDN)** — The legacy CNI for OpenShift, now in maintenance mode. Does not support Kubernetes NetworkPolicy in full and has limited Multus integration. Rejected because the project requires Multus for ODF storage network isolation (ADR-0005) and NetworkPolicy support for future ACP workloads.
- **Calico** — High-performance CNI with strong NetworkPolicy and BGP routing support. Not a supported CNI for OLM-installed operators on OpenShift (operators are qualified against OVN-Kubernetes); using Calico would place the cluster in an unsupported configuration.
- **Single NIC per node (no bonding)** — Simpler network configuration but provides no NIC redundancy and insufficient bandwidth for concurrent cluster and storage traffic. Not suitable for production-representative ACP testbeds.
- **DHCP-based addressing** — Simpler to configure initially but requires a DHCP server infrastructure in the cluster network and risks IP address changes across reboots. Static addressing via nmstate is required for reliable etcd cluster membership and Ceph OSD routing.


---

## Validated in Production

v4.21.0 — 2026-06-04 — IBM Cloud KVM (3-node compact), OCP 4.21.8, acp-deployment v4.21.0. All role assumptions confirmed against a fully deployed cluster.
