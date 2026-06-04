# Tutorial: Contribute a bare-metal example configuration

**What you will learn:** How to take a bare-metal ACP deployment that you have working on your own hardware, package it as a reusable example, sanitise it, and open a pull request that lets the next person with your hardware get started in minutes instead of days.

**Time:** 1–2 hours of active work (assumes your hardware is already deployed).

**Skill built:** How the `examples/` directory is structured, how to document hardware-specific configuration, and how the contribution review process works.

---

## Before you start

You need:

- A working ACP deployment on physical servers (at least one successful `openshift-install agent wait-for install-complete`)
- Your `extra-vars.yml` and `nodes.yml` from the working deployment
- A GitHub account with a fork of `https://github.com/tosin2013/acp-deployment`
- Git installed on your helper node

You do **not** need:
- A perfect deployment — partial or SNO deployments are still useful
- All post-install services working — a base cluster is enough to contribute

> **Why this matters:** Every bare-metal site uses different hardware. The Dell R750 behaves differently from the HPE DL380, which behaves differently from the Supermicro X12. The only way to cover this diversity is for operators who have working deployments to contribute their configurations.

---

## Step 1 — Identify your topology

ACP supports two bare-metal topologies. Choose the one that matches what you deployed:

| Topology | Servers | Example directory | Use when |
|----------|---------|-------------------|---------|
| Converged (3-node compact HA) | 3 physical servers | `examples/bare-metal-converged/` | Full ACP with ODF storage |
| SNO (Single-Node OpenShift) | 1 physical server | `examples/bare-metal-sno/` | Minimal edge, no ODF |

If your hardware requires substantially different configuration from the existing examples — different NIC bonding, different BMC vendor, unusual disk layout — you will create a new example directory in Step 2.

---

## Step 2 — Set up your working copy

Fork and clone the repository on your helper node:

```bash
# Fork on GitHub first, then:
git clone https://github.com/<YOUR_GITHUB_USERNAME>/acp-deployment.git
cd acp-deployment
git checkout -b bare-metal/<hardware-short-description>
# e.g. git checkout -b bare-metal/dell-r750-converged
```

---

## Step 3 — Create or copy your example directory

### If your hardware fits an existing topology without major changes

Work directly in the existing template:

```bash
cp examples/bare-metal-converged/extra-vars.yml examples/bare-metal-converged/extra-vars.yml.bak
cp examples/bare-metal-sno/extra-vars.yml       examples/bare-metal-sno/extra-vars.yml.bak
```

### If your hardware needs a new example directory

Create a named directory that describes the hardware:

```bash
# Convention: bare-metal-<vendor>-<model>[-<topology>]
mkdir -p examples/bare-metal-dell-r750-converged
mkdir -p examples/bare-metal-hpe-dl380-sno

# Copy the closest existing example as a starting point
cp examples/bare-metal-converged/{extra-vars.yml,inventory.yml,nodes.yml} \
   examples/bare-metal-dell-r750-converged/
```

Good directory name examples:
- `bare-metal-dell-r750-converged` — Dell PowerEdge R750, 3-node
- `bare-metal-hpe-dl380-sno` — HPE ProLiant DL380, single-node
- `bare-metal-supermicro-x12-converged` — Supermicro X12, 3-node
- `bare-metal-lenovo-sr650-converged` — Lenovo ThinkSystem SR650

---

## Step 4 — Copy your working configuration in

Copy the files you used for your successful deployment into the example directory:

```bash
cp /path/to/your/working/extra-vars.yml examples/bare-metal-dell-r750-converged/
cp /path/to/your/working/nodes.yml       examples/bare-metal-dell-r750-converged/
cp /path/to/your/working/inventory.yml   examples/bare-metal-dell-r750-converged/
```

---

## Step 5 — Sanitise all credentials

**This is the most important step.** Real credentials must never appear in a pull request.

Open `extra-vars.yml` and replace every real value with a `<REPLACE_ME_*>` placeholder:

```bash
# What to sanitise:
#   - pull_secret       → leave as empty string ''
#   - ssh_pub_key       → leave as empty string ''
#   - zerossl_account.email / kid / key  → leave as empty strings
#   - IP addresses (node IPs, VIPs, gateway, helper IP)  → <REPLACE_ME_*>
#   - MAC addresses     → <REPLACE_ME_C0_BOND0_MAC> etc.
#   - base_domain       → <REPLACE_ME_BASE_DOMAIN>
#   - aws credentials   → remove or replace with <REPLACE_ME_*>
```

Example of correct sanitisation:

```yaml
openshift:
  cluster_name: acp
  base_domain: <REPLACE_ME_BASE_DOMAIN>       # e.g. edge.example.com
  pull_secret: ''                              # populate from ~/pull-secret.json
  ssh_pub_key: ''                              # paste your SSH public key

  api_address: <REPLACE_ME_API_VIP>           # floating VIP on cluster network
  ingress_address: <REPLACE_ME_INGRESS_VIP>   # floating VIP for *.apps

  control_nodes:
    - name: control-0
      networking:
        interfaces:
          - name: bond0
            mac_address: <REPLACE_ME_C0_BOND0_MAC>   # from BIOS/BMC NIC properties
            ipv4:
              address:
                - ip: <REPLACE_ME_CONTROL_0_IP>
                  prefix_length: 24
```

Open `nodes.yml` and sanitise BMC credentials and addresses:

```yaml
nodes:
  - name: control-0
    bmc:
      address: https://<REPLACE_ME_BMC_0_IP>   # BMC management IP (iDRAC/iLO/MegaRAC)
      username: root                            # or your BMC user
      # password: set via BAREMETAL_BMC_PASSWORD environment variable
    boot_iso_url: http://<REPLACE_ME_HELPER_IP>:8080/agent.x86_64.iso
    mac_address: <REPLACE_ME_C0_BOND0_MAC>
```

