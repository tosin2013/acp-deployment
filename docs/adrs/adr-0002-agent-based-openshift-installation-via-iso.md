# ADR-0002: Agent-Based OpenShift Installation via ISO

## Date
2026-06-03

## Status
Accepted

## Context

Installing OpenShift on bare-metal hardware without cloud provider integration requires choosing between several install strategies. The ACP testbed targets commodity servers in lab or industrial environments with these characteristics:

- No guaranteed BMC (IPMI/Redfish) access for out-of-band power control.
- No existing PXE/DHCP infrastructure assumed.
- Static IP addressing is required for all cluster nodes.
- Operator simplicity is critical — the installation workflow must be executable by a single operator following documented steps.
- The project targets OpenShift 4.13, which introduced agent-based installer GA support.

Traditional approaches impose significant infrastructure prerequisites: IPI requires a temporary bootstrap VM and BMC access for bare-metal provisioning; UPI requires manual PXE server setup, ignition file hosting, and load balancer configuration — all before the first node boots.

## Decision

The agent-based OpenShift installer is used to generate a bootable `agent.x86_64.iso`. This ISO embeds the cluster topology, per-node network configuration (via nmstate), and installation logic, eliminating the need for a separate bootstrap node.

The workflow implemented in `playbooks/create-installation-media.yml`:
1. Downloads `openshift-install` and `oc` binaries from `mirror.openshift.com` to the helper node.
2. Templates `install-config.yaml` (cluster topology, networking, pull secret) from Ansible variables using `playbooks/templates/install-config.yaml.j2`.
3. Templates `agent-config.yaml` (per-node static IP, MAC address, nmstate interface config) from Ansible variables using `playbooks/templates/agent-config.yaml.j2`.
4. Runs `openshift-install agent create image` to produce `agent.x86_64.iso`.
5. Copies the ISO to `/var/www/html/` on the helper for HTTP-based retrieval or USB writing.

After ISO generation, nodes are manually booted from the ISO (written to USB or PXE-served). This is the only manual step in the deployment workflow.

## Consequences

**Positive:**
- Eliminates the bootstrap node requirement, reducing bare-metal hardware footprint.
- Per-node static IP and interface bonding configuration is embedded in the ISO via nmstate, removing the need for DHCP in the cluster network.
- Single Ansible playbook generates all installation artifacts from a single set of variables.
- ISO can be distributed via USB or served over HTTP from the helper, accommodating various lab setups.
- Agent-based installer supports both HA (3-node, platform `baremetal`) and non-HA (SNO, platform `none`) modes from the same tooling.

**Negative:**
- Node booting from the ISO remains a manual step; full end-to-end automation of the physical boot process requires BMC/IPMI integration (out of scope).
- Any configuration change (IP, interface, cluster topology) before nodes are booted requires ISO regeneration and re-imaging media.
- Disconnected/air-gapped installation via `oc-mirror` is explicitly deferred as a TODO item and not currently supported.
- The generated ISO is architecture-specific (`x86_64`); supporting other architectures requires additional consideration.

## Alternatives Considered

- **IPI (Installer-Provisioned Infrastructure)** — Fully automated end-to-end, including node provisioning, but requires a temporary bootstrap VM, BMC/IPMI access for bare-metal power control, and a Metal3/Ironic integration. These prerequisites are not available in all ACP testbed environments.
- **UPI (User-Provisioned Infrastructure)** — Maximum control and flexibility but requires manually setting up PXE servers, hosting ignition files, configuring load balancers, and registering nodes with the bootstrap process. The operational complexity is significantly higher.
- **Red Hat Assisted Installer (SaaS/on-prem)** — Provides a guided web UI and simpler UX, but requires connectivity to `console.redhat.com` (or deploying the Assisted Installer service locally). Not suitable for air-gapped or network-isolated lab environments.
- **OpenShift Hive** — Operator-driven cluster lifecycle management with CRD-based cluster provisioning, but requires an existing management cluster and adds significant operational complexity for an initial testbed deployment.


---

## Validated in Production

v4.21.0 — 2026-06-04 — IBM Cloud KVM (3-node compact), OCP 4.21.8, acp-deployment v4.21.0. All role assumptions confirmed against a fully deployed cluster.
