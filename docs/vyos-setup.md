# VyOS Router Manual Configuration Guide

> **Why manual?** VyOS boots from a live ISO and must be installed interactively to disk before any network configuration can be applied. This step cannot be scripted. Allow 10–15 minutes. It only needs to be done once per KVM host.

## Overview

The VyOS router provides VLAN-isolated networks for running SNO and Converged clusters concurrently on the same IBM Cloud bare-metal KVM host. Each cluster topology gets its own `/24`:

| VLAN | Network | Bridge | Use |
|------|---------|--------|-----|
| default | 192.168.122.0/24 | virbr0 | VyOS internet access |
| 1924 | 192.168.49.0/24 | virbr-1924 | VyOS management |
| 1925 | 192.168.50.0/24 | virbr-1925 | Converged cluster |
| 1926 | 192.168.51.0/24 | virbr-1926 | SNO cluster |

HAProxy, Route53, and cert-manager are unchanged — VyOS only provides internal VLAN DNS and routing.

## Prerequisites

1. `hack/vyos-router.sh` has been run successfully
2. The `vyos-router` VM is running: `virsh list | grep vyos`
3. Cockpit is accessible: `https://<host-ip>:9090`

## Step 1 — Open the VyOS Console

1. Open a browser to `https://<HOST_IP>:9090` (accept the self-signed cert)
2. Log in (your Linux credentials or `cockpit-admin` if set up)
3. Click **Virtual Machines** in the left sidebar
4. Click **vyos-router**
5. Click the **Console** tab
6. You should see the VyOS live ISO boot menu

If the screen is blank, click inside the console area and press **Enter**.

## Step 2 — Install VyOS to Disk

At the VyOS login prompt:

```
Login: vyos
Password: vyos
```

Start disk installation:

```
install image
```

Accept all prompts (press **Enter** for defaults):

```
Would you like to continue? (Yes/No) [Yes]:           <Enter>
Partition (Auto/Parted/Skip) [Auto]:                  <Enter>
Install the image on? [sda]:                          <Enter>
Continue? (Yes/No) [No]: Yes
How big of a root partition? (2000MB - 20480MB) [20480]: <Enter>
What would you like to name this image? [1.5-rolling]: <Enter>
Which config file should I copy? [...]: <Enter>
Which drive should GRUB modify? [sda]:                <Enter>
```

The VM reboots automatically after installation.

## Step 3 — Restart the VM After Installation

After the reboot, in Cockpit:

1. The console may show a blank screen — click **Power Off**
2. Wait for status to show **Shut off**
3. Click **Run** to start the VM
4. Click the **Console** tab
5. Wait for the VyOS login prompt (30–60 seconds)

Log in again:

```
Login: vyos
Password: vyos
```

## Step 4 — Configure Network Interfaces

VyOS interface mapping (as attached by `hack/vyos-router.sh`):

| Interface | Connected to | Purpose |
|-----------|-------------|---------|
| eth0 | libvirt default | Internet access (DHCP from 192.168.122.1) |
| eth1 | VLAN 1924 | VyOS management |
| eth2 | VLAN 1925 | Converged cluster network |
| eth3 | VLAN 1926 | SNO cluster network |

Enter configuration mode:

```
configure
```

Configure eth0 (internet uplink via libvirt default NAT):

```
set interfaces ethernet eth0 address dhcp
set interfaces ethernet eth0 description 'Libvirt-default-uplink'
```

Configure VLAN 1924 (management):

```
set interfaces ethernet eth1 address '192.168.49.1/24'
set interfaces ethernet eth1 description 'VLAN-1924-management'
```

Configure VLAN 1925 (Converged cluster):

```
set interfaces ethernet eth2 address '192.168.50.1/24'
set interfaces ethernet eth2 description 'VLAN-1925-converged'
```

Configure VLAN 1926 (SNO cluster):

```
set interfaces ethernet eth3 address '192.168.51.1/24'
set interfaces ethernet eth3 description 'VLAN-1926-sno'
```

## Step 5 — Configure DNS Forwarding

Configure DNS forwarding on all VLAN interfaces. VyOS will forward queries for each cluster's domain to the upstream resolvers:

