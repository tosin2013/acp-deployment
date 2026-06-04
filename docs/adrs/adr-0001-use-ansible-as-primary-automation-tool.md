# ADR-0001: Use Ansible as Primary Automation Tool

## Date
2026-06-03

## Status
Accepted

## Context

The ACP deployment project automates the end-to-end provisioning of an OpenShift-based Advanced Computing Platform (ACP) on bare-metal hardware as part of the Open Process Automation Forum (OPAF) reference implementation. The automation scope covers DNS setup, OpenShift installation media generation, and post-install configuration of multiple platform services including storage (ODF), CI/CD pipelines (OpenShift Pipelines), virtualization (OpenShift Virtualization), automation (AAP), and TLS certificate management.

Key constraints driving this choice:
- All orchestration must work against a single helper node that reaches both the public internet and the cluster network.
- Red Hat's ecosystem of Ansible collections (`redhat.openshift`, `containers.podman`, `amazon.aws`) provides first-class, idempotent support for OpenShift operator lifecycle and Kubernetes CR management.
- The project team has deep Ansible expertise and the target audience (Red Hat partners deploying ACP) is familiar with Ansible.
- The automation must be agentless — no pre-installed software on cluster nodes.

## Decision

Ansible is the sole automation tool for all deployment operations. All workflows are expressed as Ansible playbooks (entry points in `playbooks/`) and roles (reusable components in `roles/`). The following collections are used:

- **`redhat.openshift`** (`redhat.openshift.k8s` module) — for all Kubernetes CR and operator subscription management on the cluster.
- **`containers.podman`** — for container lifecycle operations on the helper node (DNS container).
- **`amazon.aws`** — optional, for Route53 DNS-01 ACME certificate challenge automation.

No Terraform, Helm, raw shell scripts, or standalone `kubectl` manifests are used for orchestration. Jinja2 templates within Ansible handle dynamic configuration generation (install-config, agent-config, BIND zone files).

## Consequences

**Positive:**
- Idempotent playbooks can be safely re-run without side effects, supporting incremental deployment and recovery from partial failures.
- Red Hat collections provide native, tested support for OpenShift operator subscriptions and Kubernetes API operations without shelling out to `oc` or `kubectl`.
- Ansible roles encapsulate each platform service cleanly, making it straightforward to add new services or override behavior with role variables.
- Agentless model (SSH-based) requires no software pre-installed on cluster nodes.
- Consistent with the broader Red Hat/OPAF ecosystem expectations for ACP automation.

**Negative:**
- Ansible is not a declarative state manager: there is no automatic drift detection. If cluster resources are modified outside of Ansible, re-running playbooks may not reconcile all differences.
- Collection version pinning is absent — no `requirements.yml` is checked into the repository. Reproducing deployments exactly requires manual collection version tracking.
- No CI/CD linting pipeline (ansible-lint, molecule) is present, increasing the risk of regressions from untested playbook changes.
- Contributors unfamiliar with Ansible, Jinja2 templating, or YAML inventory syntax face a steeper onboarding curve than script-based approaches.

## Alternatives Considered

- **Terraform with OpenShift provider** — Provides strong infrastructure state management and plan/apply workflow, but lacks mature support for operator CR lifecycle management and has no equivalent to Ansible roles for post-install configuration.
- **Helm charts** — Well-suited for Kubernetes application deployment, but not designed for bare-metal provisioning workflows, DNS setup, or ISO generation.
- **Bash scripts** — Low barrier to entry and familiar to most engineers, but inherently non-idempotent, hard to maintain at scale, and poorly suited for complex conditional logic across HA/non-HA modes.
- **OpenShift GitOps (ArgoCD)** — Excellent for day-2 declarative configuration drift correction, but not capable of bootstrapping a cluster from zero or running pre-cluster tasks like DNS and ISO generation.


---

## Validated in Production

v4.21.0 — 2026-06-04 — IBM Cloud KVM (3-node compact), OCP 4.21.8, acp-deployment v4.21.0. All role assumptions confirmed against a fully deployed cluster.
