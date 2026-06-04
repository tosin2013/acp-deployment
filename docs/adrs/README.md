# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) for the ACP Deployment project.

ADRs document significant architectural decisions made during the design and development of the OPAF Advanced Computing Platform (ACP) reference implementation. Each ADR uses the [Nygard format](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions): **Context**, **Decision**, and **Consequences**.

## Index

| ADR | Title | Status | Date |
|-----|-------|--------|------|
| [ADR-0001](adr-0001-use-ansible-as-primary-automation-tool.md) | Use Ansible as Primary Automation Tool | Accepted | 2026-06-03 |
| [ADR-0002](adr-0002-agent-based-openshift-installation-via-iso.md) | Agent-Based OpenShift Installation via ISO | Accepted | 2026-06-03 |
| [ADR-0003](adr-0003-helper-node-centric-deployment-model.md) | Helper-Node-Centric Deployment Model | Accepted | 2026-06-03 |
| [ADR-0004](adr-0004-support-ha-and-non-ha-cluster-architecture-modes.md) | Support Both HA and Non-HA Cluster Architecture Modes | Accepted | 2026-06-03 |
| [ADR-0005](adr-0005-odf-on-local-nvme-with-multus-storage-network.md) | OpenShift Data Foundation on Local NVMe with Multus Storage Network Isolation | Accepted | 2026-06-03 |
| [ADR-0006](adr-0006-operator-driven-post-install-configuration-via-olm.md) | Operator-Driven Post-Install Configuration via OLM | Accepted | 2026-06-03 |
| [ADR-0007](adr-0007-connected-cluster-with-red-hat-operator-catalog.md) | Connected Cluster with Red Hat Operator Catalog Dependency | Accepted | 2026-06-03 |
| [ADR-0008](adr-0008-optional-bind-in-podman-for-lab-dns.md) | Optional BIND-in-Podman for Lab DNS | Accepted | 2026-06-03 |
| [ADR-0009](adr-0009-zerossl-cert-manager-dns01-tls.md) | ZeroSSL + cert-manager with DNS-01 Challenge for TLS Certificate Management | Accepted | 2026-06-03 |
| [ADR-0010](adr-0010-aap-as-acp-dcn-management-layer.md) | Ansible Automation Platform as the ACP-to-DCN Management Layer | Accepted | 2026-06-03 |
| [ADR-0011](adr-0011-openshift-version-pinned-to-4-13.md) | OpenShift Version Pinned to 4.13 with Version-Specific Operator Channels | Superseded by ADR-0013 | 2026-06-03 |
| [ADR-0012](adr-0012-ovn-kubernetes-cni-nmstate-bonded-interfaces.md) | OVN-Kubernetes CNI with nmstate-Managed Bonded Interfaces | Accepted | 2026-06-03 |
| [ADR-0013](adr-0013-update-openshift-version-track-to-4-21.md) | Update OpenShift Version Track to 4.21 | Accepted | 2026-06-03 |
| [ADR-0014](adr-0014-ibm-cloud-bare-metal-as-kvm-host-and-helper.md) | IBM Cloud Bare Metal as Combined KVM Host and Helper Node | Accepted | 2026-06-03 |
| [ADR-0015](adr-0015-haproxy-external-access-ibm-cloud.md) | HAProxy as External Access Layer for IBM Cloud Cluster | Accepted | 2026-06-03 |
| [ADR-0016](adr-0016-route53-external-dns-ibm-cloud.md) | Route53 as External DNS for IBM Cloud Cluster Access | Accepted | 2026-06-03 |
| [ADR-0017](adr-0017-dnsmasq-internal-kvm-cluster-dns.md) | dnsmasq for Internal KVM Cluster DNS | Accepted | 2026-06-03 |
| [ADR-0018](adr-0018-mandatory-dns-verification-gate.md) | Mandatory DNS Verification Gate Before VM Deployment | Accepted | 2026-06-03 |

## Decision Relationships

