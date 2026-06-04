# ADR-0007: Connected Cluster with Red Hat Operator Catalog Dependency

## Date
2026-06-03

## Status
Accepted

## Context

The ACP reference implementation deploys five platform services via OLM (ADR-0006): OpenShift Pipelines, OpenShift Virtualization, OpenShift Data Foundation, Ansible Automation Platform, and cert-manager. Each requires operator images, catalog metadata, and operand images to be pulled during installation and reconciliation.

Red Hat distributes its supported operators through the `redhat-operators` CatalogSource, which is pre-configured in all OpenShift clusters and points to Red Hat's image registries (`registry.redhat.io`, `quay.io`). Accessing this catalog requires internet connectivity from the cluster nodes.

An alternative is a disconnected (air-gapped) installation, which mirrors all required images to an internal registry using `oc-mirror` and creates a custom `ImageContentSourcePolicy` to redirect pulls. This significantly increases operational complexity.

The ACP testbed's primary audience — Red Hat partners, OPAF evaluators, and internal Red Hat teams — typically operates in environments with reliable internet access. Air-gapped industrial environments are a future consideration.

## Decision

The ACP deployment assumes a connected cluster with unrestricted access to Red Hat's image registries and the `redhat-operators` CatalogSource available in `openshift-marketplace`. All operator `Subscription` CRs reference `redhat-operators` as the catalog source. No `ImageContentSourcePolicy`, custom `CatalogSource`, or mirroring configuration is implemented.

The OpenShift pull secret (required to authenticate with `registry.redhat.io`) must be provided in `extra-vars.yml` and is embedded in the agent installer `install-config.yaml`.

## Consequences

**Positive:**
- Dramatically simplifies the deployment: no mirror registry infrastructure, no `oc-mirror` configuration, no image digest pinning.
- Operators are always pulled at the latest version within the subscribed channel, ensuring security patches are applied automatically.
- The `redhat-operators` catalog is a pre-configured default in all OpenShift clusters — no additional setup is needed.
- Significantly reduces deployment time by eliminating a mirroring pre-step that can take hours for large operator catalogs.

**Negative:**
- The cluster nodes require outbound internet access to `registry.redhat.io` and `quay.io` during and after installation. Air-gapped or network-restricted industrial environments cannot use this deployment as-is.
- Operator image versions are not pinned; a catalog update could change operator behavior between deployments. This reduces deployment reproducibility.
- A valid Red Hat pull secret must be maintained and rotated; an expired pull secret will cause all operator image pulls to fail silently until the cluster's global pull secret is updated.
- Disconnected installation via `oc-mirror` is explicitly listed as a TODO in the README — this is a known gap for production ACP deployments.

## Alternatives Considered

- **Disconnected install with `oc-mirror`** — Mirrors all required images to an internal registry before installation. Enables air-gapped deployments and full reproducibility through digest-pinned images, but adds significant operational complexity: a mirror registry (e.g., Quay, Harbor) must be provisioned, `oc-mirror` configured, and `ImageContentSourcePolicy` applied. Deferred as a future enhancement.
- **Custom CatalogSource with a private operator catalog** — Allows full control over operator versions and content, but requires maintaining an internal operator catalog — a significant ongoing operational burden not appropriate for a reference implementation.
- **Manual operator installation (no OLM)** — Installs operators by directly applying CRDs, RBAC, and Deployment manifests without the catalog. Eliminates the catalog dependency but loses OLM's upgrade management, dependency resolution, and reconciliation capabilities.


---

## Validated in Production

v4.21.0 — 2026-06-04 — IBM Cloud KVM (3-node compact), OCP 4.21.8, acp-deployment v4.21.0. All role assumptions confirmed against a fully deployed cluster.
