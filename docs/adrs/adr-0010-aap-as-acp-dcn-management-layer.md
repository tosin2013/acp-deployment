# ADR-0010: Ansible Automation Platform as the ACP-to-DCN Management Layer

## Date
2026-06-03

## Status
Accepted

## Context

The OPAF (Open Process Automation Forum) architecture defines two primary compute tiers:

- **ACP (Advanced Computing Platform)**: The central compute cluster running platform services, analytics, and orchestration — implemented as an OpenShift cluster in this reference.
- **DCN (Distributed Control Node)**: The field-level devices running real-time control processes, typically running on embedded Linux or RTOS systems physically close to industrial equipment.

The ACP must provide an automation and orchestration layer capable of:
- Managing configuration, software updates, and health monitoring of distributed DCN devices.
- Executing automation workflows on DCNs in response to platform events.
- Providing an operator-facing UI and API for managing the DCN fleet.

The automation tool for the ACP deployment is Ansible (ADR-0001). The natural extension of Ansible at scale — with a web UI, RBAC, credential management, job scheduling, and a REST API — is Red Hat Ansible Automation Platform (AAP).

## Decision

Ansible Automation Platform 2.4 is deployed on the ACP OpenShift cluster as the management layer for DCN automation. AAP is installed via OLM (ADR-0006) using the `ansible-automation-platform` operator from `redhat-operators`.

The deployment implemented in `playbooks/setup-ansible-automation-platform.yml` and `roles/ansible_automation_platform/`:
- Subscribes to the AAP operator channel `stable-2.4`.
- Deploys an `AutomationController` CR with 1 replica in the `aap` namespace.
- Uses the ODF-provided `ocs-storagecluster-ceph-rbd` StorageClass for the AAP PostgreSQL database PVC (requires ODF to be deployed first — ADR-0005).
- Waits for the AutomationController to reach `Successful` phase before returning.

AAP's AutomationController (formerly Ansible Tower) provides:
- A web UI and REST API for managing Ansible inventories, credentials, job templates, and workflows targeting DCN devices.
- RBAC for multi-team access to the automation platform.
- Integration with OpenShift's OAuth for single sign-on.

## Consequences

**Positive:**
- AAP is a Red Hat-supported, enterprise-grade product that aligns with OPAF's requirement for a production-representative ACP implementation.
- Deploys directly on the ACP cluster, removing the need for external AAP infrastructure.
- ODF-backed PostgreSQL storage (ADR-0005) provides HA storage for AAP's database, supporting testbed restarts.
- AAP's REST API and webhooks enable future integration with ACP platform services (Tekton pipelines, OpenShift Virtualization).
- Positions the ACP as a complete automation hub for the DCN fleet, consistent with the OPAF reference architecture.

**Negative:**
- AAP requires a separate Red Hat subscription beyond the OpenShift subscription. Partners evaluating the ACP without an AAP subscription cannot deploy this component.
- A single `AutomationController` replica provides no HA for the AAP service itself. A replica count greater than 1 requires an external database (not configured here).
- AAP is deployed with default resource limits; production DCN fleet management at scale may require resource tuning not documented in the current role.
- AAP initial setup (creating inventories, credentials, job templates for DCN management) is not automated in the current playbooks — only the operator and controller instance are provisioned.

## Alternatives Considered

- **Standalone AWX** — The upstream open-source version of AAP. Avoids the AAP subscription requirement but is not Red Hat supported and may not meet OPAF certification requirements for a reference ACP implementation.
- **Direct SSH automation from the ACP** — Ansible playbooks executed directly from the helper node or cluster (via Jobs) targeting DCN devices. Viable for small DCN fleets but does not scale, lacks RBAC, and has no persistent job history or scheduling.
- **Third-party RPA / automation tools** — Vendor-specific industrial automation platforms (e.g., PTC ThingWorx, Siemens MindSphere). Introduces proprietary tooling that conflicts with the OPAF open-standards mandate.
- **OpenShift GitOps (ArgoCD) for DCN config management** — Suitable for Kubernetes workloads but not designed for managing non-Kubernetes edge devices running on embedded Linux or RTOS.


---

## Validated in Production

v4.21.0 — 2026-06-04 — IBM Cloud KVM (3-node compact), OCP 4.21.8, acp-deployment v4.21.0. All role assumptions confirmed against a fully deployed cluster.
