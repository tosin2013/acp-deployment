# ADR-0006: Operator-Driven Post-Install Configuration via OLM

## Date
2026-06-03

## Status
Accepted

## Context

After the OpenShift cluster is healthy, the ACP reference implementation must install and configure a set of platform services: OpenShift Pipelines (Tekton), OpenShift Virtualization (KubeVirt), OpenShift Data Foundation (Ceph), Ansible Automation Platform, and cert-manager. Each service requires both an operator installation (subscription to an OLM channel) and instance configuration (deploying operand CRs such as `HyperConverged`, `AutomationController`, `StorageCluster`).

There are multiple strategies for expressing this post-install configuration: direct Kubernetes manifest application (`kubectl apply`), Helm charts for packaging, GitOps-based declarative sync, or the OpenShift Operator Lifecycle Manager (OLM) subscription model.

The project must use an approach that:
- Is idempotent — re-runnable without creating duplicate resources.
- Uses supported Red Hat operator delivery mechanisms.
- Integrates naturally with Ansible as the chosen automation tool (ADR-0001).
- Does not require additional cluster infrastructure (e.g., a pre-existing ArgoCD instance).

## Decision

All platform service installations and configurations are expressed as Kubernetes Custom Resources (CRs) and managed via the `redhat.openshift.k8s` Ansible module. The pattern for each service is:

1. Create a `Namespace` for the operator (if not already present).
2. Create an `OperatorGroup` scoped to the namespace.
3. Create a `Subscription` CR pointing to the appropriate OLM catalog source (`redhat-operators`) and channel.
4. Wait for the CSV (ClusterServiceVersion) to reach `Succeeded` phase.
5. Deploy the operand CR(s) (e.g., `StorageCluster`, `HyperConverged`, `AutomationController`) that the operator then reconciles.
6. Wait for operator-reported readiness conditions.

No raw `kubectl apply` commands, Helm charts, or kustomize overlays are used. All CR definitions are stored as Ansible variables (`vars/main.yml`) or inline in tasks, rendered by the `redhat.openshift.k8s` module.

## Consequences

**Positive:**
- OLM manages operator installation, upgrade channels, dependency resolution, and RBAC, reducing the amount of boilerplate that Ansible playbooks must manage.
- The `redhat.openshift.k8s` module is idempotent by default — applying the same CR twice is a no-op if the resource already exists and matches the desired state.
- Each role encapsulates a single platform service with clear boundaries, making it easy to add, remove, or update individual services.
- Operator-driven reconciliation means the cluster self-heals operand configuration drift without re-running Ansible.
- Consistent with how Red Hat documents and supports its operators (Subscription + operand CR pattern).

**Negative:**
- OLM subscription-based installs require the cluster to pull operator images from Red Hat's registries (connected cluster requirement — see ADR-0007).
- The Ansible playbooks must implement explicit wait conditions (e.g., polling CSV phase, checking operator readiness) because OLM installs are asynchronous. Insufficient wait times cause downstream tasks to fail.
- Operator version is controlled by OLM channel selection, not a pinned image tag. Channel updates by Red Hat can change operator behavior between deployments even with the same channel name.
- Debugging OLM failures (catalog sync, image pull errors, dependency conflicts) requires OpenShift-specific knowledge beyond basic Ansible debugging skills.

## Amendment — 2026-06-04 (Post-Install Pipeline Incident)

**Incident:** During the first execution of `update-ocp-ingress-cert.yml` on a fresh cluster, step 4 (CSV wait) was missing from `roles/update_ocp_ingress_cert/tasks/cert-manager-operator.yml`. The playbook attempted to apply the `CertManager` operand CR immediately after creating the Subscription, before OLM had finished registering the `operator.openshift.io/v1alpha1` CRDs. The task failed with `Failed to find exact match for acme.cert-manager.io/v1.CertManager`.

**Root cause:** Two related gaps: (a) the CSV wait task was absent — violating the pattern defined in this ADR; (b) the `CertManager` CR used the wrong `apiVersion` (`acme.cert-manager.io/v1` instead of the OCP-bundled operator's group `operator.openshift.io/v1alpha1`).

**Constraints added:**

1. **Every role implementing the OLM pattern MUST include a CSV wait task** before any operand CR application. The canonical implementation is:
   ```yaml
   - name: Wait for <operator> CSV to succeed
     kubernetes.core.k8s_info:
       api_version: operators.coreos.com/v1alpha1
       kind: ClusterServiceVersion
       namespace: <operator-namespace>
     register: _csv
     retries: 30
     delay: 15
     until:
       - _csv.resources | length > 0
       - _csv.resources | selectattr('status.phase', 'equalto', 'Succeeded') | list | length > 0
   ```

2. **OCP-bundled operator CRDs use `operator.openshift.io` as their API group**, not the upstream project's API group. Before writing an operand CR, verify the correct `apiVersion` with:
   ```bash
   oc get crd | grep <operator-keyword>
   oc get crd <crd-name> -o jsonpath='{.spec.group}/{.spec.versions[0].name}'
   ```
   For cert-manager: the operand CR is `operator.openshift.io/v1alpha1 CertManager` (not `acme.cert-manager.io/v1 CertManager`).

**Affected file:** `roles/update_ocp_ingress_cert/tasks/cert-manager-operator.yml` — CSV wait task added 2026-06-04.

---

## Alternatives Considered

- **Raw `kubectl apply` / `oc apply` manifests** — Direct and transparent, but requires maintaining full RBAC, CRD, and operator deployment YAML manually. Does not benefit from OLM's dependency resolution or upgrade management.
- **Helm charts** — Widely used for packaging Kubernetes applications; however, Red Hat's operators are not distributed as Helm charts. Layering Helm on top of OLM adds unnecessary complexity.
- **Kustomize overlays** — Useful for environment-specific patching of base manifests, but not a deployment mechanism for operators and does not integrate naturally with Ansible's variable system.
- **OpenShift GitOps (ArgoCD)** — Excellent for declarative drift correction in production, but requires ArgoCD to be installed before it can manage other operators — a chicken-and-egg problem at cluster bootstrap time.


---

## Validated in Production

v4.21.0 — 2026-06-04 — IBM Cloud KVM (3-node compact), OCP 4.21.8, acp-deployment v4.21.0. All role assumptions confirmed against a fully deployed cluster.
