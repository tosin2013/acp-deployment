# Hardening Report: ODF Multus/macvlan Failure on KVM

| Field | Value |
|-------|-------|
| **Date** | 2026-06-04 |
| **Version** | ODF 4.21.6 / OCP 4.21 |
| **Environment** | KVM on IBM Cloud bare-metal (3 VMs as OCP control-plane) |
| **PMB tags** | `hardening`, `v4.21`, `incident` |
| **Symptom slug** | `odf-multus-kvm` |

---

## 1. Incident Reference

Discovered during post-install execution of `playbooks/setup-openshift-storage.yml`.
Root cause confirmed by `oc get events -n openshift-storage` and OCS operator logs.
Resolution verified by `PLAY RECAP: ok=16, failed=0, skipped=1`.

---

## 2. Root Cause Summary

ADR-0005 was designed for bare-metal deployments where ODF storage traffic is isolated
via a Multus macvlan NetworkAttachmentDefinition on a dedicated physical bond (`bond0`).
The StorageCluster CR contained `spec.network.provider: multus` unconditionally.

On KVM, node network interfaces are virtio (tun) devices. The Linux kernel does not
permit macvlan subinterfaces on tun devices. When rook-ceph attempted to create mon/osd
pod sandboxes, the Multus CNI shim called the kernel macvlan driver on `eth2` (virtio),
which returned `ENODEV` — surfaced as `"Link not found"` in pod events. The StorageCluster
remained stuck in `Progressing` phase indefinitely.

Three contributing defects compounded the incident:

1. **Hardcoded `count: 12`** — the StorageCluster had 12 device sets for bare-metal NVMe
   configurations. KVM VMs have 2 ODF disks × 3 nodes = 6. This caused 6 of the 12 PVCs
   to remain unbound forever.

2. **Ansible `combine()` integer coercion** — the Jinja2 template `"{{ odf_device_count | int }}"`
   evaluates to the Python integer `6` in isolation, but when nested inside a `set_fact`
   + `combine()` expression it is re-serialised as the string `"6"`. The OCS API rejected
   `count: "6"` (string) silently, causing the `redhat.openshift.k8s` module to retry the
   Create operation 30 times over 15 minutes with no visible error.

3. **LSO NonRotational filter** — `LocalVolumeSet.spec.deviceInclusionSpec.deviceMechanicalProperties`
   was `[NonRotational]`. KVM qcow2 virtio disks are reported as `Rotational` by the kernel
   regardless of the underlying storage medium. This caused `totalProvisionedDeviceCount: 0`
   and all OSD prepare pods to remain `Pending`.

---

## 3. ADRs Updated or Created

### ADR-0005 — Before

```
## Status
Accepted
```

`spec.network.provider: multus` unconditionally applied; `count: 12` hardcoded.
No KVM exception documented.

### ADR-0005 — After (Amendment 2026-06-04)

```
## Status
Accepted — Amended

> KVM virtio interfaces (eth2) do not support macvlan. A new odf_use_multus flag
> controls whether Multus is used:
> - odf_use_multus: false (KVM) — network: block omitted; Ceph uses OVN-K pod network
> - odf_use_multus: true (bare-metal) — original Multus macvlan on bond0
> odf_device_count corrected to 6 for KVM (was hardcoded 12).
```

### ADR-0004 — Before

```
## Status
Accepted
```

No sub-mode concept below `architecture: ha`.

### ADR-0004 — After (Amendment 2026-06-04)

```
## Status
Accepted — Amended

> architecture: ha alone insufficient. KVM HA vs bare-metal HA differ in:
>   odf_use_multus: false (KVM) vs true (bare-metal)
>   odf_device_count: 6 (KVM) vs 12+ (bare-metal)
```

---

## 4. Files Changed

### `roles/openshift_data_foundation/vars/main.yml`

| Change | Rationale |
|--------|-----------|
| Extracted `_storage_cluster_multus_network` as separate var | Enables conditional `combine()` in tasks |
| `count: 12` → `{{ odf_device_count \| default(6) \| int }}` | Parameterise per-environment disk count |
| Removed unconditional `network:` block from `_storage_cluster_base` | KVM-safe default |

### `roles/openshift_data_foundation/tasks/main.yml`

| Change | Rationale |
|--------|-----------|
| Added `when: odf_use_multus` to `Create NADs` task | Skip NAD on KVM |
| Added `Build StorageCluster definition` `set_fact` | Conditionally merge Multus network block |
| Force `\| int` in `Create StorageCluster` `definition:` | Overcome Ansible combine() string coercion |
| Changed `redhat.openshift.k8s_info` → `kubernetes.core.k8s_info` | Module does not exist in redhat.openshift |
| Added wait loop for `ocs-storagecluster-ceph-rbd` before patching default SC | Prevent premature CREATE attempt |

### `roles/openshift_local_storage/vars/main.yml`

| Change | Rationale |
|--------|-----------|
| Added `Rotational` to `deviceMechanicalProperties` | KVM qcow2 disks reported as Rotational |

