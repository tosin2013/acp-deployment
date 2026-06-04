# Tutorial: Deploy your first ACP cluster on IBM Cloud KVM

**Type:** Tutorial (learning-oriented)
**Audience:** Engineers who have an IBM Cloud bare-metal server and want to understand how ACP deployment works by doing it.
**Goal:** By the end of this tutorial you will have a 3-node OpenShift cluster running on KVM VMs, accessible via a public URL with a trusted TLS certificate.
**Time:** 3–4 hours (most of it unattended installation time).

> This tutorial walks you through every step. You will make mistakes — that is normal. Each step includes a verification so you know it worked before moving on.
>
> When you finish, see [Understanding the deployment pipeline](../explanation/deployment-pipeline.md) to learn *why* each step exists.

---

## What you need before you start

- An IBM Cloud bare-metal server running CentOS Stream 10 or RHEL 9
- Root or sudo access to that server
- A Red Hat pull secret (download free from [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret))
- A domain hosted in AWS Route53 (e.g., `example.com`) — you control the hosted zone
- A ZeroSSL account (free at [zerossl.com](https://zerossl.com)) with EAB credentials
- AWS IAM credentials with Route53 write access (`~/.aws/credentials`)

---

## Part 1: Prepare the server

### Step 1: Clone the repository

Log in to your IBM Cloud bare-metal server and run:

```bash
git clone https://github.com/tosin2013/acp-deployment.git
cd acp-deployment
```

### Step 2: Install KVM and required tools

```bash
sudo ./hack/bootstrap.sh
sudo ./hack/install-kvm-host.sh
```

`install-kvm-host.sh` installs `qemu-kvm`, `libvirt`, `virt-install`, and configures a KVM storage pool on `/dev/vdb` (your secondary disk). It also enables nested virtualisation, which is required if you want to run VM workloads later.

**Verify:** After it completes, run:

```bash
sudo systemctl is-active libvirtd
```

You should see `active`.

### Step 3: Set your cluster environment variables

```bash
vi hack/env.sh
```

Fill in these four values:

```bash
export CLUSTER_NAME="acp"                          # short name, no dots
export BASE_DOMAIN="example.com"                   # your Route53 domain
export EXTERNAL_IP="1.2.3.4"                       # your server's public IP
export HOSTED_ZONE_ID="Z0123456789ABCDEF"          # Route53 hosted zone ID
```

Load the values into your shell:

```bash
source hack/env.sh
```

**Verify:** You should see `[INFO] ACP environment loaded: acp.example.com (1.2.3.4)`.

---

## Part 2: Configure cluster variables

### Step 4: Download your pull secret

```bash
# Download your pull secret from https://console.redhat.com/openshift/install/pull-secret
# Save it as ~/pull-secret.json
ls -la ~/pull-secret.json
```

**Verify:** The file exists and starts with `{"auths":`.

### Step 5: Select the HA (3-node) topology

```bash
./hack/select-cluster-topology.sh
```

This creates a symlink `examples/ibm-cloud-active → examples/ibm-cloud-converged`. You will use this path for all playbooks throughout the tutorial.

**Verify:**

```bash
readlink -f examples/ibm-cloud-active
```

Should print a path ending in `ibm-cloud-converged`.

### Step 6: Populate SSH key and pull secret into extra-vars.yml

```bash
./hack/setup-cluster-vars.sh
```

This reads your SSH public key (`~/.ssh/id_rsa.pub`) and pull secret, and writes them into `examples/ibm-cloud-converged/extra-vars.yml`.

### Step 7: Set your ZeroSSL and DNS variables

Open `examples/ibm-cloud-converged/extra-vars.yml` and fill in the `zerossl_account` section at the bottom:

```bash
vi examples/ibm-cloud-converged/extra-vars.yml
```

```yaml
workshop_dns_zone: example.com        # same as BASE_DOMAIN
aws_region: us-east-1

zerossl_account:
  email: "you@example.com"
  kid: "YOUR_EAB_KEY_ID"              # from app.zerossl.com/developer
  key: "YOUR_EAB_HMAC_KEY"
```

---

## Part 3: Create the network infrastructure

### Step 8: Create the VyOS virtual router

```bash
ACTION=create ./hack/vyos-router.sh
```

This creates three VLAN networks (`virbr-1924`, `virbr-1925`, `virbr-1926`) and a VyOS router VM that routes between them and the internet.

**Verify:**

```bash
virsh list --all | grep vyos
```

You should see `vyos-router` in the list.

### Step 9: Configure the VyOS router (manual step, ~10 minutes)

Open Cockpit in your browser: `https://YOUR_SERVER_IP:9090`

Navigate to **Virtual Machines → vyos-router → Console**.

Follow the interactive steps in [`docs/vyos-setup.md`](../vyos-setup.md) to configure routing on the VyOS VM.

> This is the only manual step in the entire deployment. VyOS is the internal gateway for the cluster VMs.

**Verify:** From the VyOS console, run `show interfaces`. You should see `eth0` through `eth3` with IP addresses assigned.

### Step 10: Configure HAProxy for external access

```bash
sudo -E ./hack/configure-haproxy-forwarder.sh
```

HAProxy listens on the server's public IP and forwards port 6443 (API) and 443/80 (ingress) to the cluster VIPs inside the VyOS network.

**Verify:**

```bash
sudo systemctl is-active haproxy
```

### Step 11: Create Route53 DNS records

```bash
./hack/configure-route53-dns.sh add
```

This creates `api.acp.example.com`, `*.apps.acp.example.com`, and related records pointing to your server's public IP.

**Verify:**

```bash
./hack/verify-dns-resolution.sh
```

All checks must pass (green). If any fail, re-run step 10 or 11 before continuing — the installer will refuse to proceed without valid DNS.

---

## Part 4: Create the cluster

### Step 12: Pre-generate VM MAC addresses

```bash
./hack/generate-kvm-macs.sh examples/ibm-cloud-converged/extra-vars.yml
```

MAC addresses are embedded in the installer ISO at generation time. Generating them now means you avoid regenerating the ISO after creating VMs.

**Verify:** Open `examples/ibm-cloud-converged/extra-vars.yml` and confirm all `mac_address:` fields now have values (e.g., `52:54:00:xx:xx:xx`).

### Step 13: Inject DNS into the KVM internal network

```bash
sudo -E ./hack/setup-dnsmasq.sh
```

This injects cluster DNS entries into the libvirt dnsmasq on the `virbr-1925` interface so that OCP nodes can resolve `api-int` and each other's hostnames.

### Step 14: Generate the installer ISO

```bash
ansible-playbook playbooks/create-installation-media.yml \
  -i examples/ibm-cloud-active/inventory.yml \
  -e @examples/ibm-cloud-active/extra-vars.yml
```

This downloads `openshift-install` and `oc`, templates `install-config.yaml` and `agent-config.yaml`, and runs `openshift-install agent create image`.

**Verify:**

```bash
ls ~/cluster_acp/install/agent.x86_64.iso
```

The file should be ~1.2 GB.

### Step 15: Create the KVM virtual machines

```bash
./hack/deploy-kvm-vms.sh
```

This creates three VMs (`control-0`, `control-1`, `control-2`) each with 48 GiB RAM, 16 vCPUs, and 3 virtual disks (OS + 2 ODF disks). The VMs are booted from the installer ISO.

**Verify:**

```bash
virsh list --all
```

You should see `control-0`, `control-1`, and `control-2` in the `running` state.

### Step 16: Watch the installation

Start the VM reboot watcher in the background (it reboots VMs into the installed OS when the installer shuts them down):

```bash
./hack/watch-and-reboot-kvm-vms.sh \
  --config examples/ibm-cloud-converged/extra-vars.yml \
  --timeout 7200 &
```

Then wait for installation to complete:

```bash
export KUBECONFIG=~/cluster_acp/install/auth/kubeconfig
openshift-install agent wait-for install-complete \
  --dir ~/cluster_acp/install --log-level=info
```

Installation takes **45–90 minutes**. You will see progress messages as each node boots, installs RHCOS, and joins the cluster.

**Verify:** When complete, you see `INFO Install complete!`. Then run:

```bash
oc get nodes
```

All three nodes should be in `Ready` status.

---

## Part 5: Post-install configuration

### Step 17: Enable workload scheduling on control nodes

```bash
./hack/configure-converged-scheduling.sh
```

In a compact cluster, control nodes also run workloads. This removes the default `NoSchedule` taint so that platform operators can schedule pods.

**Verify:**

```bash
oc describe nodes | grep -A5 Taints
```

The `node-role.kubernetes.io/master:NoSchedule` taint should be gone.

### Step 18: Run the post-install services pipeline

```bash
export AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id)
export AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key)

ansible-playbook playbooks/site-post-install.yml \
  -i examples/ibm-cloud-active/inventory.yml \
  -e @examples/ibm-cloud-active/extra-vars.yml
```

This runs five playbooks in order:
1. ODF storage (Ceph + NooBaa)
2. ZeroSSL TLS (cert-manager)
3. OpenShift Pipelines (Tekton)
4. Ansible Automation Platform
5. OpenShift Virtualization (if `install_openshift_virtualization: true`)

Each takes 5–20 minutes. Total time: 45–60 minutes.

---

## Verification: Is your cluster healthy?

```bash
# All nodes Ready
oc get nodes

# All cluster operators healthy (no DEGRADED = True)
oc get co | grep -v "True.*False.*False"

# ODF storage healthy
oc get storagecluster -n openshift-storage

# TLS cert is valid
curl -s https://api.acp.example.com:6443/version
```

Open your browser to:
`https://console-openshift-console.apps.acp.example.com`

Log in with username `kubeadmin` and the password from:
```bash
cat ~/cluster_acp/install/auth/kubeadmin-password
```

You should see the OpenShift console with a valid TLS certificate (no browser warning).

---

## What you built

Congratulations. You have deployed:

- A 3-node compact OpenShift 4.21 cluster on KVM VMs
- ODF persistent storage (Ceph block, file, and object storage)
- Trusted TLS certificates from ZeroSSL on all ingress routes and the API
- OpenShift Pipelines, Ansible Automation Platform, and OpenShift Virtualization

---

## Next steps

- [Tutorial: Explore ODF persistent storage](./explore-odf-storage.md)
- [How to configure TLS certificates](../how-to/configure-zerossl-tls.md)
- [Understanding the deployment pipeline](../explanation/deployment-pipeline.md)
- [Understanding why Ansible](../explanation/why-ansible.md)
