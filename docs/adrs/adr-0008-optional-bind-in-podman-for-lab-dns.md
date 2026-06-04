# ADR-0008: Optional BIND-in-Podman for Lab DNS

## Date
2026-06-03

## Status
Accepted

## Context

OpenShift requires DNS resolution for its API endpoint (`api.<cluster>.<domain>`), wildcard application ingress (`*.apps.<cluster>.<domain>`), and internal cluster FQDN resolution. In production environments, these DNS records are created in an organization's existing external DNS infrastructure. However, ACP testbeds are frequently deployed in isolated lab networks or on-premises environments where no existing DNS infrastructure is available.

Without DNS, the agent-based installer cannot complete cluster installation and all cluster API and application access fails. The deployment automation must handle both scenarios — environments with external DNS and environments without.

The helper node is already a dedicated Linux server with network access to the cluster network (ADR-0003), making it a natural candidate to host DNS services without requiring additional hardware.

## Decision

DNS is made optional and controlled by the `external_dns` boolean variable in `extra-vars.yml`:

- **`external_dns: true`** (production): The operator manually creates the required DNS records in their external DNS system. Ansible skips all DNS-related tasks.
- **`external_dns: false`** (lab/testbed default): Ansible executes `playbooks/dns.yml` to build and run a BIND DNS server as a Podman container on the helper node.

The BIND container implementation:
- Uses Red Hat Universal Base Image 9 (UBI9) as the base, defined in `playbooks/files/bind-Containerfile`.
- BIND forward and reverse zone files are generated from Ansible variables using `playbooks/templates/bind-named.conf.j2` and zone template files.
- The container runs with `--network host` and `--privileged` flags to bind to port 53 on the helper's network interface.
- `firewalld` is configured to open UDP/TCP port 53 on the appropriate zone.
- The DNS configuration covers API, ingress wildcard, and all node FQDN records.

## Consequences

**Positive:**
- Enables complete testbed deployments in isolated lab environments with no pre-existing DNS infrastructure.
- Containerized BIND isolates the DNS service from the helper's OS packages and simplifies cleanup.
- UBI9 base image is Red Hat supported and receives security updates.
- The same `extra-vars.yml` file supports both DNS modes by flipping a single boolean, with no playbook changes.
- Zone configuration is fully generated from the existing cluster variable definitions — no duplicate data entry.

**Negative:**
- The helper node becomes a critical DNS dependency for the cluster. If the helper is rebooted or the Podman container stops, the cluster loses external DNS resolution (internal cluster DNS via CoreDNS is unaffected).
- Running with `--network host` and `--privileged` reduces container isolation — acceptable for a testbed helper but not appropriate for production use.
- The Podman container is not configured to restart automatically across helper reboots (no systemd unit generated). Post-reboot DNS restoration requires manual intervention.
- Not suitable as the authoritative DNS approach for production ACP deployments where carrier-grade DNS reliability is required.

## Alternatives Considered

- **dnsmasq** — Lightweight and commonly pre-installed on Linux, but lacks BIND's full RFC-compliant zone management, logging, and view-based split-horizon capabilities. Less familiar to DNS administrators.
- **CoreDNS standalone** — Kubernetes-native and widely used within OpenShift, but running it outside the cluster for pre-install DNS adds complexity without significant benefit over BIND.
- **Require external DNS always** — Simplifies the automation by eliminating the DNS playbook entirely, but blocks testbed deployments in isolated environments — a significant barrier for the target audience.
- **dnsmasq on the helper OS (non-containerized)** — Simpler than a container approach but risks OS-level conflicts with `systemd-resolved` and makes cleanup harder.


---

## Validated in Production

v4.21.0 — 2026-06-04 — IBM Cloud KVM (3-node compact), OCP 4.21.8, acp-deployment v4.21.0. All role assumptions confirmed against a fully deployed cluster.
