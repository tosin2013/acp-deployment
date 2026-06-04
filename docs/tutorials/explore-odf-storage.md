# Tutorial: Explore ODF persistent storage on your ACP cluster

**Type:** Tutorial (learning-oriented)
**Audience:** Engineers who have completed [Deploy your first ACP cluster](./deploy-acp-on-ibm-cloud-kvm.md) and want to understand how persistent storage works in the cluster.
**Goal:** By the end of this tutorial you will have created a PersistentVolumeClaim, written data to it, deleted and recreated a pod, and confirmed that the data survived — demonstrating that ODF storage is working correctly.
**Time:** 30 minutes.

---

## What you need before you start

- A working ACP cluster (from the first tutorial)
- `oc` CLI configured with your kubeconfig: `export KUBECONFIG=~/cluster_acp/install/auth/kubeconfig`

---

## Part 1: Understand what ODF provides

### Step 1: Inspect the storage cluster

```bash
oc get storagecluster -n openshift-storage
```

You should see `PHASE: Ready` and `HEALTH: HEALTH_OK`.

```bash
oc get storageclass
```

ODF provides three storage classes:

| StorageClass | Access Modes | Use case |
|--------------|-------------|---------|
| `ocs-storagecluster-ceph-rbd` | RWO | Databases, single-pod volumes |
| `ocs-storagecluster-cephfs` | RWO, RWX | Shared volumes, CI pipelines |
| `openshift-storage.noobaa.io` | S3 | Object storage (buckets) |

### Step 2: Inspect the Ceph cluster

```bash
oc -n openshift-storage exec -it \
  $(oc get pods -n openshift-storage -l app=rook-ceph-tools -o name | head -1) \
  -- ceph status
```

You should see `HEALTH_OK` and 6 OSDs (2 per node × 3 nodes).

---

## Part 2: Create a PersistentVolumeClaim

### Step 3: Create a test namespace

```bash
oc new-project storage-tutorial
```

### Step 4: Create a PVC using Ceph block storage

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: tutorial-pvc
  namespace: storage-tutorial
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ocs-storagecluster-ceph-rbd
  resources:
    requests:
      storage: 1Gi
EOF
```

**Verify:**

```bash
oc get pvc tutorial-pvc -n storage-tutorial
```

The status should change from `Pending` to `Bound` within 10–15 seconds. If it stays `Pending` for more than 30 seconds, check the ODF operator logs.

### Step 5: Write data to the PVC

Create a pod that mounts the PVC and writes a file:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: writer-pod
  namespace: storage-tutorial
spec:
  containers:
    - name: writer
      image: registry.access.redhat.com/ubi9/ubi-minimal:latest
      command: ["/bin/sh", "-c"]
      args:
        - echo "ACP storage tutorial - $(date)" > /data/hello.txt && cat /data/hello.txt && sleep 3600
      volumeMounts:
        - mountPath: /data
          name: tutorial-vol
  volumes:
    - name: tutorial-vol
      persistentVolumeClaim:
        claimName: tutorial-pvc
EOF
```

Wait for the pod to start:

```bash
oc wait pod/writer-pod -n storage-tutorial --for=condition=Ready --timeout=60s
```

**Verify** the data was written:

```bash
oc exec -n storage-tutorial writer-pod -- cat /data/hello.txt
```

You should see a line like `ACP storage tutorial - Thu Jun  4 ...`.

---

## Part 3: Prove data survives pod restarts

### Step 6: Delete the pod

```bash
oc delete pod writer-pod -n storage-tutorial
```

The PVC and its data are **not** deleted. PVCs are independent of pods.

### Step 7: Create a new reader pod from the same PVC

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: reader-pod
  namespace: storage-tutorial
spec:
  containers:
    - name: reader
      image: registry.access.redhat.com/ubi9/ubi-minimal:latest
      command: ["/bin/sh", "-c", "cat /data/hello.txt && sleep 3600"]
      volumeMounts:
        - mountPath: /data
          name: tutorial-vol
  volumes:
    - name: tutorial-vol
      persistentVolumeClaim:
        claimName: tutorial-pvc
EOF

oc wait pod/reader-pod -n storage-tutorial --for=condition=Ready --timeout=60s
```

**Verify** the data survived:

```bash
oc exec -n storage-tutorial reader-pod -- cat /data/hello.txt
```

You should see the exact same line that the writer pod wrote. The data survived the pod deletion because it is stored in Ceph, not in the pod's local filesystem.

---

## Part 4: Try shared storage (CephFS)

Unlike Ceph block storage (RBD), CephFS volumes can be mounted by multiple pods simultaneously. This is essential for CI/CD pipelines where many build pods share artifacts.

### Step 8: Create a shared PVC

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shared-pvc
  namespace: storage-tutorial
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ocs-storagecluster-cephfs
  resources:
    requests:
      storage: 1Gi
EOF
```

**Verify** it binds:

```bash
oc get pvc shared-pvc -n storage-tutorial
```

### Step 9: Mount the same PVC in two pods at the same time

```bash
for i in a b; do
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: shared-$i
  namespace: storage-tutorial
spec:
  containers:
    - name: app
      image: registry.access.redhat.com/ubi9/ubi-minimal:latest
      command: ["/bin/sh", "-c", "echo 'Written by pod-$i' >> /shared/log.txt && sleep 3600"]
      volumeMounts:
        - mountPath: /shared
          name: shared-vol
  volumes:
    - name: shared-vol
      persistentVolumeClaim:
        claimName: shared-pvc
EOF
done
```

Wait for both pods:

```bash
oc wait pod/shared-a pod/shared-b -n storage-tutorial --for=condition=Ready --timeout=60s
```

**Verify** both pods wrote to the same file:

```bash
oc exec -n storage-tutorial shared-a -- cat /shared/log.txt
```

You should see entries from both `pod-a` and `pod-b` in the same file — because CephFS allows multiple pods to write to the same volume simultaneously.

---

## Clean up

```bash
oc delete project storage-tutorial
```

---

## What you learned

- ODF provides three storage classes for different access patterns
- Ceph block storage (RBD) provides persistent volumes that survive pod restarts
- CephFS provides shared read-write volumes accessible from multiple pods simultaneously
- The entire storage layer runs on your 3 cluster nodes — no external SAN or NAS required

---

## Next steps

- [How to deploy ODF storage on a KVM cluster](../how-to/deploy-odf-kvm.md)
- [Understanding ODF storage design](../explanation/odf-storage-design.md)
- [Reference: extra-vars.yml configuration](../reference/extra-vars.md)
