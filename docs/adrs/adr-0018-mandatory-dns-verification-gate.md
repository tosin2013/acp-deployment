# ADR-0018: Mandatory DNS Verification Gate Before VM Deployment

## Date
2026-06-03

## Status
Accepted

## Context

The OpenShift agent-based installer (ADR-0002) embeds cluster network configuration — including DNS server addresses — into the agent ISO at generation time. If DNS is misconfigured when the ISO is generated, the cluster nodes will use incorrect DNS settings and the installation will fail during bootstrap.

DNS failures during OpenShift installation are among the most common and hardest-to-diagnose failure modes:
- Nodes fail to resolve the API endpoint and cannot join the cluster.
- The bootstrap process times out without clear error messages pointing to DNS.
- Remediation requires stopping all VMs, re-running `create-installation-media.yml`, regenerating the ISO, and rebooting all nodes — a 30–60 minute recovery cycle.

In the IBM Cloud KVM environment, correct DNS requires two independent systems to be configured correctly and consistent with each other:
1. **dnsmasq** (ADR-0017) must resolve cluster FQDNs to internal VIPs for cluster VMs.
2. **Route53** (ADR-0016) must resolve the same FQDNs to the public IP for external workstation access.

Either system can be misconfigured independently of the other. A simple "does dnsmasq respond?" check would miss Route53 misconfiguration; a "does Route53 return anything?" check would miss dnsmasq not being started.

## Decision

`hack/verify-dns-resolution.sh` performs a comprehensive DNS verification check that must exit `0` before `hack/deploy-kvm-vms.sh` creates any VM. The check is embedded as a hard prerequisite at the top of `deploy-kvm-vms.sh`:

```bash
hack/verify-dns-resolution.sh || { echo "DNS verification failed. Fix DNS before deploying VMs."; exit 1; }
```

The verification script checks:

**Internal DNS (dnsmasq at `192.168.50.1`):**
```bash
dig @192.168.50.1 api.${CLUSTER_NAME}.${BASE_DOMAIN} +short    # must return 192.168.50.253
dig @192.168.50.1 api-int.${CLUSTER_NAME}.${BASE_DOMAIN} +short # must return 192.168.50.253
dig @192.168.50.1 test.apps.${CLUSTER_NAME}.${BASE_DOMAIN} +short # must return 192.168.50.252
```

**External DNS (Route53 via Google public resolver):**
```bash
dig @8.8.8.8 api.${CLUSTER_NAME}.${BASE_DOMAIN} +short    # must return $EXTERNAL_IP
dig @8.8.8.8 test.apps.${CLUSTER_NAME}.${BASE_DOMAIN} +short # must return $EXTERNAL_IP
```

**Dnsmasq service health:**
```bash
systemctl is-active dnsmasq  # must be active
```

If any check fails, the script prints a clear diagnostic message identifying the failing record and exits with status `1`. The overall execution time of the verification check is under 10 seconds.

## Consequences

**Positive:**
- Catches the most common source of failed OpenShift agent installs before any VM is created, saving the 30–60 minute VM teardown and rebuild cycle.
- Provides actionable error messages — operators know immediately whether the problem is dnsmasq, Route53, or the dnsmasq service not running, rather than diagnosing a generic bootstrap timeout.
- The check is fast (< 10 seconds) and has no side effects, making it safe to run repeatedly.
- Enforces the operational invariant that both DNS systems are consistent before a deployment proceeds, which is especially important in the IBM Cloud environment where internal and external DNS are served by completely separate systems.

**Negative:**
- The check adds a small mandatory step before VM deployment. Operators who have already verified DNS manually must still wait for the script to complete.
- External DNS check depends on `8.8.8.8` (Google Public DNS) being reachable from the IBM Cloud machine. In restricted network environments this external check would need to use a different public resolver.
- Route53 TTL propagation means a freshly created Route53 record may not yet be visible at `8.8.8.8` within the 60-second TTL window. The script waits up to 120 seconds with polling for Route53 records to propagate after `configure-route53-dns.sh add` completes.

## Alternatives Considered

- **Ansible pre-tasks DNS check** — Integrating DNS validation into the `create-installation-media.yml` playbook as a `pre_tasks` block would catch DNS issues before ISO generation. However, this couples KVM infrastructure concerns (dnsmasq, Route53) to the Ansible helper workflow, which must remain infrastructure-agnostic (bare-metal environments don't have dnsmasq or Route53).
- **Warn-and-continue** — Log a DNS warning but allow VM deployment to proceed. Rejected: a failed install that reaches bootstrap-timeout before failing costs significantly more time than a pre-flight check that catches the issue in 10 seconds.
- **Post-VM-creation check** — Check DNS from inside a VM after creation. By this point the agent installer may have already started; a failure here still requires full VM teardown and rebuild.
- **No check (rely on operator discipline)** — DNS misconfiguration is too common and its consequences too expensive in a development iteration cycle to leave to operator discipline alone.


---

## Validated in Production

v4.21.0 — 2026-06-04 — IBM Cloud KVM (3-node compact), OCP 4.21.8, acp-deployment v4.21.0. All role assumptions confirmed against a fully deployed cluster.
