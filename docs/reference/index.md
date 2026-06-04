# Reference

Reference documentation is **information-oriented**. It contains accurate, complete, neutral technical facts about the project. There are no instructions or explanations here — only descriptions of what things are and how they work.

**Start here if:** You need to look up a specific configuration parameter, script flag, playbook input, or design decision.

---

- [extra-vars.yml configuration parameters](extra-vars.md) — every variable with type, default, and description
- [hack/ scripts](hack-scripts.md) — all CLI flags, environment variables, and idempotency notes
- [Ansible playbooks](playbooks.md) — inputs, outputs, roles, and dependency order
- [Architectural Decision Records (ADR index)](adrs.md) — all 19 ADRs with status and v4.21.0 validation

## Bare-metal hardware reference

- [Bare-metal hardware compatibility](bare-metal-hardware.md) — BMC vendor Redfish paths, NIC naming, LACP switch config, disk device naming, and known quirks
- [Bare-metal hardware sizing](bare-metal-sizing.md) — CPU, RAM, disk, and network sizing targets for Converged and SNO topologies
