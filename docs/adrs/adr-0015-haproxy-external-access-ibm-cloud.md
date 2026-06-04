# ADR-0015: HAProxy as External Access Layer for IBM Cloud Cluster

## Date
2026-06-03

## Status
Accepted

## Context

The ACP OpenShift cluster runs as KVM virtual machines on an IBM Cloud bare-metal server (ADR-0014). The cluster's API endpoint and application ingress VIPs are on the internal `acp-provisioning` libvirt network (`192.168.50.0/24`), which is not reachable from external workstations or clients.

IBM Cloud bare-metal networking has a critical architectural characteristic: the server is assigned a **private IP** (e.g., `10.241.64.5` on `eth0`) that is network-address-translated to a **public IP** by IBM Cloud's edge infrastructure. This means:

- Traffic arriving at the public IP is already NATted before it reaches `eth0`.
- Any process binding to the private IP (`10.241.64.5`) only will **not** receive this inbound NATted traffic.
- Processes must bind to `0.0.0.0` (all interfaces) to receive traffic that has been NATted from the public IP.

The OpenShift cluster requires four external ports to be reachable for full functionality:
- `6443/tcp` — Kubernetes API server (used by `oc`, `kubectl`, AAP, Tekton)
- `22623/tcp` — Machine Config Server (MCS, required during install and for node config)
- `80/tcp` — HTTP application ingress (OpenShift Router)
- `443/tcp` — HTTPS application ingress (OpenShift Router)

## Decision

HAProxy is deployed on the IBM Cloud machine (CentOS Stream 10) as a TCP-mode layer-4 load balancer providing external access to the cluster VIPs on the internal libvirt network.

HAProxy configuration:
- All frontends bind to `0.0.0.0` — required for IBM Cloud NAT passthrough.
- Port `6443` → backend `192.168.50.253:6443` (API VIP)
- Port `22623` → backend `192.168.50.253:22623` (MCS VIP)
- Port `80` → backend `192.168.50.252:80` (Ingress VIP)
- Port `443` → backend `192.168.50.252:443` (Ingress VIP)
- Stats dashboard on port `8404` (optional, `0.0.0.0`, HTTP)

All frontends operate in `mode tcp` (TLS passthrough — HAProxy does not terminate TLS). The cluster's own certificates (managed by cert-manager, ADR-0009) handle TLS end-to-end.

`firewalld` is configured to open ports `6443`, `22623`, `80`, `443` on the public zone so IBM Cloud's firewall allows inbound traffic through.

HAProxy is provisioned by `hack/configure-haproxy-forwarder.sh`, which is parameterised by environment variables (`CLUSTER_NAME`, `BASE_DOMAIN`, `API_VIP`, `INGRESS_VIP`) to keep actual values out of committed files.

## Consequences

**Positive:**
- Single-command setup via `hack/configure-haproxy-forwarder.sh`; reproducible across re-installs.
- TCP passthrough mode means HAProxy is transparent to TLS — OpenShift certificates are verified end-to-end without HAProxy needing a certificate.
- Binding to `0.0.0.0` correctly handles IBM Cloud NAT without any special iptables rules.
- HAProxy's health checks monitor backend VIP connectivity, providing early warning if the cluster API or ingress becomes unreachable.
- Stats dashboard provides real-time visibility into connection counts and backend health during install and post-install testing.

**Negative:**
- HAProxy is a single point of failure for external access. If the HAProxy process stops, the cluster API and applications become unreachable externally (though the cluster itself continues running).
- No HA HAProxy configuration: a single HAProxy instance is sufficient for a development testbed but would require a VIP or ELB for production.
- Ports `80` and `443` on the IBM Cloud machine are consumed by HAProxy. Any other web services on this machine would conflict; care must be taken not to install Apache/Nginx on the host.
- The stats endpoint at `8404` is unencrypted HTTP. It should be restricted by firewall to trusted IPs only.

## Alternatives Considered

- **NGINX stream proxy** — Functionally equivalent to HAProxy for TCP passthrough but requires the `nginx-mod-stream` package and is less commonly used in the OpenShift agent-install ecosystem. HAProxy is documented and tested in the [openshift-agent-install IBM Cloud guide](https://tosin2013.github.io/openshift-agent-install/ibm-cloud-deployment.html).
- **AWS/IBM Cloud Load Balancer** — A managed cloud load balancer (e.g., IBM Cloud NLB) would provide HA and managed certificate termination but requires VPC setup, additional cost, and significantly more configuration steps for a development environment.
- **Direct iptables DNAT rules** — Low-level NAT rules (`iptables -t nat -A PREROUTING ...`) can forward ports without HAProxy, but provide no health checking, no logging, and are harder to manage and audit.
- **Direct node exposure (no VIP)** — Pointing DNS directly at individual node IPs eliminates the load balancer but removes the VIP abstraction. If a node is replaced, DNS records must be updated manually, which is incompatible with the agent installer's VIP-based architecture.


---

## Validated in Production

v4.21.0 — 2026-06-04 — IBM Cloud KVM (3-node compact), OCP 4.21.8, acp-deployment v4.21.0. All role assumptions confirmed against a fully deployed cluster.
