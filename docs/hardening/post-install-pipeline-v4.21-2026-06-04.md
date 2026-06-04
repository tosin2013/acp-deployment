# Hardening Report: Post-Install Pipeline — v4.21 — 2026-06-04

## 1. Incident Reference

- **PMB tags:** `incident, hardening, v4.21, post-install, cert-manager, ansible_user`
- **Date:** 2026-06-04
- **Environment:** OCP 4.21, acp-deployment KVM/IBM Cloud, cert-manager-operator v1.19.0
- **Trigger:** First end-to-end run of `playbooks/site-post-install.yml` on a fresh cluster

---

## 2. Root Cause Summary

The post-install pipeline failed with four cascading bugs during its first execution.

**Bug 1 — Wrong `CertManager` CR `apiVersion`:** The `_certmanager` variable in `roles/update_ocp_ingress_cert/defaults/main.yml` used `apiVersion: acme.cert-manager.io/v1`. The OCP cert-manager operator registers its `CertManager` CR under `operator.openshift.io/v1alpha1` — a completely different API group from the upstream community project. The task failed immediately with `Failed to find exact match for acme.cert-manager.io/v1.CertManager`.

**Bug 2 — Missing OLM CSV wait:** Even with the correct API version, the first run failed because `roles/update_ocp_ingress_cert/tasks/cert-manager-operator.yml` applied the `CertManager` operand CR immediately after creating the OLM Subscription, without waiting for the CSV to reach `Succeeded`. OLM requires 60–120 seconds to pull and install the operator and register its CRDs. This violated the pattern documented in ADR-0006, which explicitly requires a CSV wait at step 4.

**Bug 3 — `ansible_user` undefined for local connections:** All five post-install playbooks used `ansible_user` in their `vars.install_dir`:
```
install_dir: "/home/{{ ansible_user }}/cluster_{{ openshift.cluster_name }}/install"
```
When `ansible_connection: local` is used (the helper is `localhost`), Ansible does not auto-populate `ansible_user`. All five playbooks failed at `Gathering Facts` with `'ansible_user' is undefined`. The same bug caused the `Update KUBECONFIG` handler to fail silently.

**Bug 4 — kubeconfig `certificate-authority-data` retained after API cert rotation:** The `Update KUBECONFIG` handler strips `certificate-authority-data` from the kubeconfig after the API server certificate is rotated to a ZeroSSL-issued cert. Because this handler failed (due to Bug 3), the kubeconfig continued pointing to the old self-signed CA. When the OpenShift Virtualization playbook subsequently connected to `api.<cluster>:6443`, the Python SSL library rejected the new ZeroSSL cert with `CERTIFICATE_VERIFY_FAILED`.

---

## 3. ADRs Updated

### ADR-0003 — Helper-Node-Centric Deployment Model

**Before (gap):** No mention of `ansible_user` behaviour for local connections.

**After (amendment 2026-06-04):** Added constraint requiring all inventory files using `ansible_connection: local` to explicitly set:
```yaml
ansible_user: "{{ lookup('env', 'USER') }}"
```
And requiring all tasks/handlers using `ansible_user` in paths to use the fallback form:
```yaml
"{{ ansible_user | default(ansible_user_id) }}"
```

### ADR-0006 — Operator-Driven Post-Install Configuration via OLM

**Before (gap):** Step 4 ("Wait for CSV to reach Succeeded") was described in the decision but not enforced — `cert-manager-operator.yml` was missing the wait task entirely.

**After (amendment 2026-06-04):** Added two constraints:
1. Every role implementing the OLM pattern **must** include a CSV wait task (canonical implementation provided).
2. OCP-bundled operator CRDs use `operator.openshift.io` as their API group, not the upstream project's group. Verification command provided.

### ADR-0009 — ZeroSSL + cert-manager with DNS-01 Challenge

**Before (gap):** Referenced "waits for CRD readiness" without specifying the correct `CertManager` CR `apiVersion`, and did not document the kubeconfig CA stripping requirement.

**After (amendment 2026-06-04):** Added two constraints:
1. `CertManager` operand CR must use `apiVersion: operator.openshift.io/v1alpha1`.
2. After API cert rotation, `certificate-authority-data` must be stripped from the kubeconfig; manual verification command and fix provided.

---

## 4. Script Patches

