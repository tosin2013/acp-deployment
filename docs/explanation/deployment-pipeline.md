# Understanding the 13-step deployment pipeline

`hack/deploy-cluster.sh` orchestrates 13 steps to go from a bare IBM Cloud server to a fully operational ACP cluster. Each step exists for a specific reason, and the order is not arbitrary. This document explains the reasoning behind the sequence.

---

## Why there is a pipeline at all

Deploying OpenShift is a multi-hour process with dependencies between phases. Some of those dependencies are hard technical requirements (the installer validates MAC addresses at ISO generation time). Others are operational requirements (DNS must be correct before any node can bootstrap). Encoding the entire flow in a single script with explicit dependency checking prevents the most common class of deployment failures: running steps in the wrong order.

The pipeline is deliberately idempotent — each step checks its own preconditions and skips work that is already done. This means the script can be re-run after a failure at any point and will continue from where it stopped.

---

## The steps and their reasoning

### Steps 1–3: Environment setup

**Step 1 — populate cluster variables:** The `extra-vars.yml` template ships with empty `pull_secret` and `ssh_pub_key` fields. `setup-cluster-vars.sh` fills them in from the operator's local files before anything else runs. This is done first because every subsequent step needs these values.

**Step 2 — VyOS router:** VyOS is the first hard dependency. It creates the libvirt VLAN networks (`virbr-1924`, `virbr-1925`, `virbr-1926`) that all subsequent steps depend on. Without VLAN 1925, the cluster nodes have nowhere to boot into. This step also includes a manual operator action (VyOS Cockpit configuration) — placing it early ensures the operator completes this before the automated steps begin.

**Step 3 — topology selection:** Sets the `ibm-cloud-active` symlink to point to either `ibm-cloud-converged` or `ibm-cloud-sno`. This choice determines VM count, resource sizing, and whether ODF is deployed in subsequent steps. It is placed before any topology-specific configuration.

### Steps 4–5: External access setup

**Step 4 — HAProxy:** External users (and the Ansible control loop itself) reach the cluster through HAProxy running on the server's public IP. HAProxy forwards to internal VIPs. This is set up before DNS because DNS records point to the server's public IP — if HAProxy is not configured, DNS resolution will succeed but connections will fail.

**Step 5 — Route53 DNS:** Creates the A records that map `api.*` and `*.apps.*` to the server's public IP. DNS must exist before the installer runs because the Agent-Based Installer validates that `api-int.<cluster>.<domain>` resolves from inside the cluster network.

### Steps 6–8: The MAC-DNS-gate sequence

This three-step sequence is the most subtle part of the pipeline and the reason for a non-obvious ordering.

**Step 6 — MAC address pre-generation:** The Agent-Based Installer embeds per-node MAC addresses in the installer ISO. When `virt-install` creates a VM, it assigns a MAC address from libvirt — but this MAC must match the one in the ISO, or the node's network interface won't be configured correctly during installation. Generating MACs before ISO generation (step 9) means the VMs and the ISO are always in sync. Without this step, operators would need to generate the ISO, discover the MACs from `virsh domiflist`, and regenerate the ISO — a two-pass process that wastes 15–30 minutes.

**Step 7 — dnsmasq injection:** The cluster nodes resolve hostnames using the dnsmasq running on `virbr-1925`. This must be injected before ISO generation because the ISO contains the `dns_resolvers` from `extra-vars.yml`, which points to dnsmasq. The DNS records themselves must also be in dnsmasq before nodes boot — otherwise `api-int` resolution fails during cluster bootstrap.

**Step 8 — DNS verification gate:** This is a hard stop. If DNS does not resolve correctly — both internally (dnsmasq) and externally (Route53) — the installation will fail partway through and produce confusing error messages. The verification gate runs `verify-dns-resolution.sh` and refuses to proceed if any check fails. Catching DNS problems before the 60-minute installer run saves significant time.

### Steps 9–11: Cluster installation

**Step 9 — ISO generation:** Only now, with MACs pre-generated and DNS verified, does the installer ISO get created. The iso embeds the cluster topology, node configurations, MAC addresses, and DNS settings from `extra-vars.yml`.

**Step 10 — VM creation:** `deploy-kvm-vms.sh` creates the KVM VMs, passing the pre-generated MACs to `virt-install`. The VMs boot from the agent ISO immediately on creation.

**Step 11 — wait-for-install-complete:** The script starts `watch-and-reboot-kvm-vms.sh` in the background to handle VM reboots (the installer shuts VMs down instead of rebooting them). Then it runs `openshift-install agent wait-for install-complete`, which polls the cluster until all components are healthy. This is the longest step: 45–90 minutes.

### Steps 12–13: Post-install

**Step 12 — workload scheduling:** On a compact (converged) cluster, control-plane nodes must also run workloads. OpenShift's default is to taint all control nodes with `NoSchedule`. This step removes that taint. It must run *before* the post-install playbooks, because the platform operators (ODF, AAP, Pipelines) need to schedule pods on all three nodes.

**Step 13 — site-post-install.yml:** The final step deploys all platform services in dependency order. ODF is deployed first because AAP's database needs persistent storage. cert-manager is second because operator routes need trusted certificates. Pipelines, AAP, and Virtualization follow. See [Reference: Playbooks](../reference/playbooks.md) for the full dependency order.

---

## The helper-node model and why it matters for this pipeline

All 13 steps run from the IBM Cloud bare-metal server itself — the same machine that hosts the KVM hypervisor is also the Ansible helper and the HAProxy/dnsmasq server. This is the helper-node-centric model described in ADR-0003.

This co-location simplifies networking (the helper is on every network simultaneously) and eliminates one class of failure: VPN disconnects, laptop sleep, or workstation network changes that would interrupt a multi-hour deployment running on a local machine.

The trade-off is that a failure of the IBM Cloud server would destroy both the cluster VMs and the deployment tooling simultaneously. For a testbed this is acceptable; for production, the helper should be on separate physical hardware.

---

## Further reading

- [Tutorial: Deploy your first ACP cluster on IBM Cloud KVM](../tutorials/deploy-acp-on-ibm-cloud-kvm.md)
- [Reference: hack/ scripts](../reference/hack-scripts.md)
- [ADR-0002: Agent-Based OpenShift Installation via ISO](../adrs/adr-0002-agent-based-openshift-installation-via-iso.md)
- [ADR-0003: Helper-Node-Centric Deployment Model](../adrs/adr-0003-helper-node-centric-deployment-model.md)
- [ADR-0018: Mandatory DNS Verification Gate](../adrs/adr-0018-mandatory-dns-verification-gate.md)
