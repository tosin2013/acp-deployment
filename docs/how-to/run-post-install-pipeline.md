# How to run the post-install platform services pipeline

**Goal:** Install all ACP platform services (ODF, TLS, Pipelines, AAP, Virtualization) on a freshly installed cluster in the correct dependency order.

**Prerequisites:**
- Running OCP cluster, all ClusterOperators healthy: `oc get co`
- `KUBECONFIG` set: `export KUBECONFIG=~/cluster_acp/install/auth/kubeconfig`
- Workload scheduling enabled on control nodes: `./hack/configure-converged-scheduling.sh`
- AWS credentials available: `~/.aws/credentials`
- ZeroSSL EAB credentials in `extra-vars.yml`

---

## 1. Run the preflight check

```bash
./hack/verify-post-install-prerequisites.sh \
  -i examples/ibm-cloud-active/inventory.yml
```

All 3 checks must pass before continuing.

## 2. Export credentials

```bash
export KUBECONFIG=~/cluster_acp/install/auth/kubeconfig
export AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id)
export AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key)
```

## 3. Run the pipeline

```bash
ansible-playbook playbooks/site-post-install.yml \
  -i examples/ibm-cloud-active/inventory.yml \
  -e @examples/ibm-cloud-active/extra-vars.yml
```

**Dependency order (enforced by `site-post-install.yml`):**

| # | Playbook | What it installs | Approx. time |
|---|---------|-----------------|-------------|
| 1 | `setup-openshift-storage.yml` | LSO + ODF (Ceph) | 20–25 min |
| 2 | `update-ocp-ingress-cert.yml` | cert-manager + ZeroSSL TLS | 10–15 min |
| 3 | `setup-openshift-pipelines.yml` | Tekton Pipelines | 5–10 min |
| 4 | `setup-ansible-automation-platform.yml` | AAP controller | 10–15 min |
| 5 | `setup-openshift-virtualization.yml` | KubeVirt (if enabled) | 5–10 min |

Total runtime: 50–75 minutes.

## 4. Skip cert-manager if ZeroSSL not yet configured

If you don't have ZeroSSL credentials yet, run without TLS:

```bash
ansible-playbook playbooks/site-post-install.yml \
  -i examples/ibm-cloud-active/inventory.yml \
  -e @examples/ibm-cloud-active/extra-vars.yml \
  -e skip_cert_manager=true
```

Run the TLS playbook separately once credentials are available:

```bash
ansible-playbook playbooks/update-ocp-ingress-cert.yml \
  -i examples/ibm-cloud-active/inventory.yml \
  -e @examples/ibm-cloud-active/extra-vars.yml
```

## 5. Run a single stage

Each playbook is idempotent and can be run independently:

```bash
# Storage only
ansible-playbook playbooks/setup-openshift-storage.yml \
  -i examples/ibm-cloud-active/inventory.yml \
  -e @examples/ibm-cloud-active/extra-vars.yml

# Pipelines only
ansible-playbook playbooks/setup-openshift-pipelines.yml \
  -i examples/ibm-cloud-active/inventory.yml \
  -e @examples/ibm-cloud-active/extra-vars.yml
```

## 6. Verify all services

```bash
# ODF
oc get storagecluster -n openshift-storage

# cert-manager
oc get csv -n cert-manager-operator

# Pipelines
oc get csv -n openshift-pipelines

# AAP
oc get AutomationController -n aap

# Virtualization (if enabled)
oc get hyperconverged -n openshift-cnv
```

---

**Expected outcome:** All five platform services are running and reporting healthy/available status.
