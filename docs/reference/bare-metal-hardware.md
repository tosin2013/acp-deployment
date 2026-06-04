# Bare-metal hardware reference

Reference tables for BMC vendors, Redfish paths, NIC naming conventions, switch LACP requirements, disk device naming, and known hardware quirks. Use this alongside the `examples/bare-metal-*` directories when adapting a configuration to your hardware.

---

## BMC vendors and Redfish virtual media paths

The Agent-Based Installer ISO is mounted on each node via Redfish virtual media. The path to the virtual media resource differs by BMC vendor and firmware version.

| Vendor | BMC product | Redfish virtual media path | Notes |
|--------|-------------|---------------------------|-------|
| Dell | iDRAC 9 | `/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD` | Default path for iDRAC 9 |
| Dell | iDRAC 10 | `/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD` | Same path as iDRAC 9 |
| HPE | iLO 5 | `/redfish/v1/Managers/1/VirtualMedia/2` | Slot 2 is CD-ROM |
| HPE | iLO 6 | `/redfish/v1/Managers/1/VirtualMedia/2` | Same path as iLO 5 |
| Supermicro | BMC (X11/X12) | `/redfish/v1/Managers/1/VirtualMedia/CD1` | X11 and X12 share this path |
| AMI | MegaRAC SP-X | `/redfish/v1/Managers/BMC/VirtualMedia/CD` | Used by many white-label OEM boards |
| Lenovo | XCC (v2 and v3) | `/redfish/v1/Managers/1/VirtualMedia/CD` | XCC v1 uses a different path — check firmware |
| Inspur | BMC | `/redfish/v1/Managers/BMC/VirtualMedia/CD` | Same as AMI MegaRAC |

### How to confirm your Redfish path

If your vendor is not listed, or if you are on an unusual firmware version:

```bash
# Enumerate all virtual media slots on the BMC
curl -sk -u root:$BAREMETAL_BMC_PASSWORD \
  https://<BMC_IP>/redfish/v1/Managers/ | python3 -m json.tool | grep -i manager

# Then list virtual media for the manager found above
curl -sk -u root:$BAREMETAL_BMC_PASSWORD \
  https://<BMC_IP>/redfish/v1/Managers/<MANAGER_ID>/VirtualMedia/ | python3 -m json.tool
```

The response lists all available virtual media slots. The CD-ROM slot is what you need.

### BMC self-signed certificates

Most BMC units ship with self-signed TLS certificates. Set the following environment variable to skip certificate verification:

```bash
export BAREMETAL_BMC_INSECURE=true
```

> Do not disable certificate verification in production environments. Replace the BMC certificate with a CA-signed one where security policy requires it.

---

## NIC naming conventions

OpenShift node networking is configured via nmstate in `extra-vars.yml`. The interface names in the nmstate configuration must match the names the kernel assigns to the physical NICs. These names vary by driver, NIC vendor, and slot position.

### Naming scheme by NIC vendor

| NIC vendor | Driver | Typical interface names | Notes |
|------------|--------|------------------------|-------|
| Mellanox ConnectX-4/5/6 | `mlx5_core` | `p1p1`, `p1p2`, `p2p1`, `p2p2` | Slot-based; `p1` = first slot, `p1p1` = first port |
| Mellanox ConnectX-4/5/6 (alt) | `mlx5_core` | `ens2f0`, `ens2f1` | Seen on some BIOS/firmware versions |
| Intel X710/XXV710 | `i40e` | `ens1f0`, `ens1f1`, `ens5f0`, `ens5f1` | Slot and function number |
| Intel E810 | `ice` | `ens1f0`, `ens1f1` | Same pattern as X710 |
| Broadcom 57504/57508 | `bnxt_en` | `eno1`, `eno2`, `eno3`, `eno4` | Embedded (onboard); slot NICs use `ens*` |
| Broadcom (PCIe) | `bnxt_en` | `enp<slot>s0f0`, `enp<slot>s0f1` | PCI slot-based naming |
| QLogic/Marvell FastLinQ | `qede` | `enp<slot>s0f0`, `enp<slot>s0f1` | |
| Mixed (any) | various | Depends on slot + driver | See "How to find your NIC names" below |

