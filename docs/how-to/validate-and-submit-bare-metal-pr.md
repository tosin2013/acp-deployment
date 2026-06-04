# How to validate and submit a bare-metal example PR

**Goal:** Verify that your bare-metal example configuration is clean and complete, then submit it as a pull request.

**Assumes:** You have a working `extra-vars.yml`, `nodes.yml`, and `inventory.yml` in your example directory. If you are documenting your hardware for the first time, follow the [contribute a bare-metal example tutorial](../tutorials/contribute-bare-metal-example.md) first.

---

## 1. Run the credential scan

No real values should appear in your example files. Run this scan before opening a PR:

```bash
cd acp-deployment

# IPs (should return nothing)
grep -rE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' \
  examples/bare-metal-<your-example>/

# MAC addresses (should return nothing)
grep -rE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' \
  examples/bare-metal-<your-example>/

# Pull secrets and keys (should return nothing)
grep -riE 'eyJ|BEGIN (RSA|EC|PRIVATE)|AKIA|password:.*[a-zA-Z0-9]{12,}' \
  examples/bare-metal-<your-example>/
```

All three commands must return **no output**. If any real value appears, replace it with a `<REPLACE_ME_*>` placeholder.

---

## 2. Verify required placeholder coverage

Check that all site-specific fields use `<REPLACE_ME_*>` placeholders:

```bash
# These should ALL appear in your extra-vars.yml:
grep -c 'REPLACE_ME' examples/bare-metal-<your-example>/extra-vars.yml
# Expected: at least 15 (IPs, MACs, domain, VIPs, storage CIDR, etc.)

grep -c 'REPLACE_ME' examples/bare-metal-<your-example>/nodes.yml
# Expected: at least 3 per node (BMC IP, helper IP, MAC)
```

---

## 3. Verify the hardware comment block is present

```bash
head -30 examples/bare-metal-<your-example>/extra-vars.yml
```

The comment block must include:
- `Vendor` and model
- `CPU` spec (count, model, core count)
- `RAM` spec
- `OS disk` device path
- `ODF disk` count and capacity (or `N/A` for SNO)
- `NIC` vendor, speed, and bond assignments
- `BMC` vendor and firmware version
- `Switch` vendor and LACP mode
- `Known quirks` (if any — write `None` if truly none)

---

## 4. Run the preflight checks

```bash
# ODF prerequisites (for converged topology with ODF)
./hack/verify-odf-prerequisites.sh \
  -e examples/bare-metal-<your-example>/extra-vars.yml

# Post-install prerequisites (if your example includes post-install services)
./hack/verify-post-install-prerequisites.sh \
  -i examples/bare-metal-<your-example>/inventory.yml
```

Expected output: all checks report `PASS`. Structural checks (YAML validity, required key presence) will pass even with `<REPLACE_ME_*>` placeholder values. Connectivity checks will skip or report `SKIP` when placeholder values are present.

---

## 5. Verify YAML is valid

```bash
python3 -c "
import yaml, sys
for f in ['extra-vars.yml', 'nodes.yml', 'inventory.yml']:
    try:
        yaml.safe_load(open('examples/bare-metal-<your-example>/' + f))
        print(f'OK: {f}')
    except yaml.YAMLError as e:
        print(f'ERROR: {f}: {e}')
        sys.exit(1)
"
```

All three files must parse without error.

---

## 6. Commit with a descriptive message

```bash
git add examples/bare-metal-<your-example>/
git commit -m "feat(examples): add bare-metal-<vendor>-<model> example

Hardware: <Vendor> <Model>, <node-count>-node <topology>
Validated: ACP v4.21.0
Topology: <Converged|SNO> with <ODF details or 'no ODF'>
BMC: <BMC vendor and version>
NIC: <NIC vendor and speed>"
```

---

## 7. Open the pull request

Push your branch and open a PR on GitHub. Use this description template:

```markdown
## Bare-metal example: <Vendor> <Model> (<topology>)

### Hardware
- **Vendor/model:** <e.g. Dell PowerEdge R750>
- **CPU:** <e.g. 2× Xeon Gold 6330, 28 cores>
- **RAM:** <e.g. 256 GB>
- **ODF disks:** <e.g. 2× NVMe 3.84 TB per node, or N/A>
- **NIC:** <e.g. Mellanox ConnectX-5, 4× 25 GbE>
- **BMC:** <e.g. iDRAC 9 v6.10>
- **Switch:** <e.g. Cisco Nexus 93180YC-FX>

### Validated against
- ACP version: v4.21.0
- OCP version: 4.21.x
- ODF deployed: yes / no
- Post-install services tested: <list or "none">

### Validation checklist
- [ ] Credential scan clean (no IPs, MACs, secrets)
- [ ] Hardware comment block present in extra-vars.yml
- [ ] All REPLACE_ME placeholders used consistently
- [ ] YAML parses without error
- [ ] Deployment tested end-to-end on real hardware
- [ ] Known quirks documented in comments
```

---

## What reviewers check

Maintainers will verify the following before merging:

| Check | What they look for |
|-------|-------------------|
| Credential scan | No real IPs, MACs, pull secrets, or SSH keys |
| Hardware comment block | Vendor, model, CPU, RAM, disks, NICs, BMC, switch, quirks |
| Placeholder consistency | `REPLACE_ME_*` used for all site-specific values |
| `installation_device` | Matches OS disk described in comment block |
| `odf_device_count` | Consistent with ODF disk count in comment block |
| Redfish path | Matches BMC vendor in the [hardware reference](../reference/bare-metal-hardware.md) |
| YAML validity | All three files parse without error |
| Topology flag | `architecture: ha` for converged, `architecture: non-ha` for SNO |
| `odf_use_multus` | `true` for bare-metal, `false` for KVM |

---

## Related pages

- [Contribute a bare-metal example (tutorial)](../tutorials/contribute-bare-metal-example.md)
- [Bare-metal hardware reference](../reference/bare-metal-hardware.md) — Redfish paths, NIC naming, LACP, disk naming
- [Bare-metal hardware sizing](../reference/bare-metal-sizing.md) — CPU, RAM, disk, and network sizing targets
- [Deploy on bare-metal servers](deploy-on-bare-metal.md)