```
ADR-0001 (Ansible)
  └── ADR-0003 (Helper Node)       ← Ansible's push model drives the helper-centric design
  └── ADR-0006 (OLM Operators)     ← redhat.openshift.k8s module used for all CR management
  └── ADR-0010 (AAP on ACP)        ← AAP deployed via Ansible; manages DCNs with Ansible

ADR-0002 (Agent ISO)
  └── ADR-0004 (HA/non-HA modes)  ← Both modes use agent-based installer
  └── ADR-0012 (OVN + nmstate)    ← nmstate config embedded in agent-config.yaml

ADR-0004 (HA/non-HA)
  └── ADR-0005 (ODF Storage)      ← ODF only deployed in HA mode

ADR-0005 (ODF Storage)
  └── ADR-0010 (AAP)              ← AAP PostgreSQL uses ODF StorageClass
  └── ADR-0012 (OVN + nmstate)    ← Multus macvlan NAD requires OVN-Kubernetes

ADR-0006 (OLM Operators)
  └── ADR-0007 (Connected Cluster) ← OLM requires Red Hat catalog access
  └── ADR-0011 (Version Pin)       ← [SUPERSEDED] Operator channels were version-specific to OCP 4.13
  └── ADR-0013 (Version Track)     ← Updated operator channels for OCP 4.21

ADR-0008 (BIND DNS)
  └── ADR-0003 (Helper Node)       ← DNS container runs on the helper node
  └── ADR-0017 (dnsmasq DNS)       ← dnsmasq replaces BIND-in-Podman for KVM environment

ADR-0009 (TLS/cert-manager)
  └── ADR-0006 (OLM Operators)     ← cert-manager deployed via OLM subscription
  └── ADR-0016 (Route53 DNS)       ← Route53 also used as cert-manager DNS-01 solver

ADR-0011 (Version Pin — SUPERSEDED)
  └── ADR-0013 (Version Track)     ← OCP 4.13 EOL; updated to stable/4.21 track

ADR-0013 (Version Track)
  └── ADR-0006 (OLM Operators)     ← ODF stable-4.21, AAP stable-2.6 channel updates

ADR-0014 (IBM Cloud Bare Metal)
  └── ADR-0003 (Helper Node)       ← Extends helper-node model; helper is the KVM host itself
  └── ADR-0015 (HAProxy)           ← HAProxy needed because IBM Cloud uses NAT
  └── ADR-0016 (Route53)           ← Route53 needed for external cluster access
  └── ADR-0017 (dnsmasq)           ← dnsmasq on KVM host serves internal cluster DNS

ADR-0015 (HAProxy)
  └── ADR-0014 (IBM Cloud BM)      ← HAProxy required because of IBM Cloud NAT architecture
  └── ADR-0016 (Route53)           ← Route53 A records point to the IP HAProxy listens on

ADR-0016 (Route53)
  └── ADR-0015 (HAProxy)           ← External DNS resolves to HAProxy frontend IP
  └── ADR-0009 (cert-manager)      ← Route53 is the DNS-01 solver for cert-manager

ADR-0017 (dnsmasq)
  └── ADR-0014 (IBM Cloud BM)      ← dnsmasq runs on the KVM host's libvirt bridge
  └── ADR-0018 (DNS Gate)          ← dnsmasq health checked by verify-dns-resolution.sh

ADR-0018 (DNS Verification Gate)
  └── ADR-0017 (dnsmasq)           ← Gate validates dnsmasq internal resolution
  └── ADR-0016 (Route53)           ← Gate validates Route53 external resolution
  └── ADR-0002 (Agent ISO)         ← Gate prevents ISO being used with misconfigured DNS
```

## Adding New ADRs

1. Create a new file named `adr-NNNN-short-title.md` (increment the number sequentially).
2. Use the Nygard format:
   ```markdown
   # ADR-NNNN: Title

   ## Date
   YYYY-MM-DD

   ## Status
   Proposed | Accepted | Deprecated | Superseded by [ADR-NNNN](link)

   ## Context
   ...

   ## Decision
   ...

   ## Consequences
   ...
   ```
3. Add an entry to the index table above.
4. Link related ADRs in the Decision Relationships section if applicable.

## Statuses

- **Proposed** — Under discussion; not yet adopted.
- **Accepted** — Decision is in effect and reflected in the codebase.
- **Deprecated** — Decision is no longer recommended but may still exist in the codebase.
- **Superseded** — Replaced by a newer ADR (link to the superseding ADR in the Status section).
