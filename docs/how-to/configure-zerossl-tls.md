# How to configure trusted TLS certificates with ZeroSSL

**Goal:** Replace the default self-signed OpenShift certificates with publicly trusted certificates from ZeroSSL, covering both the ingress wildcard (`*.apps.*`) and the API server (`api.*`).

**Prerequisites:**
- Running OCP cluster with `KUBECONFIG` set
- Route53 hosted zone for your cluster domain
- AWS IAM credentials with Route53 write access at `~/.aws/credentials`
- ZeroSSL account with EAB credentials (Key ID + HMAC key) from [app.zerossl.com/developer](https://app.zerossl.com/developer)
- `zerossl_account`, `workshop_dns_zone`, and `aws_region` populated in your `extra-vars.yml`
- `boto3` and `botocore` installed: `pip3 install boto3 botocore`

---

## 1. Run the post-install preflight check

```bash
./hack/verify-post-install-prerequisites.sh \
  -i examples/ibm-cloud-active/inventory.yml
```

Check 3 (kubeconfig stale CA) must pass. If it reports stale `certificate-authority-data`, see [How to resolve kubeconfig stale CA](./resolve-kubeconfig-stale-ca.md) first.

## 2. Export AWS credentials

```bash
export AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id)
export AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key)
```

## 3. Run the certificate playbook

```bash
ansible-playbook playbooks/update-ocp-ingress-cert.yml \
  -i examples/ibm-cloud-active/inventory.yml \
  -e @examples/ibm-cloud-active/extra-vars.yml
```

The playbook:
1. Installs the cert-manager operator and waits for CSV `Succeeded`
2. Creates a `CertManager` CR (`operator.openshift.io/v1alpha1`)
3. Creates a `ClusterIssuer` pointing to ZeroSSL's ACME endpoint with Route53 DNS-01 solver
4. Issues `Certificate` CRs for `*.apps.*` and `api.*`
5. Updates the `IngressController` default certificate
6. Patches the `APIServer` with the new certificate
7. Waits for cluster operators to stabilise

Runtime: 10–20 minutes (DNS propagation + ACME challenge takes most of the time).

## 4. Verify the certificates

```bash
# cert-manager operator is running
oc get csv -n cert-manager-operator | grep Succeeded

# Certificates are Ready
oc get certificate -A

# Test the API cert
curl -s https://api.$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')/version | jq .gitVersion

# Test ingress cert (replace with your domain)
curl -sv https://console-openshift-console.apps.acp.example.com 2>&1 | grep -i "issuer"
```

The issuer should show `ZeroSSL` or `E1`/`E6` (ZeroSSL's intermediate CAs).

## 5. Remove stale CA from kubeconfig

After the API server certificate rotates, remove the old self-signed CA from your kubeconfig:

```bash
sed -i '/certificate-authority-data/d' ~/.kube/config
```

Then test API access works without CA warnings:

```bash
oc get nodes
```

---

**Expected outcome:** All cluster routes serve ZeroSSL-issued certificates. No browser TLS warnings. `oc` CLI connects without CA trust errors.

**If cert-manager fails to start:** See [How to resolve cert-manager apiVersion mismatch](./resolve-certmanager-apiversion.md).
