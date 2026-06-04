# Contributing to acp-deployment

Thank you for considering a contribution to `acp-deployment`. This guide explains what kinds of contributions are most needed, how to make them, and what to include.

---

## Two paths, two contribution styles

This project has two deployment paths with different contribution dynamics:

### KVM on IBM Cloud contributions

The KVM path is well-validated (v4.21.0 was fully deployed and hardened on IBM Cloud KVM). Contributions here tend to be:

- Bug fixes discovered during deployment
- Improvements to the 13-step deployment pipeline
- New post-install service roles following the OLM pattern
- Improvements to preflight validation scripts

Because this path is more controlled (always the same virtual hardware), contributions are easier to validate and review.

### Bare-metal contributions

**This is where community contributions are most needed and most impactful.**

Every bare-metal site is different:

- **BMC vendors:** Dell iDRAC 9/10, HPE iLO 5/6, Supermicro X11/X12, AMI MegaRAC, Lenovo XCC
- **NIC configurations:** LACP bonded NICs, SR-IOV, single NIC, mixed vendors
- **Switch configurations:** Cisco, Arista, Juniper — LACP portchannel requirements vary
- **Disk layouts:** NVMe-only, SAS/SATA mixed, multiple disk sizes
- **Site networking:** Non-Route53 DNS, Cloudflare, corporate DNS, air-gapped environments

If you get ACP deployment working on your hardware, your example configuration is exactly what the next person with the same hardware needs. Please share it.

---

## How to contribute bare-metal support

### 1. Start with an example directory

The `examples/` directory contains topology examples:

```
examples/
  bare-metal-converged/   ← 3-node compact HA
    extra-vars.yml        ← cluster and node config
    inventory.yml         ← Ansible inventory
    nodes.yml             ← BMC addresses for Redfish
  bare-metal-sno/         ← single-node OpenShift
    extra-vars.yml
    inventory.yml
    nodes.yml
```

If your hardware requires significantly different configuration (e.g., different NIC bonding setup, different BMC path), add a new directory:

```
examples/bare-metal-dell-r750/
examples/bare-metal-hpe-dl380/
examples/bare-metal-supermicro-x12/
```

### 2. Document your hardware in extra-vars.yml

Include a comment block at the top of your `extra-vars.yml` describing:

```yaml
# Hardware reference configuration (per node):
#   Vendor  : Dell PowerEdge R750
#   CPU     : 2× Intel Xeon Gold 6330 (28 cores / 56 threads)
#   RAM     : 256 GB DDR4 ECC
#   Disk    : 2× NVMe 960 GB (OS: nvme0n1) + 4× NVMe 3.84 TB (ODF: nvme1n1, nvme2n1, nvme3n1, nvme4n1)
#   NIC     : 4× 25 GbE Mellanox ConnectX-5 (bond0: p1p1+p1p2, bond1: p2p1+p2p2)
#   BMC     : iDRAC 9 v5.10+
#   Switch  : Cisco Nexus 93180YC-FX with port-channel for LACP
#
# Redfish path: /redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD
```

### 3. Document your nodes.yml

Include the Redfish path comment and example BMC address format for your vendor:

```yaml
nodes:
  - name: control-0
    bmc:
      address: https://192.168.0.10    # Dell iDRAC 9 IP
      username: root
      # Redfish path for Dell iDRAC 9:
      # /redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD
```

### 4. Note any vendor-specific workarounds

If you had to work around a hardware-specific issue, document it in a comment in the relevant file and open an issue or PR. Common bare-metal gotchas include:

- **HPE iLO:** Different Redfish virtual media path (`/redfish/v1/Managers/1/VirtualMedia/2`)
- **NIC naming:** Some vendors use `eno1`, others `p1p1`, others `enp0s31f6` — the nmstate config must match
- **BMC self-signed certs:** Set `BAREMETAL_BMC_INSECURE=true` if your BMC uses a self-signed TLS cert
- **LACP mode:** Some switches use `active-active` not `802.3ad` mode in vendor terminology

---

## Contribution checklist

Before submitting a pull request:

- [ ] Tested the deployment end-to-end on real hardware (or documented which steps were validated)
- [ ] Removed all real credentials from `extra-vars.yml` (pull secrets, SSH keys, ZeroSSL keys)
- [ ] Used `<REPLACE_ME_*>` placeholders for site-specific values (IPs, MACs, domains)
- [ ] Added a comment block describing the hardware configuration
- [ ] Run `./hack/verify-odf-prerequisites.sh` (if ODF is part of your change)
- [ ] Run `./hack/verify-post-install-prerequisites.sh` (if post-install services are involved)
- [ ] Referenced any related ADR if your change is an architectural decision

---

## SNO (Single-Node OpenShift) for edge sites

SNO on bare-metal is particularly useful for space and power-constrained edge deployments. Key differences from converged:

- Set `architecture: non-ha` in `extra-vars.yml`
- ODF is **not supported** — use an external storage class (NFS, iSCSI, hostPath for development)
- Only 1 server and 1 entry in `nodes.yml`
- The control node runs both control-plane and workloads without taint removal
- AAP will work but needs a storage class for its PostgreSQL PVC

Example SNO configuration is in `examples/bare-metal-sno/`.

---

## Adding support for non-Route53 DNS providers

The current cert-manager `ClusterIssuer` in `roles/update_ocp_ingress_cert/templates/clusterissuer.yaml.j2` supports Route53 and Cloudflare. To add a new DNS provider:

1. Add the solver configuration to `clusterissuer.yaml.j2`
2. Add the relevant environment variables to the playbook's `vars:` block
3. Document the new credential requirements in `docs/reference/extra-vars.md`
4. Update `docs/how-to/configure-zerossl-tls.md` with the new provider

---

## Code conventions

- All Kubernetes resources are managed via `redhat.openshift.k8s` — do not use raw `kubectl`/`oc` commands
- Follow the OLM pattern: Namespace → OperatorGroup → Subscription → wait CSV → operand CR → wait readiness (ADR-0006)
- Use `ansible_user | default(ansible_user_id)` for any path construction involving the user's home directory (ADR-0003)
- Keep all CR definitions in `roles/<name>/vars/main.yml` — tasks should reference variables, not inline YAML
- See [CLAUDE.md](CLAUDE.md) for known failure patterns that affect automated development

---

## Opening an issue

If you find a problem:

1. Check [CLAUDE.md](CLAUDE.md) — your issue may already be a known pattern with a fix
2. Check the hardening reports in `docs/hardening/`
3. Open a GitHub issue with:
   - Your deployment path (KVM or bare-metal)
   - Your hardware/cloud environment
   - The exact error message
   - Which playbook or script failed
   - What you tried

---

## License

By contributing, you agree that your contributions are licensed under the [Apache 2.0 License](LICENSE).
