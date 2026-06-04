# How to expand RAM on running KVM control nodes

**Goal:** Increase the RAM of one or more KVM control node VMs without destroying cluster quorum. This is a rolling operation — one node at a time.

**Prerequisites:**
- 3-node cluster with HA (quorum is maintained when one node is offline)
- KVM host with enough free physical RAM (target: 48 GiB × 3 = 144 GiB)
- `KUBECONFIG` set
- The new RAM size already set in `hack/deploy-kvm-vms.sh` (`RAM_MB`)

---

## 1. Confirm current RAM and cluster health

```bash
# Current RAM per node
for node in control-0 control-1 control-2; do
  virsh dominfo $node | grep "Used memory"
done

# Cluster health before starting
oc get nodes
oc get co | grep -v "True.*False.*False"
```

All nodes must be `Ready` and all cluster operators must be `Available=True`.

## 2. Update RAM in deploy-kvm-vms.sh

Open `hack/deploy-kvm-vms.sh` and update `RAM_MB`:

```bash
RAM_MB=49152   # 48 GiB
```

## 3. Cordon and drain the first node

```bash
NODE="control-0"
oc adm cordon $NODE
oc adm drain $NODE --ignore-daemonsets --delete-emptydir-data --force --timeout=300s
```

Wait for all pods to be rescheduled on the remaining two nodes.

## 4. Shut down the VM

```bash
virsh shutdown control-0
```

Wait for the VM to stop:

```bash
watch virsh domstate control-0
# Wait until it shows: shut off
```

## 5. Change the VM memory

```bash
virsh setmaxmem control-0 50331648 --config   # 48 GiB in KiB
virsh setmem control-0 50331648 --config
```

**Verify:**

```bash
virsh dominfo control-0 | grep -i memory
```

## 6. Start the VM

```bash
virsh start control-0
```

Wait for the node to rejoin the cluster (typically 2–3 minutes):

```bash
watch oc get node control-0
# Wait until STATUS = Ready
```

## 7. Uncordon the node

```bash
oc adm uncordon control-0
```

## 8. Repeat for the remaining nodes

Repeat steps 3–7 for `control-1` and `control-2`, **one at a time**. Do not proceed to the next node until the current node is back in `Ready` status.

## 9. Verify all nodes have the new RAM

```bash
for node in control-0 control-1 control-2; do
  virsh dominfo $node | grep "Used memory"
done

# Cluster health after rolling update
oc get nodes
oc get co | grep -v "True.*False.*False"
```

All three nodes should show ~50 GiB (`49152 MB` → ~50331648 KiB) and be in `Ready` state.

---

**Expected outcome:** All three VMs are running with 48 GiB RAM, the cluster is fully healthy, and any pending ODF pods (MDS, NooBaa) that were failing due to insufficient memory are now scheduled.
