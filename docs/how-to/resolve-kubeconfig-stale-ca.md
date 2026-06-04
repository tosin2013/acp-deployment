# How to resolve: CERTIFICATE_VERIFY_FAILED after API certificate rotation

**Symptom:** After running `update-ocp-ingress-cert.yml`, subsequent playbooks fail with:
```
CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate
```
or:
```
SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed: unable to get local issuer certificate (_ssl.c:1xxx)
```

**Root cause:** When the OpenShift API server certificate is rotated to ZeroSSL (a publicly trusted CA), the kubeconfig at `~/.kube/config` still contains a `certificate-authority-data` field pointing to the old self-signed CA. The Kubernetes Python client uses this embedded CA to validate the API server's certificate — but the new ZeroSSL cert is not signed by the old self-signed CA, so validation fails.

---

## 1. Check for stale certificate-authority-data

```bash
grep "certificate-authority-data" ~/.kube/config
```

If this line exists **and** cert rotation has already completed, it needs to be removed.

## 2. Verify the new certificate is trusted

```bash
# Should return cluster version without SSL errors
curl -sk https://api.$(oc get dns cluster -o jsonpath='{.spec.baseDomain}'):6443/version
```

If this returns valid JSON, the new ZeroSSL certificate is in place and the system CA trusts it.

## 3. Remove the stale CA from kubeconfig

```bash
sed -i '/certificate-authority-data/d' ~/.kube/config
```

> **Why is this safe?** After cert rotation, the API server serves a ZeroSSL certificate signed by a public CA that is trusted by the system's default CA bundle. The `certificate-authority-data` field in kubeconfig was only needed to trust the old *self-signed* CA. Once removed, the Kubernetes client falls back to the system CA bundle, which already trusts ZeroSSL.

## 4. Also update the cluster install directory kubeconfig

The install directory kubeconfig may also have stale CA data:

```bash
sed -i '/certificate-authority-data/d' ~/cluster_acp/install/auth/kubeconfig
```

## 5. Verify API access

```bash
oc get nodes
```

This should succeed without SSL errors.

## 6. Re-run the failed playbook

```bash
ansible-playbook playbooks/setup-openshift-virtualization.yml \
  -i examples/ibm-cloud-active/inventory.yml \
  -e @examples/ibm-cloud-active/extra-vars.yml
```

---

**Why this happened:** The `Update KUBECONFIG` handler in `roles/update_ocp_ingress_cert/handlers/main.yml` was supposed to strip the `certificate-authority-data` line automatically, but failed silently because `ansible_user` was undefined (see [How to resolve ansible_user undefined](./resolve-ansible-user-undefined.md)).

**Permanent fix:** The `ansible_user` bug is fixed in all post-install playbooks and the handler now uses `ansible_user | default(ansible_user_id)`. The post-install preflight script (`hack/verify-post-install-prerequisites.sh`) checks for stale `certificate-authority-data` before deployment.
