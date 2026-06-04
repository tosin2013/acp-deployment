# ADR-0019: Cockpit Web Console as Mandatory VyOS VM Management Interface

## Date
2026-06-03

## Status
Accepted — Amended

> **Amendment (2026-06-03, VyOS hard requirement):** VyOS VM configuration via Cockpit is now a
> **hard requirement for ALL IBM Cloud KVM deployments**, including single-cluster. The prior
> "optional for single-cluster" distinction is removed. `hack/verify-dns-resolution.sh` enforces
> this by checking that the `vyos-router` VM is in `running` state before any VM creation is
> allowed. The alternative "Skip VyOS VM configuration for single-cluster" is no longer valid.

## Context

`hack/vyos-router.sh` (ADR-0017 amendment) creates a VyOS router VM on the IBM Cloud bare-metal KVM host as part of the mandatory infrastructure setup. The VyOS VM boots from a live ISO and requires interactive disk installation before persistent network configuration can be applied. This interactive installation step **cannot be automated** because VyOS's installer requires keyboard interaction at a console prompt that is only accessible while the VM is in a pre-disk-boot state.

The IBM Cloud bare-metal host is SSH-only — there is no physical keyboard or monitor. The only path to a VM's graphical or serial console from a remote machine is through a local web-based VM management interface.

Three access mechanisms were evaluated:

1. **VNC directly to the VM's VNC port** — Works but requires TCP port forwarding through SSH (complex, port conflicts, firewall management) and a local VNC client on the developer's workstation.
2. **`virsh console` (serial console)** — Requires the guest OS to expose a serial console device. VyOS's live ISO does not reliably expose serial console during the interactive installer stage.
3. **Cockpit web console** — Provides browser-based VM console access via HTTPS from any workstation. Cockpit is a Red Hat-maintained project, available in CentOS Stream 10's default repository, and provides a full graphical VM console through its `cockpit-machines` plugin without requiring port forwarding or a local VNC client.

The upstream `openshift-agent-install` developer guide ([VyOS Router Manual Configuration Guide](https://tosin2013.github.io/openshift-agent-install/vyos-manual-configuration.html)) documents Cockpit as the sole supported access path for VyOS VM console during interactive installation.

## Decision

**Cockpit** (`cockpit` + `cockpit-machines`) is installed as a mandatory dependency on the IBM Cloud KVM host and used as the VM console access mechanism for VyOS initial disk installation and network configuration.

Installation is handled automatically by `hack/vyos-router.sh`:

```bash
# Installed automatically if missing:
dnf install -y cockpit cockpit-machines
systemctl enable --now cockpit.socket
firewall-cmd --add-service=cockpit --permanent
firewall-cmd --reload
```

Cockpit credentials are written to `~/cockpit-credentials.txt` on first install (if `cockpit-admin` user does not exist).

**Access URL**: `https://<host-public-ip>:9090`

**VyOS console workflow via Cockpit**:
1. Open `https://<IBM-Cloud-public-IP>:9090` in browser
2. Login with credentials from `~/cockpit-credentials.txt`
3. Navigate: Virtual Machines → `vyos-router` → Console tab
4. Follow `docs/vyos-setup.md` for disk install and network configuration steps (~10–15 minutes)

Cockpit is used **only** for the VyOS interactive setup. It is not the primary management interface for the OpenShift cluster or Ansible operations — those remain SSH and kubeconfig-based (ADR-0003).

## Consequences

**Positive:**
- Browser-based VM console eliminates SSH tunnel + VNC client complexity. Any developer with network access to the IBM Cloud public IP on port 9090 can complete VyOS setup without installing additional software.
- Cockpit is a Red Hat-maintained product with active support on CentOS Stream 10; it is available from the default CentOS Stream repos without third-party repositories.
- `cockpit-machines` provides a full graphical console (VNC via WebSocket) with no network port forwarding or firewall changes beyond opening port 9090.
- Cockpit also provides useful secondary capabilities: resource monitoring (CPU/RAM during cluster deployment), storage management (pool inspection), and quick VM power control — all useful during development iteration cycles.
- Automated installation in `vyos-router.sh` means Cockpit is always present when VyOS setup is needed; no separate prerequisite step is required.

**Negative:**
- Port 9090 must be open on the IBM Cloud machine's `firewalld` public zone. This adds a management-plane exposure that should be restricted to trusted IP ranges in production environments.
- Cockpit uses a self-signed TLS certificate by default. Developers must accept a browser certificate warning on first access (or configure a valid certificate, which adds setup overhead).
- Cockpit's `cockpit-admin` user requires a password set on the host — this credential must be managed securely. It is stored in `~/cockpit-credentials.txt` (which is not committed to git).
- Cockpit session authentication is separate from SSH keys; developers need the Cockpit password in addition to their SSH key.

## Alternatives Considered

- **VNC with SSH port forwarding** — `ssh -L 5901:localhost:5901 user@host` then a local VNC client. Works but requires a VNC client installed locally, an available local port, and correct DISPLAY configuration in libvirt XML. Adds per-developer setup friction and is not documented in the upstream guide.
- **`virsh console` (serial/PTY)** — Requires `console=ttyS0` kernel argument and a serial device in the VM definition. VyOS's live ISO does not expose serial console during the installer phase; this approach fails at the exact step that requires console access.
- **Automating VyOS installation via `expect` scripts** — VyOS's installer prompts are not stable across versions and the interactive session involves timing-sensitive terminal interactions. This approach is brittle and was explicitly rejected by the upstream project.
- **Pre-configured VyOS image (cloud-init)** — VyOS does support cloud-init on paid enterprise builds. The nightly/rolling build used by this project (free, community) does not include cloud-init support. A pre-built image approach would require hosting and maintaining custom VyOS disk images — significant operational overhead.
- **Skip VyOS VM configuration for single-cluster** — ~~Previously considered valid for single-cluster deployments.~~ **Rejected** (2026-06-03 amendment). VyOS VM configuration is now a hard requirement for all deployments. `hack/verify-dns-resolution.sh` will block VM creation if `vyos-router` is not running.

## References

- [openshift-agent-install: VyOS Router Manual Configuration Guide](https://tosin2013.github.io/openshift-agent-install/vyos-manual-configuration.html)
- [openshift-agent-install: Developer Guide — Hard Requirement: VyOS Router](https://tosin2013.github.io/openshift-agent-install/developer-guide.html)
- ADR-0014: IBM Cloud Bare Metal as Combined KVM Host and Helper Node
- ADR-0017: Internal KVM Cluster DNS (Amendment: VyOS-First Architecture)
- `hack/vyos-router.sh` — automated VyOS VM creation and Cockpit installation
- `docs/vyos-setup.md` — manual VyOS disk install and network configuration procedure


---

## Validated in Production

v4.21.0 — 2026-06-04 — IBM Cloud KVM (3-node compact), OCP 4.21.8, acp-deployment v4.21.0. All role assumptions confirmed against a fully deployed cluster.
