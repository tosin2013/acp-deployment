# CLAUDE.md — AI Agent Session Guide for acp-deployment

This file provides persistent guidance for AI coding agents working in this repository.
It is updated after each Post-Resolution Hardening cycle.

---

## Project Overview

`acp-deployment` automates the deployment of an OpenShift-based Assured Communications
Platform (ACP) testbed on IBM Cloud bare-metal or KVM hosts. Primary tools: Ansible,
Kubernetes/OpenShift manifests, VyOS networking, Agent-Based Installer.

Key entry points:
- `hack/deploy-cluster.sh` — master orchestrator
- `playbooks/` — post-install Ansible playbooks
- `roles/` — Ansible roles (LSO, ODF, AAP, cert-manager, …)
- `examples/ibm-cloud-active/extra-vars.yml` — active environment config

---

## Environment Lessons

- This repo uses KVM virtualisation on IBM Cloud bare-metal hosts. VMs (`control-0`,
  `control-1`, `control-2`) run OpenShift. The helper/bastion is the physical host.
- VyOS router is a **hard requirement** — do not treat it as optional.
- `sudo` is always required for `virsh`, `virt-install`, and libvirt operations.
- Extra-vars file may contain ZeroSSL EAB credentials — never commit to git.

---

## Known Failure Patterns — v4.21

### ODF macvlan / Multus on KVM virtio

**Symptom:** `rook-ceph-mon` pods stuck in `Init:0/2` with event
`error adding container to network "ocs-public-cluster": Link not found`.
StorageCluster remains `Progressing` indefinitely.

**Check before action:** Before running `setup-openshift-storage.yml`, verify
`odf_use_multus: false` is set in `extra-vars.yml` when the target environment
is KVM. Run `systemd-detect-virt` on the bastion to confirm.

**Root cause:** ADR-0005 assumed bare-metal `bond0` with macvlan. KVM virtio
(`eth2`, tun device) cannot be a macvlan master — the Linux kernel rejects it.
The Multus CNI shim returns `Link not found`.

**See:** `docs/adrs/adr-0005-odf-on-local-nvme-with-multus-storage-network.md`
(Amendment 2026-06-04), PMB tag: `hardening, v4.21`.

---

### ODF device count mismatch — `count: 12` on KVM with 6 disks

**Symptom:** OSD prepare jobs created but PVCs stay `Pending`; or OSD pod count
does not match disk count; StorageCluster stays `Progressing`.

**Check before action:** Verify `odf_device_count` in `extra-vars.yml` equals
`(disks_per_node × node_count)`. KVM default: 2 disks × 3 nodes = **6**.

**Root cause:** `count` was hardcoded to `12` in `roles/openshift_data_foundation/vars/main.yml`.
Now parameterised via `odf_device_count | default(6)`.

---

### LSO LocalVolumeSet: zero PVs provisioned on KVM

**Symptom:** `totalProvisionedDeviceCount: 0` after LocalVolumeSet creation.
OSD prepare pods stuck `Pending` — no PVs bound.

**Check before action:** Run `oc get localvolumediscoveryresult -n openshift-local-storage -o yaml`
and look for `.spec.discoveredDevices[*].property`. KVM qcow2 virtio disks report
as `Rotational`. Ensure `deviceMechanicalProperties` includes `Rotational`.

**Root cause:** `deviceMechanicalProperties: [NonRotational]` excluded all KVM
virtual disks (which appear `Rotational` regardless of underlying storage medium).

---

### Ansible `combine()` silently coerces integer templates to strings

**Symptom:** `redhat.openshift.k8s` silently retries for minutes; StorageCluster
never created. Verbose output shows `"count": "6"` (string, not integer).

**Check before action:** When nesting `{{ x | int }}` inside a `set_fact` +
`combine()` expression, always re-apply `| int` **at the module call site** in
the `definition:` parameter — not in `vars` or `set_fact`.

**Root cause:** Ansible Jinja2 renders template strings inside `combine()` via
the standard string coercion path. `"{{ 6 | int }}"` becomes `"6"` (str) when
evaluated as a dict value inside another template expression.

**Pattern:**
```yaml
# WRONG — count will be string "6"
- set_fact:
    my_def: "{{ base_def | combine({'spec': {'count': my_var | int}}) }}"

# CORRECT — force int at the module parameter
- redhat.openshift.k8s:
    definition: "{{ my_def | combine({'spec': {'count': my_var | int}}) }}"
```

---

### VMs booting from ISO after RHCOS install

**Symptom:** Nodes reinstall RHCOS on every reboot; cluster never bootstraps.

**Root cause:** `virt-install --cdrom` sets CDROM to boot order 1, disk to 2.
After RHCOS is written, VM boots ISO again.

**Fix:** Post-`virt-install` XML patch sets `vda` to boot order 1, `sda` to 2.
See `hack/deploy-kvm-vms.sh`.

---

### cert-manager CertManager CR wrong apiVersion (OCP operator vs upstream)

**Symptom:** `redhat.openshift.k8s` fails with
`Failed to find exact match for acme.cert-manager.io/v1.CertManager by [kind, name, singularName, shortNames]`
when running `update-ocp-ingress-cert.yml`.

