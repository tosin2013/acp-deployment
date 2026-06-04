# Reference: Ansible Playbooks

All playbooks live in `playbooks/`. They target the `helper` host defined in the inventory.

---

## playbooks/create-installation-media.yml

**Purpose:** Download OpenShift tooling and generate the Agent-Based Installer ISO.

**Inputs:**
- `openshift.version` — OCP release (`stable` or pinned, e.g. `4.21.18`)
- `openshift.cluster_name`, `openshift.base_domain`
- `openshift.pull_secret`, `openshift.ssh_pub_key`
- `openshift.control_nodes[]` — per-node networking, MAC addresses, installation device
- `openshift.api_address`, `openshift.ingress_address`

**Outputs:**
- `~/cluster_<name>/install/openshift-install` — installer binary
- `~/cluster_<name>/install/oc` — oc CLI binary
- `~/cluster_<name>/install/agent.x86_64.iso` — bootable installer ISO
- `/var/www/html/agent.x86_64.iso` — copy served over HTTP

**Templates used:**
- `playbooks/templates/install-config.yaml.j2` — cluster topology and pull secret
- `playbooks/templates/agent-config.yaml.j2` — per-node nmstate configuration

**Idempotency:** The ISO is only regenerated if it does not already exist (`creates:` condition).

---

## playbooks/site-post-install.yml

**Purpose:** Master orchestrator that imports all post-install playbooks in dependency order.

**Playbook order:**

| Order | Playbook |
|-------|---------|
| 1 | `setup-openshift-storage.yml` |
| 2 | `update-ocp-ingress-cert.yml` (skippable with `-e skip_cert_manager=true`) |
| 3 | `setup-openshift-pipelines.yml` |
| 4 | `setup-ansible-automation-platform.yml` |
| 5 | `setup-openshift-virtualization.yml` (conditional on `install_openshift_virtualization`) |

**Special variable:** `-e skip_cert_manager=true` causes step 2 to be bypassed.

---

## playbooks/setup-openshift-storage.yml

**Purpose:** Deploy Local Storage Operator (LSO) and OpenShift Data Foundation (ODF).

**Inputs:**
- `openshift.all_node_settings.odf_use_multus` — `false` for KVM, `true` for bare-metal
- `openshift.all_node_settings.odf_device_count` — total number of ODF block devices
- `openshift.all_node_settings.storage_interface` — NIC/bond for Multus (bare-metal only)
- `openshift.all_node_settings.storage_network` — CIDR for ODF storage network (bare-metal only)

**Roles invoked (in order):**
1. `roles/openshift_local_storage` — LSO operator + `LocalVolumeSet` CR
2. `roles/openshift_data_foundation` — ODF operator + `StorageSystem` + `StorageCluster` CRs

**Pre-tasks:** Checks `systemd-detect-virt`; fails if KVM detected and `odf_use_multus: true`.

**Storage classes created:**
- `ocs-storagecluster-ceph-rbd` (block, RWO)
- `ocs-storagecluster-cephfs` (file, RWO/RWX)
- `openshift-storage.noobaa.io` (object/S3)

**Idempotency:** All `redhat.openshift.k8s` calls are idempotent.

---

## playbooks/update-ocp-ingress-cert.yml

**Purpose:** Install cert-manager and issue ZeroSSL TLS certificates for ingress and API.

**Inputs:**
- `workshop_dns_zone` — Route53 hosted zone name
- `aws_region` — Route53 region
- `zerossl_account.email`, `zerossl_account.kid`, `zerossl_account.key`
- `acme.solvers` — list of DNS-01 solvers (`[route53]`)
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` environment variables

**Role invoked:** `roles/update_ocp_ingress_cert`

**Tasks (in order within the role):**
1. `cert-manager-operator.yml` — Namespace, OperatorGroup, Subscription, wait CSV
2. `pre-flight.yml` — Verify prerequisites
3. Main tasks — `CertManager`, `ClusterIssuer`, `Certificate` CRs for ingress + API
4. `update-ingress-cert.yml` — Patch `IngressController`
5. `update-api-cert.yml` — Patch `APIServer`

**Handler:** `Update KUBECONFIG` — removes `certificate-authority-data` from kubeconfig after API cert rotation.

**Skip condition:** If `skip_cert_manager` is defined and truthy, the entire playbook exits immediately.

---

## playbooks/setup-openshift-pipelines.yml

**Purpose:** Install the OpenShift Pipelines (Tekton) operator.

**Roles invoked:** Inline tasks (no separate role).

**Resources created:**
- `Namespace: openshift-pipelines`
- `OperatorGroup: openshift-pipelines`
- `Subscription: openshift-pipelines-operator-rh` on channel `latest`

**Verification:** Waits for the Pipelines CSV to reach `Succeeded`.

---

## playbooks/setup-ansible-automation-platform.yml

**Purpose:** Install Ansible Automation Platform (AAP) operator and create an `AutomationController` instance.

**Inputs:**
- `openshift.cluster_name`, `openshift.base_domain` — used to construct the AAP route URL

**Roles invoked:** `roles/ansible_automation_platform`

**Resources created:**
- `Namespace: aap`
- `OperatorGroup: aap`
- `Subscription: ansible-automation-platform-operator` on channel `stable-2.6-cluster-scoped`
- `AutomationController: aap-controller` (single-replica, basic install)

**Dependency:** Requires ODF storage classes to be present (AAP PostgreSQL uses PVCs).

---

## playbooks/setup-openshift-virtualization.yml

**Purpose:** Install OpenShift Virtualization (KubeVirt) operator.

**Conditional execution:** Skipped unless `install_openshift_virtualization: true` in `extra-vars.yml`.

**Roles invoked:** `roles/openshift_virtualization`

**Resources created:**
- `Namespace: openshift-cnv`
- `OperatorGroup: openshift-cnv`
- `Subscription: kubevirt-hyperconverged` on channel `stable`
- `HyperConverged: kubevirt-hyperconverged` CR

**Requirements:** Nested virtualisation enabled on the KVM host (`kvm_intel`/`kvm_amd` nested=1). 48 GiB RAM per node minimum.

---

## playbooks/dns.yml

**Purpose:** Create and manage the BIND-in-Podman DNS container on the helper node.

**When used:** Only when `external_dns: false` (bare-metal path). On IBM Cloud KVM, Route53 + dnsmasq are used instead.

**Inputs:** `dns.*` block from `extra-vars.yml`.

**Resources:** Runs a Podman container from `playbooks/files/bind-Containerfile` with zone files generated from `playbooks/templates/bind-*.j2` templates.

---

## Ansible collections required

Defined in `playbooks/collections/requirements.yml`.

| Collection | Used for |
|-----------|---------|
| `redhat.openshift` | Kubernetes CR and OLM management (`redhat.openshift.k8s`) |
| `kubernetes.core` | Pod/resource status polling (`kubernetes.core.k8s_info`) |
| `containers.podman` | DNS container lifecycle |
| `amazon.aws` | Route53 DNS record management |

Install with:
```bash
ansible-galaxy collection install -r playbooks/collections/requirements.yml
```