| File | Change | Rationale |
|------|--------|-----------|
| `roles/update_ocp_ingress_cert/defaults/main.yml` | `_certmanager.apiVersion` changed from `acme.cert-manager.io/v1` to `operator.openshift.io/v1alpha1` | Correct API group for OCP-bundled cert-manager operator |
| `roles/update_ocp_ingress_cert/tasks/cert-manager-operator.yml` | Added `Wait for cert-manager-operator CSV to succeed` task (30 retries × 15 s) | Enforces ADR-0006 step 4; prevents operand CR race against CRD registration |
| `examples/ibm-cloud-active/inventory.yml` | Added `ansible_user: "{{ lookup('env', 'USER') }}"` to helper host vars | `ansible_connection: local` does not populate `ansible_user`; fixes all 5 playbooks simultaneously |
| `roles/update_ocp_ingress_cert/handlers/main.yml` | `Update KUBECONFIG` handler path changed from `{{ ansible_user }}` to `{{ ansible_user \| default(ansible_user_id) }}` | Ensures handler completes even when `ansible_user` is undefined, so kubeconfig CA is stripped after cert rotation |
| `playbooks/setup-openshift-storage.yml` | `install_dir` uses `ansible_user \| default(ansible_user_id)` | Belt-and-suspenders: playbook works even without inventory fix |
| `playbooks/setup-openshift-pipelines.yml` | Same as above | Same rationale |
| `playbooks/setup-ansible-automation-platform.yml` | Same as above | Same rationale |
| `playbooks/setup-openshift-virtualization.yml` | Same as above | Same rationale |
| `playbooks/site-post-install.yml` | Same as above | Same rationale |

---

## 5. CLAUDE.md Additions

Two failure patterns added under `## Known Failure Patterns — v4.21`:

### Pattern: cert-manager CertManager CR wrong apiVersion

```
Symptom: Failed to find exact match for acme.cert-manager.io/v1.CertManager
Check: oc get crd certmanagers.operator.openshift.io -o jsonpath='{.spec.group}/{.spec.versions[0].name}'
       Expected: operator.openshift.io/v1alpha1
Fix: set apiVersion: operator.openshift.io/v1alpha1 in roles/update_ocp_ingress_cert/defaults/main.yml
```

### Pattern: ansible_user undefined on local connections / kubeconfig CA retained

```
Symptom (a): 'ansible_user' is undefined at Gathering Facts
Symptom (b): CERTIFICATE_VERIFY_FAILED after API cert rotation
Check (a): grep "ansible_user" examples/ibm-cloud-active/inventory.yml
           Expected: ansible_user: "{{ lookup('env', 'USER') }}"
Check (b): grep -c "certificate-authority-data" ~/cluster_acp/install/auth/kubeconfig
           Expected: 0 after TLS rotation
Fix (b):   sed -i '/^    certificate-authority-data:/d' ~/cluster_acp/install/auth/kubeconfig
```

---

## 6. Validation Gaps and Proposed Checks

**New script:** `hack/verify-post-install-prerequisites.sh`

| # | Signal | Command | Healthy Output | Failure Condition |
|---|--------|---------|----------------|-------------------|
| 1 | `ansible_user` resolves for helper | `ansible -i inventory helper -m debug -a 'var=ansible_user'` | `"ansible_user": "vpcuser"` | `VARIABLE IS NOT DEFINED` |
| 2 | cert-manager CSV Succeeded | `oc get csv -n cert-manager-operator -o jsonpath='{..status.phase}'` | `Succeeded` | Any other value or empty |
| 3 | kubeconfig no stale CA post-TLS | `grep -c certificate-authority-data kubeconfig` | `0` | `> 0` when `router-cert` secret exists |

**Usage:**
```bash
./hack/verify-post-install-prerequisites.sh \
  --inventory examples/ibm-cloud-active/inventory.yml \
  --kubeconfig ~/cluster_acp/install/auth/kubeconfig
```

**Suggested location:** Run after `setup-openshift-storage.yml` and before `update-ocp-ingress-cert.yml`, or as a standalone preflight before any post-install run.

---

## 7. Verification — Original Failures Cannot Be Reproduced

| Bug | Verification |
|-----|-------------|
| Wrong `CertManager` apiVersion | `oc get crd certmanagers.operator.openshift.io -o jsonpath='{.spec.group}/{.spec.versions[0].name}'` → `operator.openshift.io/v1alpha1`. `defaults/main.yml` now uses this group. Re-running `update-ocp-ingress-cert.yml` returns `ok` (idempotent). |
| Missing CSV wait | `cert-manager-operator.yml` now contains `Wait for cert-manager-operator CSV to succeed`. Running the playbook on a fresh cluster will wait up to 7.5 min for the CSV before applying any CR. |
| `ansible_user` undefined | `verify-post-install-prerequisites.sh` Check 1 confirms `ansible_user` resolves to `vpcuser`. All 5 playbooks now use `default(ansible_user_id)`. Re-running all playbooks returns `ok` with no `Gathering Facts` failure. |
| kubeconfig CA retained | `verify-post-install-prerequisites.sh` Check 3 confirms `certificate-authority-data` count = 0. All subsequent `redhat.openshift.k8s` calls succeed without SSL errors. |

---

*Generated by Post-Resolution Hardening Protocol. See PMB tags: `incident, hardening, v4.21`.*
