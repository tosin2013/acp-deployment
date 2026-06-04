# ADR-0009: ZeroSSL + cert-manager with DNS-01 Challenge for TLS Certificate Management

## Date
2026-06-03

## Status
Accepted

## Context

OpenShift clusters require valid TLS certificates for two critical endpoints:
- **Ingress wildcard**: `*.apps.<cluster>.<domain>` — used by all routes served by the OpenShift Router.
- **API server**: `api.<cluster>.<domain>` — used by `oc`, Kubernetes clients, and AAP for cluster API access.

By default, OpenShift uses self-signed certificates for both. Self-signed certificates cause TLS warnings in browsers, require custom CA trust distribution, and block integrations with external tools that enforce certificate validation (e.g., AAP, Tekton webhooks). Valid trusted certificates eliminate these friction points.

The ACP testbed environment has the following constraints:
- Nodes are in private networks; HTTP-01 ACME challenge (requiring inbound port 80) is not viable.
- The cluster domain is managed in either AWS Route53 or Cloudflare DNS — both support programmatic DNS record creation for DNS-01 challenges.
- A free, automated certificate authority is preferred to avoid per-cluster cost or corporate PKI onboarding delays.
- Certificate rotation must be automated for long-lived testbeds.

## Decision

The `update_ocp_ingress_cert` Ansible role automates certificate issuance and rotation using:

1. **OpenShift cert-manager operator** — Installed via OLM subscription as the certificate lifecycle management engine on the cluster.
2. **ZeroSSL** as the ACME certificate authority — ZeroSSL provides free, trusted certificates via the ACME protocol (RFC 8555) with no rate limits for testbed usage.
3. **DNS-01 ACME challenge** — Validates domain ownership by creating a `_acme-challenge` TXT record in the authoritative DNS zone, circumventing the need for inbound HTTP access.
4. **Route53 or Cloudflare as DNS solvers** — The `ClusterIssuer` is configured with either an AWS Route53 or Cloudflare solver using API credentials from environment variables.

The role:
- Installs the cert-manager operator and waits for CRD readiness.
- Creates a `ClusterIssuer` with ZeroSSL's ACME endpoint and the configured DNS-01 solver.
- Issues a `Certificate` CR for `*.apps.<cluster>.<domain>` and `api.<cluster>.<domain>`.
- Updates the `IngressController` to use the issued certificate secret.
- Patches the `APIServer` to use the issued certificate secret.
- Waits for cluster operators to stabilize after cert rotation.

## Consequences

**Positive:**
- Eliminates self-signed certificate warnings in browsers and API clients across the entire cluster.
- DNS-01 challenge works in private/firewalled environments where HTTP-01 is blocked.
- cert-manager automates renewal before expiry — no manual certificate rotation required for long-lived testbeds.
- ZeroSSL is free, publicly trusted, and supports the standard ACME protocol — no vendor lock-in.
- Both Route53 and Cloudflare DNS providers are supported, covering the most common DNS hosting scenarios for the target audience.

**Negative:**
- Requires external DNS API credentials (AWS access keys or Cloudflare API token) that must be managed securely. These credentials are not included in `examples/extra-vars.yml`, creating a documentation gap.
- cert-manager is an additional operator that must be installed and maintained on the cluster.
- The ZeroSSL ACME account must be pre-created and the EAB (External Account Binding) credentials provided in `extra-vars.yml` — this is not self-bootstrapping.
- Certificate issuance involves DNS propagation delays (typically 1-5 minutes) and ACME server polling, making the role take longer than other post-install tasks.
- Only Route53 and Cloudflare solvers are implemented; organizations using other DNS providers (Azure DNS, Google Cloud DNS, etc.) must add new solver configurations.

## Amendment — 2026-06-04 (Post-Install Pipeline Incident)

**Incident:** Two failures were observed during the first end-to-end run of `update-ocp-ingress-cert.yml`:

1. **Wrong `CertManager` CR apiVersion.** The `_certmanager` variable in `roles/update_ocp_ingress_cert/defaults/main.yml` originally used `apiVersion: acme.cert-manager.io/v1`. The OCP cert-manager operator bundles a different CRD group: the `CertManager` operand CR is `operator.openshift.io/v1alpha1`, not the upstream `acme.cert-manager.io/v1`. The task failed with `Failed to find exact match for acme.cert-manager.io/v1.CertManager`.

2. **kubeconfig `certificate-authority-data` not stripped after API cert rotation.** After the API server certificate is replaced with a ZeroSSL-issued cert, the kubeconfig must have its `certificate-authority-data` field removed so that the Python SSL library trusts the new certificate via the system CA store (which includes ZeroSSL's root). The `Update KUBECONFIG` handler performs this strip, but it failed silently in the same run due to `ansible_user` being undefined (see ADR-0003 amendment). Subsequent playbooks that connected to `api.<cluster>.<domain>:6443` received `CERTIFICATE_VERIFY_FAILED`.

**Constraints added:**

1. The `CertManager` operand CR MUST use `apiVersion: operator.openshift.io/v1alpha1`. Do not use the upstream `acme.cert-manager.io/v1` apiVersion — that group does not exist in the OCP cert-manager operator's CRD set.

2. After the `Update api` task rotates the API server certificate, the handler MUST strip `certificate-authority-data` from the kubeconfig at `~/cluster_<name>/install/auth/kubeconfig`. If the handler does not run (e.g., idempotent re-run where `Update api` is `ok` not `changed`), the operator must verify manually:
   ```bash
   grep -c "certificate-authority-data" ~/cluster_acp/install/auth/kubeconfig
   # Expected: 0 after TLS rotation
   ```
   If non-zero, strip with:
   ```bash
   sed -i '/^    certificate-authority-data:/d' ~/cluster_acp/install/auth/kubeconfig
   ```

3. The `Update KUBECONFIG` handler MUST use `ansible_user | default(ansible_user_id)` to resolve the kubeconfig path reliably for both SSH and local connections (see ADR-0003 amendment 2026-06-04).

**Affected files:**
- `roles/update_ocp_ingress_cert/defaults/main.yml` — `apiVersion` corrected to `operator.openshift.io/v1alpha1`.
- `roles/update_ocp_ingress_cert/handlers/main.yml` — `ansible_user | default(ansible_user_id)` fallback added.

---

## Alternatives Considered

- **Let's Encrypt** — Another free ACME CA with DNS-01 support. Rate limits (50 certificates per registered domain per week) can be a constraint in environments with frequent cluster rebuilds. ZeroSSL was chosen for its absence of published rate limits for individual certificates.
- **Corporate PKI / HashiCorp Vault** — Provides full control over the certificate chain and integrates with enterprise trust stores. Appropriate for production deployments, but requires significant pre-existing PKI infrastructure not available in all partner testbed environments.
- **Self-signed certificates (OpenShift default)** — No setup required, but breaks integrations with tools that enforce certificate validation and requires custom CA distribution to all clients. Rejected as the default for a reference implementation.
- **Manual certificate management** — Generate and upload certificates manually each time they are needed. Not scalable for automated testbed deployments and requires renewal reminders and operator intervention.
- **OpenShift's built-in certificate rotation** — Handles internal cluster certificates only; does not issue publicly trusted certificates for the ingress or API endpoints.


---

## Validated in Production

v4.21.0 — 2026-06-04 — IBM Cloud KVM (3-node compact), OCP 4.21.8, acp-deployment v4.21.0. All role assumptions confirmed against a fully deployed cluster.
