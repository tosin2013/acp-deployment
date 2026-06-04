# Why Ansible? Understanding the automation philosophy of ACP deployment

The choice of Ansible as the sole automation tool for `acp-deployment` is a deliberate architectural decision (ADR-0001) that shapes everything about how the project works. This document explores why Ansible was chosen, what that choice enables, and what limitations it imposes.

---

## The problem being solved

Deploying an OpenShift cluster is not a single action — it is a sequence of operations that span at least three distinct phases:

1. **Infrastructure preparation:** DNS records, network routing, KVM VM creation or BMC-based node booting
2. **Cluster installation:** Generating and booting an installer ISO, waiting 45–90 minutes for RHCOS to install and nodes to join, then performing initial cluster configuration
3. **Platform service installation:** Deploying 5–6 Kubernetes operators via OLM, each requiring its own CR lifecycle and readiness waits

Each phase depends on the previous one. The tooling must handle long-running waits, error recovery, and re-execution without side effects. It must also work against radically different targets: the Linux helper node (for DNS, VM creation, binary downloads) and the Kubernetes API (for operator subscriptions and CR management).

---

## Why Ansible fits this problem

**Ansible spans both worlds.** A single Ansible playbook can run shell commands on the helper node to create a libvirt VM, then switch targets to run `redhat.openshift.k8s` against the cluster API — no glue code needed. Terraform is excellent at infrastructure state management but cannot manage Kubernetes operator CRs natively. Helm manages Kubernetes applications but cannot bootstrap a cluster or create DNS records. Ansible does all of it.

**Idempotency is built in.** The `redhat.openshift.k8s` module does not create a resource if it already exists with the same spec. Re-running a playbook after a partial failure is safe — it picks up where it left off. For a deployment that takes 2–3 hours and may be interrupted by network timeouts, this property is essential.

**The OLM pattern is a natural fit.** OpenShift's Operator Lifecycle Manager (OLM) installs operators asynchronously. The deployment must create a `Subscription` CR, then wait for OLM to pull images, install CRDs, and advance the ClusterServiceVersion to `Succeeded` — a process that takes 60–120 seconds. Ansible's `until` + `retries` + `delay` pattern expresses this wait naturally. Other tools would require custom polling scripts or external orchestration.

**Red Hat's ecosystem is Ansible-first.** The `redhat.openshift` and `kubernetes.core` Ansible collections are maintained by Red Hat with first-class support for all OpenShift operator patterns. The target audience for ACP deployment — Red Hat partners and field teams — is already fluent in Ansible.

---

## The trade-offs accepted

**No automatic drift detection.** Ansible is not a declarative state manager. If someone manually deletes an OLM subscription or modifies a CR outside of Ansible, re-running the playbook will not necessarily detect or remediate the drift. OpenShift's own operators handle day-2 CR drift (that is their job), but infra-level drift requires manual investigation.

**No version pinning of collections.** The project installs Ansible collections from `ansible-galaxy` at whatever version is current. This means the same playbook may produce different results on different machines if collection versions differ. A `requirements.yml` with pinned versions would solve this but is not yet implemented.

**No CI/CD test pipeline.** There is no automated test runner (molecule, ansible-lint in CI) for playbook changes. Regressions are caught in production deployments. This is a gap acknowledged in ADR-0001.

**YAML verbosity.** Expressing complex conditionals and data transformations in Ansible/Jinja2 can be verbose and surprising — particularly around type coercion (see the `| int` requirement for `StorageCluster.count`) and undefined variable handling (the `ansible_user` issue on local connections). These are footguns that Ansible-unfamiliar contributors will encounter.

---

## Alternatives that were rejected

**Terraform with OpenShift provider:** Terraform's strength is managing cloud infrastructure (VMs, networks, DNS) and detecting drift. Its weakness is operator CR lifecycle management — the OpenShift Terraform provider does not natively model OLM subscriptions, CSV readiness, or operand CRs. Connecting Terraform outputs to Ansible for post-install would add complexity without eliminating it.

**Helm:** Helm is the right tool for packaging and deploying Kubernetes *applications*. It is not designed for bootstrapping clusters, creating KVM VMs, or managing system-level DNS. It also lacks built-in support for OLM's asynchronous installation model.

**Pure Bash:** Shell scripts are familiar and transparent, but they are inherently non-idempotent. Every re-run requires manual guard clauses. Complex conditionals (HA vs SNO, KVM vs bare-metal, Multus vs no-Multus) become difficult to maintain and test. Bash also lacks first-class YAML data handling and Kubernetes API access.

**OpenShift GitOps (ArgoCD):** ArgoCD excels at day-2 declarative drift correction for running clusters. It cannot bootstrap a cluster from scratch, create DNS records, manage KVM VMs, or run pre-cluster tasks. It is a complement to this project, not a replacement.

---

## What this means for contributors

If you are extending `acp-deployment`, you are working in Ansible. Every new platform service should be expressed as a role with:
- A `vars/main.yml` defining all Kubernetes CR definitions
- A `tasks/main.yml` following the OLM pattern: Namespace → OperatorGroup → Subscription → wait CSV → operand CR → wait readiness
- Idempotent task definitions using `redhat.openshift.k8s`

See [ADR-0001](../adrs/adr-0001-use-ansible-as-primary-automation-tool.md) for the full rationale, and [ADR-0006](../adrs/adr-0006-operator-driven-post-install-configuration-via-olm.md) for the OLM pattern specification.