**Check before action:** The OCP cert-manager operator bundles the `CertManager` CR under
`operator.openshift.io/v1alpha1`, **not** the upstream `acme.cert-manager.io/v1`.
Verify with:
```bash
oc get crd certmanagers.operator.openshift.io -o jsonpath='{.spec.group}/{.spec.versions[0].name}'
# Expected: operator.openshift.io/v1alpha1
```

**Root cause:** Confusion between the upstream `acme.cert-manager.io` CRD group and the
Red Hat OCP-bundled operator's CRD group (`operator.openshift.io`). The two are different
and the upstream group does not exist in the OCP operator installation.

**Fix:** Set `apiVersion: operator.openshift.io/v1alpha1` in `_certmanager` in
`roles/update_ocp_ingress_cert/defaults/main.yml`. See ADR-0006 and ADR-0009 amendments 2026-06-04.

---

### ansible_user undefined on local connections / kubeconfig CA retained after cert rotation

**Symptom (a):** Any post-install playbook fails immediately at `Gathering Facts` with:
`The field 'module_defaults' has an invalid value ... 'ansible_user' is undefined`

**Symptom (b):** Playbooks running after `update-ocp-ingress-cert.yml` fail with:
`HTTPSConnectionPool ... SSLError CERTIFICATE_VERIFY_FAILED unable to get local issuer certificate`

**Check before action:**
1. Verify `ansible_user` is defined in the inventory for local connections:
   ```bash
   grep "ansible_user" examples/ibm-cloud-active/inventory.yml
   # Expected: ansible_user: "{{ lookup('env', 'USER') }}"
   ```
2. Verify the kubeconfig has no stale self-signed CA after cert rotation:
   ```bash
   grep -c "certificate-authority-data" ~/cluster_acp/install/auth/kubeconfig
   # Expected: 0
   ```
   If non-zero, strip with:
   ```bash
   sed -i '/^    certificate-authority-data:/d' ~/cluster_acp/install/auth/kubeconfig
   ```

**Root cause (a):** `ansible_connection: local` does not populate `ansible_user`. All five
post-install playbooks used it unguarded in `vars.install_dir`. The inventory must set
`ansible_user: "{{ lookup('env', 'USER') }}"` explicitly.

**Root cause (b):** The `Update KUBECONFIG` handler strips `certificate-authority-data`
from the kubeconfig after API cert rotation. If that handler fails (e.g., due to root cause a),
the kubeconfig retains the old self-signed CA which conflicts with the new ZeroSSL cert,
causing all subsequent `redhat.openshift.k8s` calls to fail with SSL errors.

**Fix:** See ADR-0003 and ADR-0009 amendments 2026-06-04. All five playbooks now use
`ansible_user | default(ansible_user_id)` in `install_dir`. Inventory sets `ansible_user`
explicitly. Handler uses `default(ansible_user_id)` fallback.

---

### dnsmasq restart tears down VMs' network bridges

**Symptom:** All running VMs lose network connectivity after DNS update.

**Root cause:** `virsh net-destroy` detaches all vnet interfaces from the bridge.

**Fix:** Use SIGHUP to reload dnsmasq config without network teardown.
See `hack/setup-dnsmasq.sh`.

---

## Conventions

- Always use `kubernetes.core.k8s_info` (not `redhat.openshift.k8s_info` — the latter
  does not exist in the installed collection).
- StorageCluster `count` must be an **integer** passed to the OCS API. Always force
  `| int` at the `redhat.openshift.k8s: definition:` call site.
- `virsh net-update` for live DNS changes; never `virsh net-destroy` on a network
  with running VMs.
- VyOS is a hard requirement for all KVM cluster deployments.

---

## Release History

| Version | Date | OCP | Status |
|---------|------|-----|--------|
| v4.21.0 | 2026-06-04 | 4.21.8 | First tagged release. IBM Cloud KVM (3-node compact HA). Two hardening cycles. |
| v4.20.0-rc1 | 2026-06-05 | 4.20.x | Release candidate. Branch: `release-4.20`. ODF `stable-4.20`. Not yet production validated. |

### v4.21.0 — 2026-06-04

First fully-deployed and tagged release. Validated on IBM Cloud bare-metal (KVM) with a 3-node compact
HA cluster running OpenShift 4.21.8. All post-install platform services operational:
ODF (Ceph HEALTH_OK, 6 OSDs), ZeroSSL TLS, OpenShift Pipelines, AAP, OpenShift Virtualization.

Two hardening cycles completed:

1. **ODF Multus/KVM** — `odf_use_multus: false` flag, LSO Rotational disks, integer coercion fix,
   VM RAM raised to 48 GiB. See `docs/hardening/odf-multus-kvm-v4.21-2026-06-04.md`.

2. **Post-install pipeline** — CertManager `apiVersion` fix, OLM CSV wait, `ansible_user` fallback,
   kubeconfig CA strip. See `docs/hardening/post-install-pipeline-v4.21-2026-06-04.md`.

Known limitations in this release: nested KVM required for Virt workloads; ODF not on SNO;
Route53 required for DNS-01 TLS.

Next cycle focus: DCN management via AAP, bare-metal deployment path validation, v4.22 track upgrade.
