# ADR-0004: Support Both HA and Non-HA Cluster Architecture Modes

## Date
2026-06-03

## Status
Accepted — Amended

> **Amendment (2026-06-04, KVM virtualisation sub-mode):** The `architecture: ha` flag alone is
> insufficient to describe the storage environment. A KVM-based HA deployment (3 VMs on a single
> bare-metal host) requires different ODF and LSO configuration from a bare-metal HA deployment
> (3 physical servers). The following additional variables must be set in `extra-vars.yml` for
> KVM HA deployments:
>
> | Variable | KVM value | Bare-metal value |
> |----------|-----------|-----------------|
> | `odf_use_multus` | `false` | `true` |
> | `odf_device_count` | `6` (2 disks × 3 nodes) | `12` or per-hardware |
>
> The `architecture` variable remains `ha` in both cases. The additional variables are read from
> `openshift.all_node_settings` in `extra-vars.yml`. See ADR-0005 amendment for details.

## Context

OPAF ACP testbed deployments occur across a wide range of hardware environments. Partners and teams evaluating the ACP reference implementation may have:

- **Three or more servers** available, enabling a highly-available (HA) compact 3-node control-plane cluster where all nodes are simultaneously control-plane and compute.
- **A single server** available, requiring a Single-Node OpenShift (SNO) deployment that sacrifices availability for minimal hardware footprint.

Both configurations serve legitimate use cases: HA is appropriate for production-representative testbeds and partner validation labs, while SNO suits development workstations, field demos, and resource-constrained environments.

Maintaining separate playbook repositories or codebases for each mode would double the maintenance burden and risk divergence between modes as the project evolves.

## Decision

A single `architecture` variable (`ha` or `non-HA`) controls all mode-specific behavior across playbooks, roles, and Jinja2 templates. No separate codebases or inventory files are required.

Mode differences are implemented as follows:

| Aspect | HA Mode (`architecture: ha`) | Non-HA Mode (`architecture: non-HA`) |
|--------|------------------------------|---------------------------------------|
| Node count | 3 control-plane nodes | 1 node |
| Platform | `baremetal` with API/ingress VIPs | `none` with `bootstrapInPlace` |
| Network | OVN-Kubernetes, nmstate bonded NICs | OVN-Kubernetes, simplified |
| Storage | ODF StorageCluster deployed | ODF skipped (`when: architecture == 'ha'`) |
| install-config | HA template branch | SNO template branch |

The `install-config.yaml.j2` and `agent-config.yaml.j2` Jinja2 templates branch on the `architecture` variable to produce the correct configuration for each mode. Any new role or task that is HA-specific uses the same `when: architecture == 'ha'` conditional guard.

## Consequences

**Positive:**
- A single `extra-vars.yml` and inventory file supports both deployment sizes with no playbook changes.
- Reduces maintenance burden compared to maintaining separate repositories for each mode.
- Establishes a consistent conditional pattern (`when: architecture == 'ha'`) that new roles and tasks can follow.
- Allows the same CI/CD and documentation pipeline to cover both modes.

**Negative:**
- Non-HA hardware recommendations are not fully documented (marked as TODO in README); operators deploying SNO lack equivalent guidance to the HA hardware section.
- Testing both modes requires two completely separate hardware setups; there is no automated test matrix that validates both paths.
- The `architecture` variable is an unvalidated string (`'ha'` vs `'non-HA'`). A typo or case mismatch silently falls through conditionals without an error, which can cause ODF to be skipped unexpectedly in an intended HA deployment.
- The string comparison `architecture == 'ha'` is fragile; a future refactor to a boolean or enum would require updating all conditional guards.

## Alternatives Considered

- **Separate playbook repositories for HA and non-HA** — Cleaner separation with no cross-mode conditionals, but doubles the maintenance surface and risks the two codebases drifting apart as features are added.
- **Only supporting HA mode** — Simplifies the codebase significantly but excludes resource-constrained labs, field demo environments, and single-server partner evaluations that represent a significant portion of the target audience.
- **Kubernetes node labels or taints to differentiate workloads** — Not applicable at install time; labels and taints cannot influence the installer's topology or platform configuration decisions made before the cluster exists.


---

## Validated in Production

v4.21.0 — 2026-06-04 — IBM Cloud KVM (3-node compact), OCP 4.21.8, acp-deployment v4.21.0. All role assumptions confirmed against a fully deployed cluster.
