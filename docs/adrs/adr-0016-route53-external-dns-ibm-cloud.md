# ADR-0016: Route53 as External DNS for IBM Cloud Cluster Access

## Date
2026-06-03

## Status
Accepted

## Context

OpenShift requires resolvable DNS records for external access (ADR-0008 covers the internal/lab DNS decision for bare-metal). The IBM Cloud deployment environment has two DNS contexts:

1. **Internal** (cluster VMs): VMs on the `acp-provisioning` libvirt network must resolve `api.<cluster>.<domain>` to the internal API VIP (`192.168.50.253`) and `*.apps.<cluster>.<domain>` to the ingress VIP (`192.168.50.252`). This is handled by dnsmasq (ADR-0017).
2. **External** (developer workstations, CI systems, AAP): Clients outside the IBM Cloud machine must resolve cluster FQDNs to the IBM Cloud public IP (`<EXTERNAL_IP>`) so they can reach the cluster via HAProxy (ADR-0015).

The bare-metal BIND-in-Podman approach (ADR-0008) is not suitable here: the BIND container on the helper node is on the internal libvirt network and is not authoritative for the public domain. A publicly authoritative DNS service is required.

The cluster's base domain (`sandbox3377.opentlc.com` in this environment) already has a hosted zone in AWS Route53. AWS credentials are available at `~/.aws/credentials` (default profile), making Route53 the lowest-friction authoritative DNS option.

## Decision

AWS Route53 is used as the external authoritative DNS for the cluster domain. The `hack/configure-route53-dns.sh` script manages the lifecycle of cluster DNS records:

- **On deploy**: creates A records pointing to `$EXTERNAL_IP` (IBM Cloud public IP):
  - `api.<CLUSTER_NAME>.<BASE_DOMAIN>` → `<EXTERNAL_IP>`
  - `api-int.<CLUSTER_NAME>.<BASE_DOMAIN>` → `<EXTERNAL_IP>` (external clients only; cluster VMs use dnsmasq)
  - `*.apps.<CLUSTER_NAME>.<BASE_DOMAIN>` → `<EXTERNAL_IP>`
- **On destroy**: deletes the same records (via `hack/configure-route53-dns.sh delete`)

The script accepts `CLUSTER_NAME`, `BASE_DOMAIN`, `HOSTED_ZONE_ID`, and `EXTERNAL_IP` as environment variables — never hardcoded — and uses the AWS CLI (`aws route53 change-resource-record-sets`) with the default credential profile.

Record TTL is set to 60 seconds to allow rapid updates during development without long propagation delays.

`hack/verify-dns-resolution.sh` validates external DNS by querying Google's public resolver (`8.8.8.8`) and confirming the returned IP matches `$EXTERNAL_IP` before allowing VM deployment to proceed (ADR-0018).

## Consequences

**Positive:**
- Route53 is the authoritative DNS for the existing domain — no additional DNS infrastructure is needed.
- AWS CLI automation via `configure-route53-dns.sh` makes record creation and teardown repeatable and scriptable; cluster rebuild cycles are clean.
- Route53's global anycast infrastructure provides reliable resolution worldwide with sub-60-second TTL propagation.
- The `delete` subcommand enables clean teardown when the cluster is no longer needed, preventing stale DNS records from accumulating.
- AWS credentials already present at `~/.aws/credentials` mean no additional credential setup is required.

**Negative:**
- Route53 requires a Route53-managed domain. Environments using other DNS providers (Cloudflare, corporate DNS, Azure DNS) need a different DNS automation script.
- A 60-second TTL means DNS changes take up to 60 seconds to propagate globally. During rapid rebuild cycles, resolvers may serve stale records briefly.
- If `$EXTERNAL_IP` changes (e.g., IBM Cloud reassigns the public IP after a reboot), the Route53 records must be manually updated by re-running `configure-route53-dns.sh add`.
- Route53 API calls incur a small cost (USD 0.004 per DNS query in public zones). For a development cluster this is negligible.

## Alternatives Considered

- **Cloudflare DNS** — Free tier, API-compatible alternative. Not applicable here because the `sandbox3377.opentlc.com` zone is in Route53 and cannot be moved for a lab environment.
- **`/etc/hosts` on each workstation** — Works for individual developers but does not scale to CI/CD systems, AAP automation, or shared access. Requires manual updates on each developer machine.
- **CoreDNS with external forwarding** — Could forward external queries to dnsmasq, but dnsmasq is internal only and not publicly reachable; this does not solve the external resolution problem.
- **Operator-managed certificates with Let's Encrypt DNS-01** — Already handled by ADR-0009 using cert-manager with Route53 as the solver. Route53 is already in use for cert-manager; extending it for cluster DNS records is consistent.


---

## Validated in Production

v4.21.0 — 2026-06-04 — IBM Cloud KVM (3-node compact), OCP 4.21.8, acp-deployment v4.21.0. All role assumptions confirmed against a fully deployed cluster.
