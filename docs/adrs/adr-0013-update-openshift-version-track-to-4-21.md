# ADR-0013: Update OpenShift Version Track to 4.21

## Date
2026-06-03

## Status
Accepted — Amended

> **Amendment (2026-06-03):** Extended `startingCSV` removal to cover cert-manager.
> The original decision removed `startingCSV` from the ODF subscription only. During
> the June 2026 ADR state review, the same pinned-CSV risk was identified in
> `roles/update_ocp_ingress_cert/defaults/main.yml` (`cert-manager-operator.v1.13.1`).
> That field has been removed; OLM now selects the latest CSV on `stable-v1` automatically.
> See the **Amendment** section at the bottom of this document.

## Context

ADR-0011 established OpenShift 4.13.9 as the pinned version for the ACP deployment. At the time, 4.13 was the current stable release. OpenShift 4.13 reached **end of maintenance support in November 2024**, meaning:

- No further bug-fix or security errata are published for the cluster.
- The `stable-4.13` ODF operator channel receives no further operator updates.
- The `stable-2.4` AAP channel is also past full support (ended October 2024).
- Running `openshift-install` with `version: 4.13.9` will fail because the download URL for that version's binaries is no longer reliably hosted.

As of June 2026, the supported version matrix is:

| OCP | ODF Channel | AAP Channel | Support Status |
|-----|-------------|-------------|----------------|
| 4.21 | stable-4.21 | stable-2.6 | Full support — Recommended |
| 4.20 | stable-4.20 | stable-2.6 | Maintenance support |
| 4.19 | stable-4.19 | stable-2.5/2.6 | Maintenance support |
| 4.13 | stable-4.13 | stable-2.4 | EOL — do not use |

The `version: stable` directive in the agent installer resolves to the latest stable channel, which is 4.21.x. This enables the project to remain on a supported release without requiring a hardcoded minor version bump on every update cycle.

## Decision

The following version pins are updated across the repository:

| File | Field | Old Value | New Value |
|------|-------|-----------|-----------|
| `examples/extra-vars.yml` | `openshift.version` | `4.13.9` | `stable` |
| `roles/openshift_data_foundation/vars/main.yml` | `_subscription.spec.channel` | `stable-4.13` | `stable-4.21` |
| `roles/openshift_data_foundation/vars/main.yml` | `_subscription.spec.startingCSV` | `odf-operator.v4.13.2-rhodf` | _(removed)_ |
| `roles/ansible_automation_platform/vars/main.yml` | `_subscription.spec.channel` | `stable-2.4` | `stable-2.6` |

Operators already using version-agnostic channels require no change:
- OpenShift Virtualization: `stable` (tracks OCP minor automatically)
- Local Storage Operator: `stable` (same)
- OpenShift Pipelines: `latest` (same)
- cert-manager: `stable` (same)

`startingCSV` is removed from the ODF subscription so OLM selects the latest CSV on the `stable-4.21` channel, rather than failing to find a now-deleted specific CSV.

## Consequences

**Positive:**
- The project is restored to a fully supported configuration — all operator subscriptions receive ongoing security and bug-fix updates from Red Hat.
- `version: stable` allows the `openshift-install` binary download to succeed and always resolves to a current, supported minor release without requiring a code change for each minor version bump.
- Removing `startingCSV` from the ODF subscription eliminates the risk of OLM failing when a specific CSV is rotated out of the catalog.
- OCP 4.21 includes improvements to the agent-based installer, OVN-Kubernetes, and ODF that benefit ACP deployments.

**Negative:**
- `version: stable` reduces strict reproducibility: the same `extra-vars.yml` may produce different minor versions (e.g., 4.21.14 vs 4.21.18) on different run dates. Operators who need full binary-level reproducibility should pin to a specific version (e.g., `version: 4.21.18`) and update it deliberately.
- ODF channel `stable-4.21` must be manually bumped to `stable-4.22` when the cluster is upgraded to OCP 4.22. This is an intentional forcing function for synchronized upgrades.
- AAP `stable-2.6` was GA in October 2025; any automation relying on AAP 2.4-specific API behaviour must be re-validated against 2.6.

## Alternatives Considered

- **Pin to `4.21.x` explicitly** — Provides full reproducibility at the cost of manual version bump on every patch release. Recommended for production ACP deployments where change control is required; `version: stable` is preferred for development and testing use cases.
- **Maintain parallel support for 4.13 and 4.21** — Doubles the testing matrix. Rejected: 4.13 is EOL and cannot be made supported regardless of effort.
- **Float all operator channels** — Remove all version constraints and use `latest` everywhere. Increases the risk of an operator channel change breaking the deployment without a corresponding cluster version upgrade.

---

## Amendment: Remove cert-manager `startingCSV` (2026-06-03)

### Problem

The original decision removed `startingCSV` from the ODF subscription (`roles/openshift_data_foundation/vars/main.yml`) to prevent OLM failing when a specific CSV is rotated out of the catalog. The same pinned-CSV risk existed in `roles/update_ocp_ingress_cert/defaults/main.yml`:

```yaml
# Before amendment (risky):
_subscription:
  spec:
    channel: stable-v1
    startingCSV: cert-manager-operator.v1.13.1  # ← removed
```

If `cert-manager-operator.v1.13.1` is no longer present in the `stable-v1` channel catalog when the playbook runs, OLM will fail with a `MissingRequiredCSV` error and cert-manager will not install.

### Decision

`startingCSV` is removed from the cert-manager `Subscription` in `roles/update_ocp_ingress_cert/defaults/main.yml`. OLM selects the latest available CSV on the `stable-v1` channel automatically.

### Updated Change Table

| File | Field | Old Value | New Value |
|------|-------|-----------|-----------|
| `examples/extra-vars.yml` | `openshift.version` | `4.13.9` | `stable` |
| `roles/openshift_data_foundation/vars/main.yml` | `_subscription.spec.channel` | `stable-4.13` | `stable-4.21` |
| `roles/openshift_data_foundation/vars/main.yml` | `_subscription.spec.startingCSV` | `odf-operator.v4.13.2-rhodf` | _(removed)_ |
| `roles/ansible_automation_platform/vars/main.yml` | `_subscription.spec.channel` | `stable-2.4` | `stable-2.6` |
| `roles/update_ocp_ingress_cert/defaults/main.yml` | `_subscription.spec.startingCSV` | `cert-manager-operator.v1.13.1` | _(removed)_ |

### Principle

**No operator `Subscription` in this repository should pin `startingCSV`.** OLM channel tracking is the correct mechanism for version management. When a specific operator version is required for reproducibility, pin the entire channel (e.g., `stable-4.21`) rather than a CSV within it. This principle applies to all current and future roles.


---

## Validated in Production

v4.21.0 — 2026-06-04 — IBM Cloud KVM (3-node compact), OCP 4.21.8, acp-deployment v4.21.0. All role assumptions confirmed against a fully deployed cluster.
