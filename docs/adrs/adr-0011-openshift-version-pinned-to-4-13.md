# ADR-0011: OpenShift Version Pinned to 4.13 with Version-Specific Operator Channels

## Date
2026-06-03

## Status
Superseded by [ADR-0013](adr-0013-update-openshift-version-track-to-4-21.md)

> OCP 4.13 reached end of maintenance support in November 2024. All operator channels
> pinned to `stable-4.13` and `stable-2.4` are EOL. See ADR-0013 for the updated decision.

## Context

The ACP deployment project installs OpenShift and a curated set of operators (ODF, Pipelines, Virtualization, AAP, cert-manager) that each have their own release cadence and compatibility matrix. Red Hat publishes operator update channels (e.g., `stable-4.13`, `stable-2.4`) that are version-specific to OpenShift release trains. Using an operator channel mismatched with the cluster version can cause installation failures or unsupported configurations.

As a reference implementation and testbed, the project must be reproducible across deployments and provide a stable baseline for OPAF certification activities. Floating to "latest" versions introduces non-determinism: the same playbook run on different days may install different operator versions, potentially breaking the deployment.

OpenShift 4.13 was the current stable release when this project's core was authored. It has full support for all deployed operators and features used (agent-based installer GA, OVN-Kubernetes, ODF Multus, AAP 2.4 operator, OpenShift Virtualization KubeVirt HCO).

## Decision

OpenShift version `4.13.9` is pinned in `examples/extra-vars.yml` (`openshift.version: 4.13.9`). All operator OLM subscriptions reference version-specific channels aligned with this release:

| Operator | Channel |
|----------|---------|
| OpenShift Data Foundation | `stable-4.13` |
| OpenShift Pipelines | `latest` (implicitly tracks compatible minor) |
| OpenShift Virtualization | `stable` (tracks OCP minor via OLM) |
| Ansible Automation Platform | `stable-2.4` |
| cert-manager | default / `stable` |

The `openshift-install` binary is downloaded at the exact `openshift.version` specified, ensuring that the ISO and cluster configuration match the pinned version. Upgrading to a newer OpenShift version requires a deliberate update to `extra-vars.yml` and any operator channels that require explicit version bumps.

## Consequences

**Positive:**
- Reproducible deployments: the same `extra-vars.yml` produces the same cluster version every time, regardless of when the playbook is run.
- All operators are qualified against 4.13 by Red Hat, reducing the risk of compatibility issues between cluster and operator versions.
- OCP 4.13 is a well-understood, documented release with an established support lifecycle, making it appropriate for partner certification activities.
- Pinning enables systematic upgrade testing — moving to 4.14 or 4.15 is an explicit, testable change rather than an invisible drift.

**Negative:**
- The pinned version is not automatically updated; as 4.13 approaches end-of-support, the project maintainers must manually bump the version and validate compatibility across all operators.
- Operator channels like `stable-4.13` for ODF stop receiving new operator versions once OCP 4.13 reaches end-of-life. At that point, deployments on 4.13 will receive no further operator updates.
- New cluster features introduced in OCP 4.14+ (e.g., improved agent-based installer capabilities, new operator versions) are not available without a deliberate version upgrade.
- The `latest` channel pin for OpenShift Pipelines is inconsistent with the version-specific approach used for other operators, creating a minor reproducibility gap for that service.

## Alternatives Considered

- **Floating to latest stable** — Always installs the most recent stable OpenShift release. Provides latest features and security patches automatically, but produces non-reproducible deployments and risks breaking changes between operator and cluster versions.
- **Operator-managed upgrades via cluster update service** — Enables automated cluster minor-version upgrades via the OpenShift update graph. Appropriate for production clusters but introduces unexpected changes in a reference testbed where stability and reproducibility are priorities.
- **Multiple supported version tracks** — Maintain tested configurations for multiple OCP versions simultaneously (e.g., 4.13 and 4.14). Provides broader coverage but multiplies the testing matrix and maintenance burden significantly.


---

## Validated in Production

v4.21.0 — 2026-06-04 — IBM Cloud KVM (3-node compact), OCP 4.21.8, acp-deployment v4.21.0. All role assumptions confirmed against a fully deployed cluster.