### `examples/ibm-cloud-active/extra-vars.yml`

| Change | Rationale |
|--------|-----------|
| Added `odf_use_multus: false` | Disable Multus for this KVM environment |
| Added `odf_device_count: 6` | Correct disk count for 2-disk × 3-node KVM |

### `playbooks/setup-openshift-storage.yml`

| Change | Rationale |
|--------|-----------|
| Added `systemd-detect-virt` preflight check | Fail fast if odf_use_multus: true on KVM |

### `CLAUDE.md` (new)

| Change | Rationale |
|--------|-----------|
| Created with 5 known failure patterns | AI agent session persistence |

### `hack/verify-odf-prerequisites.sh` (new)

| Change | Rationale |
|--------|-----------|
| 5-check preflight script | Catch KVM/multus mismatch, disk count, LSO provisioning before playbook |

---

## 5. CLAUDE.md Addition (exact text)

```markdown
### ODF macvlan / Multus on KVM virtio

**Symptom:** `rook-ceph-mon` pods stuck in `Init:0/2` with event
`error adding container to network "ocs-public-cluster": Link not found`.

**Check before action:** Verify `odf_use_multus: false` in `extra-vars.yml`
when the target environment is KVM. Run `systemd-detect-virt` on the bastion.

**Root cause:** KVM virtio does not support macvlan. Set `odf_use_multus: false`.
See ADR-0005 amendment 2026-06-04.
```

---

## 6. Validation Gaps and Proposed Checks

### Signal 1: KVM + Multus mismatch

| Field | Value |
|-------|-------|
| **Name** | `odf-multus-kvm-guard` |
| **Command** | `systemd-detect-virt 2>/dev/null` + check `odf_use_multus` in extra-vars |
| **Healthy output** | `kvm` with `odf_use_multus: false`, or non-KVM with `odf_use_multus: true` |
| **Failure condition** | `kvm` detected AND `odf_use_multus: true` |
| **Location** | `hack/verify-odf-prerequisites.sh` (Check 1); `playbooks/setup-openshift-storage.yml` pre_tasks |

### Signal 2: LSO provisioned device count

| Field | Value |
|-------|-------|
| **Name** | `lso-pv-count` |
| **Command** | `oc get localvolumeset local-disks -n openshift-local-storage -o jsonpath='{.status.totalProvisionedDeviceCount}'` |
| **Healthy output** | Equal to `odf_device_count` (e.g. `6`) |
| **Failure condition** | Returns `0` or value < `odf_device_count` |
| **Location** | `hack/verify-odf-prerequisites.sh` (Check 3) |

### Signal 3: StorageCluster stuck with finalizers

| Field | Value |
|-------|-------|
| **Name** | `sc-finalizer-check` |
| **Command** | `oc get storagecluster ocs-storagecluster -n openshift-storage -o jsonpath='{.metadata.deletionTimestamp}'` |
| **Healthy output** | Empty string (no deletionTimestamp) |
| **Failure condition** | Non-empty (SC stuck deleting) |
| **Location** | `hack/verify-odf-prerequisites.sh` (Check 4) |

### Signal 4: Ansible integer coercion regression test

| Field | Value |
|-------|-------|
| **Name** | `sc-count-type` |
| **Command** | `oc get storagecluster ocs-storagecluster -n openshift-storage -o jsonpath='{.spec.storageDeviceSets[0].count}'` |
| **Healthy output** | Integer (e.g. `6`, not `"6"`) — OCS API accepts and stores as integer |
| **Failure condition** | Task retries indefinitely without creating StorageCluster |
| **Location** | Post-apply check in `roles/openshift_data_foundation/tasks/main.yml` |

---

## 7. Verification: Original Failure Cannot Be Reproduced

After all patches applied, a fresh run of `playbooks/setup-openshift-storage.yml` with
`odf_use_multus: false` in `extra-vars.yml`:

| Check | Result |
|-------|--------|
| `Create NADs` task | **skipped** (correct: `when: odf_use_multus` is false) |
| `Build StorageCluster definition` | **ok** (set_fact runs) |
| `Create StorageCluster` | **ok, attempts: 1** (count sent as integer `6`) |
| 6 OSD prepare jobs | **Completed** |
| 6 OSD pods | **2/2 Running** |
| `ocs-storagecluster-ceph-rbd` StorageClass | **set as default** |
| `PLAY RECAP` | **ok=16, changed=1, failed=0, skipped=1** |
| `oc get events -n openshift-storage \| grep "Link not found"` | **0 results** (new events only) |
| `systemd-detect-virt` → `kvm` + `odf_use_multus: false` preflight | **PASS** |

The failure class — Multus macvlan on KVM virtio causing StorageCluster perpetual
`Progressing` — is now structurally impossible when `odf_use_multus: false` is set.
The `verify-odf-prerequisites.sh` preflight and the in-playbook guard both catch the
misconfiguration before any ODF resources are created.

---

*Hardening complete for v4.21. This failure class is now documented, structurally
addressed, and embedded in the project artifacts.*