Verify no real values remain:

```bash
# These should return nothing after sanitisation:
grep -E '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' examples/bare-metal-dell-r750-converged/extra-vars.yml
grep -E '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' examples/bare-metal-dell-r750-converged/extra-vars.yml
grep -iE 'password|secret|key.*:.*[a-zA-Z0-9+/]{20}' examples/bare-metal-dell-r750-converged/extra-vars.yml
```

---

## Step 6 — Write the hardware comment block

Add a comment block at the very top of `extra-vars.yml` that describes your hardware precisely. This is what allows the next person with the same hardware to find your example and trust that it applies to them.

```yaml
---
# Bare-Metal Converged (3-node compact) — Dell PowerEdge R750
# ============================================================
# Validated: ACP v4.21.0, June 2026
#
# Hardware reference configuration (per node):
#   Vendor  : Dell PowerEdge R750
#   CPU     : 2× Intel Xeon Gold 6330 (28 cores / 56 threads)
#   RAM     : 256 GB DDR4 ECC
#   OS disk : 1× NVMe 960 GB (installation_device: /dev/nvme0n1)
#   ODF disk: 2× NVMe 3.84 TB (odf_device_count: 2)
#   NIC     : 4× 25 GbE Mellanox ConnectX-5 (bond0: p1p1+p1p2, bond1: p2p1+p2p2)
#   BMC     : iDRAC 9 v6.10+
#   Switch  : Cisco Nexus 93180YC-FX, LACP port-channel (mode active)
#
# Redfish virtual media path (Dell iDRAC 9):
#   /redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD
#
# Known quirks:
#   - iDRAC 9 v5.x has a Redfish session timeout bug; upgrade to v6.10+
#   - LACP requires 'channel-group X mode active' on Nexus; 'passive' won't bond
#   - NVMe ordering may shift after BIOS update; use /dev/disk/by-path/ for stability
```

Key fields in the comment block:

| Field | Why it matters |
|-------|---------------|
| Vendor + model | Lets others search for their exact hardware |
| CPU | Affects scheduling and CPU-pinning decisions |
| RAM | Determines whether all platform services fit |
| OS disk device path | Must match `installation_device:` in `extra-vars.yml` |
| ODF disk count + size | Drives the `odf_device_count` variable and usable capacity |
| NIC names + bonding | The nmstate config must use these exact interface names |
| BMC vendor + version | Determines which Redfish path applies |
| Switch vendor + LACP mode | LACP interoperability varies by switch vendor |
| Known quirks | Critical — document any non-obvious workarounds you discovered |

---

## Step 7 — Verify the example builds cleanly

Run the preflight check to confirm the configuration is self-consistent before opening a PR:

```bash
./hack/verify-odf-prerequisites.sh \
  -e examples/bare-metal-dell-r750-converged/extra-vars.yml

# Expected: all checks PASS (even with placeholder values,
# the structural checks should pass)
```

If your example includes post-install configuration:

```bash
./hack/verify-post-install-prerequisites.sh \
  -i examples/bare-metal-dell-r750-converged/inventory.yml
```

---

## Step 8 — Open the pull request

Commit your example and push to your fork:

```bash
git add examples/bare-metal-dell-r750-converged/
git commit -m "feat(examples): add bare-metal-dell-r750-converged example

Hardware: Dell PowerEdge R750, 3-node converged
Validated: ACP v4.21.0, June 2026
Topology: Converged (3-node compact HA) with ODF, 2× 3.84 TB NVMe per node
BMC: iDRAC 9 v6.10+
NIC: Mellanox ConnectX-5 25 GbE, bond0/bond1 (LACP)"

git push origin bare-metal/dell-r750-converged
```

Open a pull request on GitHub. Use this PR description template:

```
## Bare-metal example: Dell PowerEdge R750 (3-node converged)

### Hardware
- Vendor: Dell PowerEdge R750
- CPU: 2× Intel Xeon Gold 6330
- RAM: 256 GB
- ODF disks: 2× NVMe 3.84 TB per node
- NIC: Mellanox ConnectX-5 25 GbE
- BMC: iDRAC 9 v6.10

### Validated against
- ACP v4.21.0
- OCP 4.21.x
- ODF (Ceph) storage: yes
- Post-install services: AAP, Pipelines [list what you tested]

### Checklist
- [x] Credentials sanitised (no IPs, MACs, pull secrets, SSH keys)
- [x] Hardware comment block at top of extra-vars.yml
- [x] Deployment tested end-to-end (not just config generated)
- [x] Known quirks documented in comments
- [ ] Post-install pipeline tested (if applicable)
```

---

## What reviewers check

When a maintainer reviews your PR, they will verify:

1. No real credentials in any file (`grep` for IP addresses, MACs, secrets)
2. Hardware comment block is present and complete
3. `REPLACE_ME` placeholders are used consistently
4. The Redfish path in `nodes.yml` comments matches the BMC vendor documented in `extra-vars.yml`
5. `installation_device` matches the OS disk described in the comment block
6. `odf_device_count` is consistent with the disk count in the comment block

---

## What you have learned

By completing this tutorial you have:

- Understood how the `examples/` directory maps to hardware topology
- Learned the `<REPLACE_ME_*>` placeholder convention that makes examples reusable
- Written a hardware comment block that future users will rely on
- Opened a PR that makes ACP deployment faster for everyone with your hardware

The next step is the reference documentation:
- [Bare-metal hardware reference](../reference/bare-metal-hardware.md) — Redfish paths, NIC naming, and known BMC quirks for all supported vendors
- [Bare-metal hardware sizing](../reference/bare-metal-sizing.md) — CPU, RAM, disk, and network sizing targets