### Embedded vs slot NICs

- **Embedded (onboard) NICs** typically get `eno1`, `eno2`, etc.
- **PCIe slot NICs** typically get `enp<bus>s<slot>f<function>` (kernel predictable names) or `p<slot>p<port>` (some RHEL versions)
- **Biosdevname disabled** (some RHEL configurations): names fall back to `eth0`, `eth1`, etc.

### How to find your NIC names before deployment

Boot a RHEL 9 live environment on one node and run:

```bash
ip link show
# or
nmcli device status

# For more detail (driver, PCI address):
lshw -class network -short
```

For systems already enrolled in the BMC:

```bash
# Dell iDRAC: list NIC properties
racadm getconfig -c cfgLanNetworking

# HPE iLO: use the iLO web UI → System → Network → NICs
# or via Redfish:
curl -sk -u root:$BAREMETAL_BMC_PASSWORD \
  https://<BMC_IP>/redfish/v1/Systems/1/EthernetInterfaces/ | python3 -m json.tool
```

---

## LACP portchannel requirements by switch vendor

All bare-metal ACP deployments use LACP bonding (`802.3ad`) for node NICs. The switch-side configuration varies by vendor.

### Cisco Nexus (NX-OS)

```
interface port-channel10
  switchport mode trunk
  switchport trunk allowed vlan 100,200
  spanning-tree port type edge trunk

interface ethernet1/1
  channel-group 10 mode active    # <-- must be 'active', not 'passive' or 'on'
  no shutdown

interface ethernet1/2
  channel-group 10 mode active
  no shutdown
```

> **Critical:** Both the switch and the NIC bond must be in `active` mode for LACP negotiation. `passive/passive` will not bond.

### Arista EOS

```
interface Port-Channel10
   switchport mode trunk
   switchport trunk allowed vlan 100,200

interface Ethernet1
   channel-group 10 mode active
   no shutdown

interface Ethernet2
   channel-group 10 mode active
   no shutdown
```

### Juniper EX Series (Junos)

```
set interfaces ae0 aggregated-ether-options lacp active
set interfaces ae0 unit 0 family ethernet-switching interface-mode trunk
set interfaces ae0 unit 0 family ethernet-switching vlan members [vlan-100 vlan-200]

set interfaces ge-0/0/0 ether-options 802.3ad ae0
set interfaces ge-0/0/1 ether-options 802.3ad ae0
```

### Common LACP failure modes

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Bond comes up but flaps | LACP PDU mismatch (different timers) | Set `lacp-rate fast` on both sides |
| Only one member active | Switch port in `mode on` (static) instead of `mode active` | Change switch to `mode active` |
| Bond never forms | VLAN mismatch on trunk | Verify allowed VLANs match on both sides |
| Intermittent drops | MTU mismatch | Set jumbo frames consistently (9000 bytes) |
| Both bonds go down on reboot | Switch LACP min-links configured | Ensure min-links ≤ member count |

---

## Disk device naming and ODF layouts

### Device naming by storage type

| Storage type | Kernel device path | By-path (stable) | Notes |
|-------------|-------------------|------------------|-------|
| NVMe (PCIe slot 0, first drive) | `/dev/nvme0n1` | `/dev/disk/by-path/pci-0000:02:00.0-nvme-1` | NVMe numbering may shift after BIOS update |
| NVMe (PCIe slot 0, second drive) | `/dev/nvme1n1` | `/dev/disk/by-path/pci-0000:03:00.0-nvme-1` | |
| SAS/SATA (first) | `/dev/sda` | `/dev/disk/by-path/pci-0000:00:1f.2-ata-1` | |
| SAS via HBA (first) | `/dev/sda` | `/dev/disk/by-id/scsi-<wwn>` | Use WWN for stability |

