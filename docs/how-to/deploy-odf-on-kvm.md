# How to deploy ODF storage on a KVM cluster

**Goal:** Install OpenShift Data Foundation (ODF/Ceph) on a compact KVM cluster using local virtual disks.

**Prerequisites:**
- A running 3-node OCP cluster with `KUBECONFIG` set
- `odf_use_multus: false` and `odf_device_count: 6` set in your `extra-vars.yml` (mandatory for KVM — see [Understanding ODF storage design](../explanation/odf-storage-design.md))
- Each VM has 2 additional virtual disks (`vdb`, `vdc`) — created automatically by `hack/deploy-kvm-vms.sh`
- 48 GiB RAM per node minimum (ODF MDS + NooBaa require ~14 GiB headroom)

---

## 1. Run the ODF preflight check

```bash
./hack/verify-odf-prerequisites.sh \
  -e examples/ibm-cloud-active/extra-vars.yml
```

All 5 checks must pass. If any fail, fix them before proceeding.

## 2. Run the storage playbook

```bash
export KUBECONFIG=~/cluster_acp/install/auth/kubeconfig

ansible-playbook playbooks/setup-openshift-storage.yml \
  -i examples/ibm-cloud-active/inventory.yml \
  -e @examples/ibm-cloud-active/extra-vars.yml
```

The playbook runs in this order:
1. Installs Local Storage Operator (LSO) via OLM
2. Creates a `LocalVolumeSet` to auto-discover `vdb`/`vdc` on all nodes
3. Waits for LSO to provision PVs (typically 3–5 minutes)
4. Installs ODF operator via OLM
5. Creates the `StorageCluster` CR with 6 device sets
6. Waits for `PHASE: Ready` and `HEALTH: HEALTH_OK`

Total runtime: 15–25 minutes.

## 3. Verify the deployment

```bash
# StorageCluster phase
oc get storagecluster -n openshift-storage

# Ceph OSD status
oc -n openshift-storage exec -it \
  $(oc get pods -n openshift-storage -l app=rook-ceph-tools -o name | head -1) \
  -- ceph status

# Storage classes created
oc get storageclass | grep ocs
```

Expected output from `ceph status`: `HEALTH_OK`, `6 osds: 6 up, 6 in`.

## 4. Set the default StorageClass (optional)

```bash
oc patch storageclass ocs-storagecluster-ceph-rbd \
  -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "true"}}}'
```

---

**Expected outcome:** Three storage classes are provisioned and ready. `oc get pvc` in any namespace will bind against `ocs-storagecluster-ceph-rbd` by default.

**If the storage cluster does not reach HEALTH_OK:** See [How to resolve ODF Multus macvlan failure on KVM](./resolve-odf-multus-kvm.md).
