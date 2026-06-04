# ACP Deployment Documentation

`acp-deployment` is an Ansible automation toolkit for deploying an **Advanced Computing Platform (ACP)** reference implementation on Red Hat OpenShift Container Platform 4.21.

It covers the full deployment lifecycle: KVM host preparation, cluster installation via Agent-Based Installer, and post-install platform services (ODF storage, TLS, Ansible Automation Platform, OpenShift Pipelines, OpenShift Virtualization).

Two infrastructure paths are supported: **IBM Cloud KVM** (VMs on a bare-metal server) and **Bare-Metal Direct** (physical servers via Redfish BMC).

---

## How to use these docs

These docs follow the [Diátaxis framework](https://diataxis.fr) — four distinct types of documentation, each serving a different need:

| Section | Purpose | Go here when... |
|---------|---------|----------------|
| **Tutorials** | Learning-oriented | You are new to ACP deployment and want to learn by doing |
| **How-To Guides** | Task-oriented | You know what you want to accomplish and need directions |
| **Reference** | Information-oriented | You need exact configuration parameters, script flags, or playbook inputs |
| **Explanation** | Understanding-oriented | You want to understand *why* the system works the way it does |

---

## Tutorials

Step-by-step guides that take you through a learning experience. Follow along in your own environment and end up with a working result.

| Tutorial | What you build |
|----------|---------------|
| [Deploy your first ACP cluster on IBM Cloud KVM](tutorials/deploy-acp-on-ibm-cloud-kvm.md) | A 3-node OCP cluster on KVM VMs with ODF, TLS, and platform services |
| [Explore ODF persistent storage](tutorials/explore-odf-storage.md) | Hands-on experience with Ceph block and file storage (PVCs, RWX volumes) |

---

## How-To Guides

Directions for accomplishing specific real-world goals. Each guide assumes you already understand the basics.

**Deployment tasks:**

| Guide | Goal |
|-------|------|
| [Deploy ODF storage on a KVM cluster](how-to/deploy-odf-on-kvm.md) | Install ODF with local virtual disks |
| [Configure TLS certificates with ZeroSSL](how-to/configure-zerossl-tls.md) | Replace self-signed certs with publicly trusted ZeroSSL certs |
| [Run the post-install platform services pipeline](how-to/run-post-install-pipeline.md) | Install all platform services in dependency order |
| [Expand VM RAM on running KVM nodes](how-to/expand-vm-ram.md) | Rolling RAM increase without losing cluster quorum |
| [Deploy on bare-metal servers](how-to/deploy-on-bare-metal.md) | Boot physical servers via Redfish BMC |

**Troubleshooting (from hardening reports):**

| Guide | Symptom |
|-------|---------|
| [Resolve ODF Multus macvlan failure on KVM](how-to/resolve-odf-multus-kvm.md) | StorageCluster stuck Progressing, "Link not found" errors |
| [Resolve ansible_user undefined](how-to/resolve-ansible-user-undefined.md) | Post-install playbooks fail at Gathering Facts |
| [Resolve cert-manager apiVersion mismatch](how-to/resolve-certmanager-apiversion.md) | "Failed to find exact match for acme.cert-manager.io/v1.CertManager" |
| [Resolve kubeconfig stale CA after cert rotation](how-to/resolve-kubeconfig-stale-ca.md) | CERTIFICATE_VERIFY_FAILED after API cert rotation |

---

## Reference

Accurate, complete technical facts about every user-facing element of the project.

| Reference | Contents |
|-----------|---------|
| [extra-vars.yml parameters](reference/extra-vars.md) | Every configuration parameter with type, default, and description |
| [hack/ scripts](reference/hack-scripts.md) | All CLI flags, env vars, and behavior for each script |
| [Ansible playbooks](reference/playbooks.md) | Inputs, outputs, roles, and dependency order for each playbook |
| [Architectural Decision Records](reference/adrs.md) | Index of all 19 ADRs with validation status |

---

## Explanation

Context, background, and design rationale. Answers "why?" rather than "how?".

| Explanation | Subject |
|-------------|---------|
| [Architecture overview](explanation/architecture-overview.md) | The four-layer model and how components relate |
| [Understanding the deployment pipeline](explanation/deployment-pipeline.md) | Why each of the 13 steps exists and why they must run in order |
| [KVM vs bare-metal deployment paths](explanation/kvm-vs-baremetal.md) | What differs, why it differs, and when to choose which |
| [Understanding ODF storage design](explanation/odf-storage-design.md) | Why Ceph, why LSO, why Multus, why 48 GiB RAM |
| [Why Ansible?](explanation/why-ansible.md) | The trade-offs behind the choice of Ansible as the sole automation tool |

---

## Release notes and changelog

- [v4.21.0 Release Notes](releases/v4.21.0.md)
- [CHANGELOG](../CHANGELOG.md)

---

## AI agent guidance

See [CLAUDE.md](../CLAUDE.md) for known failure patterns and conventions relevant to AI-assisted development on this repository.