> **Recommendation:** Use `/dev/disk/by-path/` for `installation_device` in `extra-vars.yml`. The `/dev/nvme0n1` path is convenient but can change if NVMe drives are added or reordered between BIOS updates or slot changes.

### ODF disk layout examples

ODF (Ceph) requires that ODF disks are **separate from the OS disk** and are **raw** (unformatted, no partition table). LSO discovers them automatically based on the `deviceMechanicalProperties` and `deviceInclusionSpec` filters.

#### Minimum viable ODF (1 ODF disk per node, replica 2)

```
Per node:
  /dev/nvme0n1  ←  OS (installation_device)
  /dev/nvme1n1  ←  ODF (odf_device_count: 1)

3-node cluster total ODF raw capacity: 3 × disk_size
Usable with replica-2: ≈ 50% of raw
```

#### Validated reference layout (2 ODF disks per node, replica 3)

```
Per node:
  /dev/nvme0n1  ←  OS (installation_device: /dev/nvme0n1)
  /dev/nvme1n1  ←  ODF disk 1 (odf_device_count: 2)
  /dev/nvme2n1  ←  ODF disk 2

3-node cluster total ODF raw capacity: 3 × 2 × disk_size
Usable with replica-3: ≈ 33% of raw
```

#### Mixed NVMe + SAS layout

```
Per node:
  /dev/nvme0n1  ←  OS
  /dev/sda      ←  ODF disk 1 (SAS)
  /dev/sdb      ←  ODF disk 2 (SAS)
```

For mixed rotational/non-rotational layouts, LSO must include both `Rotational` and `NonRotational` in `deviceMechanicalProperties`. See [ADR-0005](../adrs/adr-0005-odf-on-local-nvme-with-multus-storage-network.md) for the resolution of this issue on KVM, which applies equally to SAS disks on bare-metal.

---

## Known BMC quirks and workarounds

| Vendor / version | Issue | Workaround |
|-----------------|-------|-----------|
| Dell iDRAC 9 v5.x | Redfish session timeout during ISO mount causes silent failure | Upgrade to iDRAC 9 v6.10+ or use `idrac8` compatibility mode |
| Dell iDRAC 9 (any) | Virtual media eject fails if ISO is still mounted from previous attempt | Use Redfish `DELETE` on the session resource, then remount |
| HPE iLO 5 < v2.65 | `InsertVirtualMedia` returns 200 but media is not actually mounted | Upgrade iLO firmware to v2.65+ |
| HPE iLO 6 | Different session authentication scheme from iLO 5 | Ensure `ilorest` or the Redfish client is using Basic auth, not session tokens |
| Supermicro X11 | Redfish API requires `X-Auth-Token` header (session-based auth), not Basic auth | Obtain a session token first via `POST /redfish/v1/SessionService/Sessions` |
| Supermicro X12 | Virtual media path changed from X11 | Use `CD1` not `CD` in the path; verify with enumeration |
| AMI MegaRAC | Default admin account is `admin`/`admin` — may be locked on first boot | Set password via IPMI: `ipmitool -H <ip> -U admin -P admin user set password 2 <newpass>` |
| Lenovo XCC v1 | Redfish virtual media not available (XCC v1 predates full Redfish support) | Upgrade to XCC v2 firmware before attempting Redfish boot |
| Any BMC | Self-signed TLS cert causes curl/Python `CERTIFICATE_VERIFY_FAILED` | Set `BAREMETAL_BMC_INSECURE=true` or import the BMC cert into the system trust store |
| Any BMC | Node powers off instead of rebooting from ISO | Check that `BootSourceOverrideEnabled: Once` is set, not `Continuous` |
| Any BMC | IPMI console shows boot, but cluster install never starts | The ISO may not have been mounted successfully — check `InsertVirtualMedia` response body for errors |
