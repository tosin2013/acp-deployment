# ADR-0003: Helper-Node-Centric Deployment Model

## Date
2026-06-03

## Status
Accepted

## Context

ACP deployment requires a stable execution environment with access to several resources simultaneously:

- Outbound internet connectivity to download OpenShift binaries and operator images from Red Hat registries.
- Inbound network access to all cluster nodes via SSH during Ansible execution.
- Cluster API access via kubeconfig for all post-install configuration tasks.
- A location to serve the agent installer ISO over HTTP.
- An optional DNS server for lab environments without external DNS.

Ansible's push-based execution model requires a control node that can reach all managed hosts. During the multi-hour cluster installation process, the control node must maintain connectivity. Operators working on local workstations risk interruption from laptop sleep, VPN disconnects, or network changes.

## Decision

All Ansible playbooks target a single `helper` host defined in `examples/inventory.yml`. The helper node is a dedicated Linux server (or VM) that fulfills the following roles throughout the deployment lifecycle:

- **Tool host**: Downloads `openshift-install`, `oc`, and other binaries; stores generated artifacts in `~/cluster_<cluster_name>/install/`.
- **ISO file server**: Serves `agent.x86_64.iso` via Apache/HTTPD from `/var/www/html/`.
- **DNS server** (optional): Runs a BIND container via Podman when `external_dns: false`.
- **Ansible execution host**: All `redhat.openshift.k8s` module calls execute from the helper using the cluster kubeconfig at `~/cluster_<cluster_name>/install/auth/kubeconfig`.
- **Day-2 operations host**: Post-install playbooks (storage, pipelines, virtualization, AAP, TLS) are all run from the helper against the cluster API.

The inventory is intentionally minimal — a single `[helper]` host group — reflecting the single-node orchestration model.

## Consequences

**Positive:**
- Single SSH target simplifies inventory management and reduces the operational surface area.
- All deployment artifacts (kubeconfig, generated configs, binaries) are co-located on one machine, making the deployment state inspectable and reproducible.
- Playbooks can be re-run against the same helper at any point to recover from partial failures or add new services.
- The helper persists across the cluster's entire lifecycle, serving as a stable operations base.

**Negative:**
- The helper node is a single point of failure for all Ansible-driven deployment and day-2 operations. If the helper is lost, the kubeconfig and generated artifacts must be recovered or regenerated.
- Cluster kubeconfig stored on a non-clustered host (the helper) requires explicit access control policies to prevent unauthorized cluster access.
- The helper must maintain outbound internet access throughout the deployment (connected cluster assumption). Air-gapped scenarios require additional mirroring setup.
- Scaling to multiple simultaneous ACP cluster deployments requires either multiple helpers (one per cluster) or a more complex inventory organization.

## Amendment — 2026-06-04 (Post-Install Pipeline Incident)

**Incident:** All five post-install playbooks (`setup-openshift-storage.yml`, `setup-openshift-pipelines.yml`, `setup-ansible-automation-platform.yml`, `setup-openshift-virtualization.yml`, `site-post-install.yml`) use `ansible_user` in their `vars.install_dir`:
```yaml
install_dir: "/home/{{ ansible_user }}/cluster_{{ openshift.cluster_name }}/install"
```
When the helper is `localhost` with `ansible_connection: local`, Ansible does **not** auto-populate `ansible_user`. The variable is undefined, and the playbook fails at `Gathering Facts` with:
```
'ansible_user' is undefined
```
The same bug caused the `Update KUBECONFIG` handler to fail, leaving `certificate-authority-data` in the kubeconfig after API cert rotation (see ADR-0009 amendment 2026-06-04).

**Constraints added:**

1. **All inventory files using `ansible_connection: local` MUST explicitly define `ansible_user`**. The canonical form is:
   ```yaml
   ansible_user: "{{ lookup('env', 'USER') }}"
   ```
   This resolves to the OS user running Ansible for both SSH and local connections without hard-coding a username.

2. **Any task or handler that constructs a path with `ansible_user` MUST use the fallback form**:
   ```yaml
   "{{ ansible_user | default(ansible_user_id) }}"
   ```
   `ansible_user_id` is always populated by Ansible's fact gathering, making it a safe fallback when `ansible_user` is absent.

3. These constraints apply to all current and future playbooks targeting the `[helper]` host group.

**Affected files:**
- `examples/ibm-cloud-active/inventory.yml` — `ansible_user: "{{ lookup('env', 'USER') }}"` added 2026-06-04.
- `roles/update_ocp_ingress_cert/handlers/main.yml` — `ansible_user | default(ansible_user_id)` fallback added 2026-06-04.

---

## Alternatives Considered

- **Local workstation execution** — Eliminates dedicated helper hardware, but requires the operator's laptop to maintain persistent network connectivity during multi-hour install operations. Laptop sleep, VPN changes, or network interruptions will abort the deployment.
- **Bastion host with separate tool node** — A bastion for SSH access plus a separate tool/jump server for artifact storage provides better separation of concerns, but adds network complexity and doubles the infrastructure prerequisites for a testbed deployment.
- **Distributed orchestration (per-node self-config)** — Not applicable to Ansible's push model; also irrelevant before the cluster exists.
- **Ansible Automation Platform (AAP) as execution environment** — Viable for production at scale, but requires AAP infrastructure to already exist before deploying the ACP. This circular dependency makes AAP unsuitable as the Ansible execution engine for ACP bootstrapping (AAP is instead deployed *on* the ACP).


---

## Validated in Production

v4.21.0 — 2026-06-04 — IBM Cloud KVM (3-node compact), OCP 4.21.8, acp-deployment v4.21.0. All role assumptions confirmed against a fully deployed cluster.
