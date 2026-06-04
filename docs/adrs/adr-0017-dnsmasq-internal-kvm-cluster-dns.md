# ADR-0017: Internal KVM Cluster DNS — dnsmasq (Single-Cluster) and VyOS (Multi-Cluster)

## Date
2026-06-03

## Status
Accepted — Amended

> Original decision (2026-06-03): dnsmasq only.
> Amendment (2026-06-03): added VyOS DNS forwarding for multi-cluster (SNO + Converged) VLAN isolation.
> **Amendment (2026-06-03, VyOS-first):** `hack/vyos-router.sh` now creates ALL provisioning VLAN
> networks (1924/1925/1926) regardless of deployment mode. `hack/setup-libvirt-networks.sh` is
> **deprecated for provisioning** and now creates the ODF storage network (`acp-storage`) only.
> **Amendment (2026-06-03, VyOS hard requirement):** VyOS router VM configuration via Cockpit is
> now a **hard requirement for ALL KVM deployments**, not just multi-cluster. `hack/verify-dns-resolution.sh`
> enforces this by checking `vyos-router` VM state before any VM creation. The prior
> "optional for single-cluster" distinction is removed. See ADR-0019.
> See the **Amendment: VyOS-First Architecture** section below.

## Context

OpenShift cluster VMs running on libvirt networks must resolve cluster FQDNs during the agent-based installation process, before OpenShift's internal CoreDNS service is operational. The installer requires:

- `api.<cluster>.<domain>` → API VIP
- `api-int.<cluster>.<domain>` → API VIP (internal alias)
- `*.apps.<cluster>.<domain>` → Ingress VIP

These internal VIPs are on the libvirt NAT network and are **not** the same as the IBM Cloud public IP exposed via Route53 (ADR-0016). If VMs resolved FQDNs via public DNS, they would get the public IP and route cluster traffic through IBM Cloud NAT and HAProxy — adding latency and a routing dependency during install.

This project supports two deployment modes that require different DNS approaches:

| Mode | Clusters | DNS solution |
|------|----------|-------------|
| **Single-cluster** | One cluster at a time (SNO OR Converged) | dnsmasq on KVM host bridge |
| **Multi-cluster** | SNO AND Converged simultaneously | VyOS DNS forwarding per VLAN |

## Decision

### Single-cluster mode: dnsmasq

For single-cluster deployments, `dnsmasq` is injected into libvirt's built-in dnsmasq via `virsh net-update` (managed by `hack/setup-dnsmasq.sh`). This binds to the libvirt bridge IP (`192.168.50.1` for the provisioning network) and serves only the cluster VMs.

DNS records injected into libvirt's dnsmasq:
```
address=/api.<CLUSTER_NAME>.<BASE_DOMAIN>/192.168.50.253
address=/api-int.<CLUSTER_NAME>.<BASE_DOMAIN>/192.168.50.253
address=/.apps.<CLUSTER_NAME>.<BASE_DOMAIN>/192.168.50.252
```

Cluster VMs receive `192.168.50.1` as their DNS server from libvirt DHCP.

### Multi-cluster mode: VyOS DNS forwarding

For running SNO and Converged clusters simultaneously, VyOS provides per-VLAN DNS forwarding. Each cluster's VMs use the VyOS VLAN gateway as their DNS resolver:

| VLAN | Network | Gateway (DNS) | Cluster |
|------|---------|---------------|---------|
| 1924 | 192.168.49.0/24 | 192.168.49.1 | VyOS management |
| 1925 | 192.168.50.0/24 | 192.168.50.1 | Converged |
| 1926 | 192.168.51.0/24 | 192.168.51.1 | SNO |

VyOS forwards all DNS queries to upstream resolvers (1.1.1.1, 8.8.8.8). Cluster-internal FQDNs are resolved by each cluster's CoreDNS once the cluster is running. During installation (before CoreDNS), internal VIPs are specified directly in `nmstate` interface config via `agent-config.yaml` and do not require DNS resolution.

