# Explanation

Explanation documents are **understanding-oriented**. They provide context, background, and design rationale. They answer "why?" and help you see the bigger picture. They are not instructions — for those, see the How-To Guides.

**Start here if:** You want to understand why ACP deployment works the way it does, or you want to make informed decisions about adapting it to new environments.

---

- [Architecture overview](architecture-overview.md) — the four-layer model, the helper node's role, and key interfaces
- [Understanding the deployment pipeline](deployment-pipeline.md) — why the 13 steps exist and why their order matters
- [KVM vs bare-metal deployment paths](kvm-vs-baremetal.md) — what differs, why it differs, and when to choose which
- [Understanding ODF storage design](odf-storage-design.md) — why Ceph, why LSO, why Multus, why 48 GiB RAM minimum
- [Why Ansible?](why-ansible.md) — the trade-offs behind choosing Ansible as the sole automation tool