```
set service dns forwarding cache-size '0'
set service dns forwarding listen-address '192.168.49.1'
set service dns forwarding listen-address '192.168.50.1'
set service dns forwarding listen-address '192.168.51.1'
set service dns forwarding allow-from '192.168.49.0/24'
set service dns forwarding allow-from '192.168.50.0/24'
set service dns forwarding allow-from '192.168.51.0/24'
set service dns forwarding name-server '1.1.1.1'
set service dns forwarding name-server '8.8.8.8'
```

## Step 6 — Configure NAT Masquerading

Allow cluster VMs to reach the internet through eth0:

```
set nat source rule 100 outbound-interface name 'eth0'
set nat source rule 100 source address '192.168.49.0/24'
set nat source rule 100 translation address masquerade

set nat source rule 101 outbound-interface name 'eth0'
set nat source rule 101 source address '192.168.50.0/24'
set nat source rule 101 translation address masquerade

set nat source rule 102 outbound-interface name 'eth0'
set nat source rule 102 source address '192.168.51.0/24'
set nat source rule 102 translation address masquerade
```

## Step 7 — Enable SSH Access

```
set service ssh port '22'
set service ssh listen-address '0.0.0.0'
```

## Step 8 — Commit and Save

```
commit
save
exit
```

## Step 9 — Verify from the KVM Host

Open a new terminal on the IBM Cloud host and test:

```bash
# Converged cluster VLAN gateway
ping -c 3 192.168.50.1

# SNO cluster VLAN gateway
ping -c 3 192.168.51.1

# DNS forwarding (should return public IP from 8.8.8.8 — not internal VIPs)
dig @192.168.50.1 google.com +short
dig @192.168.51.1 google.com +short

# Verify libvirt networks are active
virsh net-list --all
```

Expected libvirt network output:

```
Name      State    Autostart   Persistent
--------------------------------------------
1924      active   yes         yes
1925      active   yes         yes
1926      active   yes         yes
default   active   yes         yes
```

## Step 10 — Proceed with Cluster Topology Selection

Once VyOS is configured, run the topology auto-selection:

```bash
./hack/select-cluster-topology.sh
```

This sets `examples/ibm-cloud-active` to either `ibm-cloud-converged` or `ibm-cloud-sno` based on available host resources.

## Troubleshooting

### Console shows blank screen after boot

Click inside the console and press **Enter**. If still blank, use Cockpit Power Off → Run cycle.

### VyOS VM not in Cockpit VM list

```bash
virsh list --all   # Check if VM exists
virsh start vyos-router   # Start if stopped
```

### DNS not forwarding from cluster VMs

```bash
# SSH into VyOS (after setting up SSH in Step 7)
ssh vyos@192.168.50.1

# Check DNS service
show service dns forwarding

# Restart DNS if needed
sudo systemctl restart vyos-dns-forwarding
```

### Networks reachable from VyOS but not from KVM host

The KVM host accesses VLAN networks via the libvirt bridge, not through VyOS. Check:

```bash
ip route show | grep 192.168.5
virsh net-info 1925
```

### VyOS configuration lost after reboot

You must run `save` after every `commit`. To verify config was saved:

```bash
# In VyOS
show configuration
```

## Reference: Full VyOS Configuration Summary

After completing all steps, your VyOS configuration summary should look like:

```
interfaces:
  ethernet:
    eth0: { address: dhcp, description: Libvirt-default-uplink }
    eth1: { address: 192.168.49.1/24, description: VLAN-1924-management }
    eth2: { address: 192.168.50.1/24, description: VLAN-1925-converged }
    eth3: { address: 192.168.51.1/24, description: VLAN-1926-sno }

service:
  dns:
    forwarding:
      listen-address: [192.168.49.1, 192.168.50.1, 192.168.51.1]
      name-server: [1.1.1.1, 8.8.8.8]
  ssh:
    port: 22

nat:
  source:
    rule 100: { outbound: eth0, source: 192.168.49.0/24, translation: masquerade }
    rule 101: { outbound: eth0, source: 192.168.50.0/24, translation: masquerade }
    rule 102: { outbound: eth0, source: 192.168.51.0/24, translation: masquerade }
```
