# ADR-0020: Release Branch per OCP Minor Version

## Date
2026-06-05

## Status
Accepted

## Context

ADR-0013 established that `acp-deployment` targets OCP 4.21 as its primary version track. Two components in the repository are pinned to a specific OCP minor version and cannot be made version-agnostic without runtime conditionals:

1. **ODF subscription channel** (`roles/openshift_data_foundation/vars/main.yml`): `stable-4.21`. ODF minor-version channels are explicitly tied to the OCP minor; running `stable-4.21` against an OCP 4.20 cluster will either fail or install a mismatched operator version.

2. **Bootstrap CLI channel** (`hack/bootstrap.sh`): `stable-4.21` for RHEL 9+ helper nodes. The `oc` and `openshift-install` binaries downloaded must match the target cluster minor version.

A third group of consumers — the `examples/*/extra-vars.yml` files — use `version: stable`, which floats to whatever is latest in the `stable` channel. On `main` this resolves to 4.21.x; on a 4.20 branch it should resolve to 4.20.x.

A project team has requested support for OCP 4.20 to begin a deployment on hardware that is not yet ready for 4.21. Maintaining a single branch that conditionally selects between 4.20 and 4.21 would require adding version-detection logic to the bootstrap script and role vars — adding complexity for a problem that version-controlled branches already solve cleanly.

The upstream reference repository `RedHatEdge/acp-manifests` uses a `release-<major>.<minor>` branching model (e.g. `release-4.20`, `release-4.21`). Adopting the same convention aligns with upstream and makes the multi-version strategy immediately recognisable to contributors familiar with the upstream project.

## Decision

Adopt a **`release-<major>.<minor>` branch per supported OCP minor version**, mirroring the upstream `RedHatEdge/acp-manifests` convention.

**Branch naming:**
- `main` — always tracks the latest recommended OCP version (currently 4.21)
- `release-4.20` — targets OCP 4.20.x
- `release-4.22` — will be created when OCP 4.22 is validated (future)

**What changes per branch (the version-specific pins):**

| File | `main` (4.21) | `release-4.20` |
|------|--------------|---------------|
| `hack/bootstrap.sh` RHEL 9+ `OC_CHANNEL` | `stable-4.21` | `stable-4.20` |
| `roles/openshift_data_foundation/vars/main.yml` channel | `stable-4.21` | `stable-4.20` |
| `examples/*/extra-vars.yml` version default | `stable` (resolves 4.21.x) | `stable-4.20` (resolves 4.20.x) |

**What does NOT change per branch:**
- All Ansible playbooks and role logic (version-agnostic)
- AAP channel `stable-2.6` (AAP release train spans multiple OCP minors)
- Virtualization, LSO, cert-manager, Pipelines channels (`stable`, `stable-v1`, `latest`)
- Documentation structure (Diátaxis layout, ADRs, how-to guides, tutorials)

**Branch lifecycle:**
- A new `release-<minor>` branch is created from `main` when a project needs the older version and when the version has been validated end-to-end.
- Critical bug fixes discovered on `main` are cherry-picked to active `release-*` branches.
- A `release-*` branch is archived (read-only, no further cherry-picks) when its OCP minor version reaches end of maintenance support.
- `main` is rebased or fast-forwarded to follow the latest recommended OCP version.

**Tagging:**
- Each branch is tagged with `v<ocp-version>.<patch>` (e.g. `v4.20.0-rc1`) for release identification.
- `main` tags use the OCP version (e.g. `v4.21.0`).

## Consequences

**Positive:**
- Consumers targeting a specific OCP minor can `git checkout release-4.20` and immediately have a consistent, tested configuration.
- No runtime version-detection logic is needed in scripts or roles.
- Aligns with the upstream `RedHatEdge/acp-manifests` branching convention, reducing cognitive overhead for contributors familiar with upstream.
- Branch-level diffs are minimal and reviewable (3 lines change per new branch).

**Negative:**
- Bug fixes must be applied to multiple active branches when they are version-agnostic (mitigated by cherry-pick workflow).
- GitHub Actions CI would need to be triggered per-branch if automated testing is added in future.
- Documentation on `release-*` branches may drift from `main` if not actively maintained (mitigated by keeping docs changes to the minimum needed for version accuracy).

**Neutral:**
- The `ibm-cloud-active` example symlink in the working deployment will continue to point to the active version used on the helper node; it is not branch-specific.

## Branch inventory (as of June 2026)

| Branch | OCP version | ODF channel | Status |
|--------|-------------|-------------|--------|
| `main` | 4.21 (recommended) | `stable-4.21` | Active — production validated v4.21.0 |
| `release-4.20` | 4.20 | `stable-4.20` | Active — rc1, not yet production validated |

## Validated in Production

This ADR was accepted on 2026-06-05 as part of the `release-4.20` branch creation. The 4.20 branch has not yet been validated in production; this section will be updated when a deployment on OCP 4.20 is confirmed.
