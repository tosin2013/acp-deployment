# How to resolve: ODF StorageCluster stuck Progressing on KVM (Multus macvlan failure)

**Symptom:** ODF StorageCluster is stuck in `PHASE: Progressing` indefinitely. Ceph pods log errors like:
```
error adding container to network "ocs-public-cluster": Link not found
```
or
```
failed to create macvlan interface: ioctl: no such device
```

**Root cause:** KVM virtio network interfaces do not support macvlan subinterfaces. The default ODF storage network configuration uses Multus macvlan, which only works on physical NIC bonds (bare-metal). On KVM, `odf_use_multus` must be `false`.

See [Understanding ODF storage design](../explanation/odf-storage-design.md) for why this difference exists.

---

## Prerequisites

- Access to `extra-vars.yml` for your cluster
- Ability to re-run Ansible playbooks

## 1. Check whether Multus is the cause

```bash
# Look for macvlan/NAD errors in Ceph pods
oc get events -n openshift-storage --sort-by=.lastTimestamp | grep -i "network\|macvlan\|link"

# Check if NADs exist (they should NOT exist on KVM)
oc get NetworkAttachmentDefinition -n openshift-storage
```

If you see NADs and macvlan errors, this guide applies.

## 2. Set odf_use_multus: false in extra-vars.yml

```bash
vi examples/ibm-cloud-active/extra-vars.yml
```

Find or add the `odf_use_multus` setting under `all_node_settings`:

```yaml
all_node_settings:
  odf_use_multus: false   # KVM virtio does not support macvlan
  odf_device_count: 6     # 2 disks × 3 nodes
```

## 3. Delete the stuck StorageCluster and NADs

```bash
# Remove finalizers to allow deletion
oc patch storagecluster ocs-storagecluster -n openshift-storage \
  -p '{"metadata":{"finalizers":[]}}' --type=merge

oc delete storagecluster ocs-storagecluster -n openshift-storage --timeout=60s

# Delete NADs
oc delete NetworkAttachmentDefinition ocs-public-cluster -n openshift-storage
```

## 4. Re-run the ODF playbook

```bash
ansible-playbook playbooks/setup-openshift-storage.yml \
  -i examples/ibm-cloud-active/inventory.yml \
  -e @examples/ibm-cloud-active/extra-vars.yml
```

With `odf_use_multus: false`, the playbook will:
- Skip NAD creation
- Create the StorageCluster without the Multus network block
- ODF storage traffic will share the primary cluster network

## 5. Verify the fix

```bash
oc get storagecluster -n openshift-storage
# PHASE should be Ready within 15 minutes
```

---

**Permanent fix:** The `odf_use_multus: false` flag is now the documented default for all KVM deployments. The ODF preflight script (`hack/verify-odf-prerequisites.sh`) will catch this misconfiguration before deployment and print an actionable error.
