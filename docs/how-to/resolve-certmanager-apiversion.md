# How to resolve: cert-manager CertManager CR fails with 'Failed to find exact match'

**Symptom:** The `update-ocp-ingress-cert.yml` playbook fails with:
```
Failed to find exact match for acme.cert-manager.io/v1.CertManager
```
or the task `Create CertManager instance` fails with an API resource not found error.

**Root cause:** The `CertManager` CR in OCP's bundled cert-manager operator uses the API group `operator.openshift.io/v1alpha1`, **not** `acme.cert-manager.io/v1`. Using the wrong `apiVersion` causes the Kubernetes API server to reject the resource. Additionally, this CR must only be applied *after* the OLM CSV for cert-manager reaches `Succeeded` — applying it too early causes the CRD to not yet exist.

---

## 1. Check the current apiVersion in your role defaults

```bash
grep -A3 "kind: CertManager" \
  roles/update_ocp_ingress_cert/defaults/main.yml
```

If you see `apiVersion: acme.cert-manager.io/v1`, this is the bug.

## 2. Fix the apiVersion

```bash
vi roles/update_ocp_ingress_cert/defaults/main.yml
```

Change:
```yaml
_certmanager:
  apiVersion: acme.cert-manager.io/v1    # WRONG
```

To:
```yaml
_certmanager:
  apiVersion: operator.openshift.io/v1alpha1   # CORRECT for OCP cert-manager
```

## 3. Verify the cert-manager operator CSV has succeeded

The `CertManager` CR can only be applied after OLM installs the operator. Check the CSV phase:

```bash
oc get csv -n cert-manager-operator -o wide
```

Wait until `PHASE = Succeeded`. If it stays `Installing` or `Pending` for more than 3 minutes, check the OLM pod logs:

```bash
oc logs -n openshift-operator-lifecycle-manager \
  $(oc get pods -n openshift-operator-lifecycle-manager \
    -l app=catalog-operator -o name | head -1) | tail -30
```

## 4. Re-run the certificate playbook

```bash
ansible-playbook playbooks/update-ocp-ingress-cert.yml \
  -i examples/ibm-cloud-active/inventory.yml \
  -e @examples/ibm-cloud-active/extra-vars.yml
```

---

**Permanent fix:** The correct `apiVersion: operator.openshift.io/v1alpha1` is now set in `roles/update_ocp_ingress_cert/defaults/main.yml`. A `Wait for cert-manager-operator CSV to succeed` task was added to `roles/update_ocp_ingress_cert/tasks/cert-manager-operator.yml` to gate CR creation on operator readiness.
