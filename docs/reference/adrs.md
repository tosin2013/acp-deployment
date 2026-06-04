# Reference: Architectural Decision Records

All design decisions for the ACP deployment project are documented as Architectural Decision Records (ADRs) in `docs/adrs/`. Each ADR captures the context, decision, consequences, and alternatives considered.

All 19 ADRs were validated against the v4.21.0 production deployment on 2026-06-04.

---

## ADR index

| ADR | Title | Status | Validated |
|-----|-------|--------|-----------|
| [ADR-0001](../adrs/adr-0001-use-ansible-as-primary-automation-tool.md) | Use Ansible as Primary Automation Tool | Accepted | v4.21.0 |
| [ADR-0002](../adrs/adr-0002-agent-based-openshift-installation-via-iso.md) | Agent-Based OpenShift Installation via ISO | Accepted | v4.21.0 |
| [ADR-0003](../adrs/adr-0003-helper-node-centric-deployment-model.md) | Helper-Node-Centric Deployment Model | Accepted | v4.21.0 |
| [ADR-0004](../adrs/adr-0004-support-ha-and-non-ha-cluster-architecture-modes.md) | Support HA and Non-HA Cluster Architecture Modes | Accepted | v4.21.0 |
| [ADR-0005](../adrs/adr-0005-odf-on-local-nvme-with-multus-storage-network.md) | ODF on Local NVMe with Multus Storage Network | Accepted | v4.21.0 |
| [ADR-0006](../adrs/adr-0006-operator-driven-post-install-configuration-via-olm.md) | Operator-Driven Post-Install Configuration via OLM | Accepted | v4.21.0 |
| [ADR-0007](../adrs/adr-0007-connected-cluster-with-red-hat-operator-catalog.md) | Connected Cluster with Red Hat Operator Catalog | Accepted | v4.21.0 |
| [ADR-0008](../adrs/adr-0008-optional-bind-in-podman-for-lab-dns.md) | Optional BIND in Podman for Lab DNS | Accepted | v4.21.0 |
| [ADR-0009](../adrs/adr-0009-zerossl-cert-manager-dns01-tls.md) | ZeroSSL + cert-manager with DNS-01 for TLS | Accepted | v4.21.0 |
| [ADR-0010](../adrs/adr-0010-aap-as-acp-dcn-management-layer.md) | AAP as ACP DCN Management Layer | Accepted | v4.21.0 |
| [ADR-0011](../adrs/adr-0011-openshift-version-pinned-to-4-13.md) | OpenShift Version Pinned to 4.13 | Superseded by ADR-0013 | v4.21.0 |
| [ADR-0012](../adrs/adr-0012-ovn-kubernetes-cni-nmstate-bonded-interfaces.md) | OVN-Kubernetes CNI + NMState Bonded Interfaces | Accepted | v4.21.0 |
| [ADR-0013](../adrs/adr-0013-update-openshift-version-track-to-4-21.md) | Update OpenShift Version Track to 4.21 | Accepted | v4.21.0 |
| [ADR-0014](../adrs/adr-0014-ibm-cloud-bare-metal-as-kvm-host-and-helper.md) | IBM Cloud Bare-Metal as KVM Host and Helper | Accepted | v4.21.0 |
| [ADR-0015](../adrs/adr-0015-haproxy-external-access-ibm-cloud.md) | HAProxy External Access for IBM Cloud | Accepted | v4.21.0 |
| [ADR-0016](../adrs/adr-0016-route53-external-dns-ibm-cloud.md) | Route53 External DNS for IBM Cloud | Accepted | v4.21.0 |
| [ADR-0017](../adrs/adr-0017-dnsmasq-internal-kvm-cluster-dns.md) | dnsmasq Internal KVM Cluster DNS | Accepted | v4.21.0 |
| [ADR-0018](../adrs/adr-0018-mandatory-dns-verification-gate.md) | Mandatory DNS Verification Gate | Accepted | v4.21.0 |
| [ADR-0019](../adrs/adr-0019-cockpit-vyos-console-management.md) | Cockpit + VyOS Console Management | Accepted | v4.21.0 |

---

## ADRs amended during v4.21.0 release cycle

The following ADRs were amended to address issues discovered during the v4.21.0 deployment:

| ADR | Amendment |
|-----|----------|
| ADR-0003 | `ansible_user` must be explicitly set for `ansible_connection: local`; use `ansible_user \| default(ansible_user_id)` fallback in path construction |
| ADR-0004 | KVM virtualisation sub-mode added: `odf_use_multus` and `odf_device_count` required for KVM HA deployments |
| ADR-0005 | `odf_use_multus: false` required on KVM (virtio does not support macvlan); `odf_device_count: 6` for KVM (2 disks × 3 nodes) |
| ADR-0006 | Explicit `Wait for CSV Succeeded` task required before applying operand CRs; `operator.openshift.io` API group for OCP-bundled operators |
| ADR-0009 | `CertManager` CR `apiVersion` is `operator.openshift.io/v1alpha1`; `certificate-authority-data` must be stripped from kubeconfig after API cert rotation |

---

## ADR format

Each ADR follows this structure:

```
# ADR-XXXX: Title

## Date
## Status
## Context
## Decision
## Consequences
## Alternatives Considered
## Amendment (if applicable)
## Validated in Production
```