**VyOS setup** is handled by:
- `hack/vyos-router.sh` — automated: downloads ISO, creates libvirt VLAN networks, creates VM
- `docs/vyos-setup.md` — manual: interactive disk install + network config via Cockpit console

### Why the split

**IBM Cloud context:** Unlike a local developer workstation, this IBM Cloud bare-metal host already has NAT handled at the cloud layer and Route53 for external DNS. VyOS is not needed for the external routing problem — only for isolating multiple concurrent cluster VLANs from each other.

**Single cluster:** dnsmasq is zero-overhead and sufficient. VyOS adds an extra 2 GB RAM VM for no benefit when only one cluster runs at a time.

**Multiple clusters:** Without VLAN isolation, both clusters would share `192.168.50.0/24` and their VIPs would collide. VyOS separates them onto distinct `/24`s with independent DNS.

## Consequences

**Positive:**
- All deployments have consistent VLAN isolation and internet access via VyOS NAT.
- Multi-cluster deployments get proper VLAN isolation without IP conflicts.
- VyOS NAT masquerading provides cluster VMs internet access through the libvirt default network.
- VyOS DNS forwarding is simple (upstream resolvers only) — no zone file management required.
- HAProxy + Route53 + cert-manager are unchanged in both modes.

**Negative:**
- VyOS initial setup requires a mandatory manual step (interactive disk install via Cockpit console, ~10-15 min). This step cannot be automated because VyOS boots from a live ISO.
- VyOS consumes ~2 GB RAM and 20 GB disk when running.
- VyOS configuration must be re-applied if the VM is re-created (config is saved to disk but the VM definition is managed by libvirt).
- DNS verification (`hack/verify-dns-resolution.sh`) must be re-run after VyOS reconfiguration.

## Alternatives Considered

- **BIND-in-Podman (ADR-0008 approach)** — Fully featured DNS with zone files. Heavier than needed; BIND-in-Podman remains the choice for bare-metal lab environments (ADR-0008 unchanged).
- **libvirt's built-in dnsmasq** — Does not support wildcard A records via standard `virsh net-edit`. Used via injection (`virsh net-update`) for single-cluster mode.
- **Separate dnsmasq instances per cluster** — Would work but conflicts on port 53 without complex `listen-address` management per bridge. VyOS is cleaner for multi-cluster.
- **Systemd-resolved split-DNS** — Complex, interacts poorly with NetworkManager/libvirt on CentOS Stream 10.
- **VyOS for single-cluster DNS** — VyOS VM is now a hard requirement for all deployments (ADR-0019 amendment). libvirt VLAN bridge dnsmasq remains the DNS mechanism; VyOS provides routing and internet access and is required regardless of cluster count.

---

## Amendment: VyOS-First Architecture (2026-06-03)

### Problem

The original decision used `hack/setup-libvirt-networks.sh` to create both the provisioning network (`acp-provisioning`, `192.168.50.0/24`) and the storage network (`acp-storage`, `192.168.52.0/24`). The provisioning network was a simple libvirt NAT network. Over time, analysis of the upstream `openshift-agent-install` developer guide and live environment state revealed two gaps:

1. The provisioning network naming (`acp-provisioning`) was inconsistent with the VLAN-indexed naming used by `hack/vyos-router.sh` (`1925`, `1926`). The deploy scripts reference VLAN bridges (`virbr-1925`, `virbr-1926`) not the `acp-provisioning` bridge.
2. Without `vyos-router.sh` creating the VLAN networks first, `deploy-kvm-vms.sh` targets non-existent bridges, and the DNS verification gate (`hack/verify-dns-resolution.sh`) fails because `192.168.50.1` (the VLAN 1925 bridge) does not exist.

