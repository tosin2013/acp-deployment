# How to resolve: 'ansible_user' is undefined on the helper node

**Symptom:** Playbooks fail at `Gathering Facts` or when constructing `install_dir` paths:
```
FAILED! => {"msg": "The task includes an option with an undefined variable. 'ansible_user' is undefined"}
```
or
```
fatal: [helper]: FAILED! => the field 'path' has an invalid value, which includes an undefined variable.
```

**Root cause:** When `ansible_connection: local` is set (the helper runs Ansible against itself), Ansible does not auto-populate the `ansible_user` variable. Playbooks that construct paths like `/home/{{ ansible_user }}/cluster_acp/...` fail because `ansible_user` has no value.

---

## Prerequisites

- Access to `examples/ibm-cloud-active/inventory.yml`

## 1. Add ansible_user to the helper inventory

```bash
vi examples/ibm-cloud-active/inventory.yml
```

Add `ansible_user` to the helper host definition:

```yaml
all:
  hosts:
    helper:
      ansible_host: localhost
      ansible_connection: local
      ansible_python_interpreter: /usr/bin/python3
      ansible_user: "{{ lookup('env', 'USER') }}"
```

The `lookup('env', 'USER')` expression resolves at Ansible runtime to the OS user running the playbook — it is always available on Linux.

## 2. Verify the fix

```bash
ansible -i examples/ibm-cloud-active/inventory.yml helper \
  -m debug -a "var=ansible_user"
```

Expected output:
```
helper | SUCCESS => {
    "ansible_user": "vpcuser"
}
```

## 3. Re-run the failed playbook

```bash
ansible-playbook playbooks/site-post-install.yml \
  -i examples/ibm-cloud-active/inventory.yml \
  -e @examples/ibm-cloud-active/extra-vars.yml
```

## Secondary fix: default(ansible_user_id) in playbooks

If you encounter this in a custom playbook, use the `default()` fallback for all path constructions:

```yaml
vars:
  install_dir: "/home/{{ ansible_user | default(ansible_user_id) }}/cluster_{{ openshift.cluster_name }}/install"
```

`ansible_user_id` is always populated by Ansible fact gathering, even on local connections.

---

**Permanent fix:** `ansible_user: "{{ lookup('env', 'USER') }}"` is now set in all example inventories. All post-install playbooks use `ansible_user | default(ansible_user_id)` as a fallback. The post-install preflight script (`hack/verify-post-install-prerequisites.sh`) checks this before deployment.