The developer guide from the upstream project ([openshift-agent-install developer guide](https://tosin2013.github.io/openshift-agent-install/developer-guide.html)) explicitly classifies VyOS as a **hard requirement** because all example configurations use VLAN-tagged libvirt networks that only `vyos-router.sh` creates.

### Decision

`hack/vyos-router.sh` is the **mandatory first step** for all IBM Cloud KVM deployments. It creates:

| Network | Bridge | CIDR | Purpose |
|---------|--------|------|---------|
| `1924` | `virbr-1924` | `192.168.49.0/24` | VyOS management |
| `1925` | `virbr-1925` | `192.168.50.0/24` | Converged cluster provisioning |
| `1926` | `virbr-1926` | `192.168.51.0/24` | SNO cluster provisioning |
| `acp-storage` | `virbr-acp2` | `192.168.52.0/24` | ODF Multus storage network |

`hack/setup-libvirt-networks.sh` is **deprecated for provisioning** and is retained only as an idempotent creator of `acp-storage` for environments that already have the VLAN networks. New deployments must run `vyos-router.sh`.

The deployment mode distinction for DNS is updated as follows. Note that **VyOS VM configuration is now a hard requirement in all modes** (see second amendment below):

| Mode | DNS mechanism | VyOS VM config required? |
|------|--------------|--------------------------|
| **Single-cluster** (SNO or Converged, not both) | libvirt VLAN bridge dnsmasq via `virsh net-update` (`hack/setup-dnsmasq.sh`) on VLAN 1925 or 1926 | **Yes — always required** (see VyOS hard requirement amendment) |
| **Multi-cluster** (SNO AND Converged simultaneously) | VyOS VM DNS forwarding per VLAN (upstream resolvers 1.1.1.1/8.8.8.8) | **Yes — always required** |

The `hack/setup-dnsmasq.sh` script auto-detects the active topology from the `examples/ibm-cloud-active` symlink:
- Symlink → `ibm-cloud-converged` → injects DNS into VLAN `1925` dnsmasq (gateway `192.168.50.1`)
- Symlink → `ibm-cloud-sno` → injects DNS into VLAN `1926` dnsmasq (gateway `192.168.51.1`)

DNS records injected:
```
address=/api.${CLUSTER_NAME}.${BASE_DOMAIN}/<API_VIP>
address=/api-int.${CLUSTER_NAME}.${BASE_DOMAIN}/<API_VIP>
address=/.apps.${CLUSTER_NAME}.${BASE_DOMAIN}/<INGRESS_VIP>
```

### Corrected Deployment Sequence

```
Phase 0:  hack/install-kvm-host.sh       # KVM packages, acp-vms pool, nested virt
Phase 1:  hack/vyos-router.sh            # VLAN networks 1924/1925/1926 + acp-storage + VyOS VM
          [REQUIRED] docs/vyos-setup.md  # VyOS disk install via Cockpit — MANDATORY for all deployments (ADR-0019)
Phase 2:  hack/setup-dnsmasq.sh          # DNS injection into active VLAN bridge
Phase 3:  hack/configure-route53-dns.sh  # External DNS
Phase 3.5: hack/verify-dns-resolution.sh # MANDATORY gate (ADR-0018)
Phase 4:  playbooks/create-installation-media.yml
Phase 5:  hack/deploy-kvm-vms.sh
```

### Consequences of Amendment

**Positive:**
- VLAN network naming is consistent between `vyos-router.sh`, `deploy-kvm-vms.sh`, and `verify-dns-resolution.sh`.
- All deployments have a consistent, tested network topology regardless of cluster count.
- Multi-cluster deployments remain fully supported via VyOS VM configuration.
- Aligns with the upstream `openshift-agent-install` reference implementation.
- `hack/verify-dns-resolution.sh` enforces VyOS VM running as a hard gate (checked automatically by `deploy-kvm-vms.sh`).

**Negative:**
- `hack/setup-libvirt-networks.sh` must not be used as the primary network setup script. Operators following older documentation may create conflicting network names.
- The `vyos-router.sh` VLAN network creation requires Cockpit to be installed for the VyOS VM console (see ADR-0019). Cockpit is installed automatically by `vyos-router.sh` if missing.


---

## Validated in Production

v4.21.0 — 2026-06-04 — IBM Cloud KVM (3-node compact), OCP 4.21.8, acp-deployment v4.21.0. All role assumptions confirmed against a fully deployed cluster.
