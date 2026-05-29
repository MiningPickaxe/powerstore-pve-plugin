# Installation Guide

## Requirements

| Component | Minimum version |
|---|---|
| Proxmox VE | 8.0 |
| Dell PowerStore OS | 3.x |
| Perl | 5.20 |
| open-iscsi | any current |
| libwww-perl | any current |
| liblwp-protocol-https-perl | any current |
| libjson-perl | any current |
| libio-socket-ssl-perl | any current |

---

## iSCSI Prerequisites

Before installing the plugin, ensure each Proxmox node has iSCSI configured:

```bash
# Install open-iscsi
apt install open-iscsi

# Enable and start iscsid
systemctl enable --now iscsid

# Verify an initiator name exists
cat /etc/iscsi/initiatorname.iscsi
# Example: InitiatorName=iqn.1993-08.org.debian:01:abc123

# If blank, generate one:
iscsi-iname -p iqn.$(date +%Y-%m).$(hostname -d):$(hostname -s) \
    | tee /etc/iscsi/initiatorname.iscsi
systemctl restart iscsid
```

Ensure the PowerStore array's iSCSI portal IP is reachable from each Proxmox node on **port 3260 TCP**.

---

## Option A — Debian Package (recommended)

```bash
# 1. Download the latest release .deb
#    (replace with actual release URL or build from source — see below)

# 2. Install
dpkg -i powerstore-pve-plugin_1.0.0_all.deb

# 3. Verify
perl -c /usr/share/perl5/PVE/Storage/Custom/PowerStorePlugin.pm
pvesm help powerstoreplugin 2>&1 | head -5
```

---

## Option B — Interactive Installer Script

```bash
# Clone the repository
git clone https://github.com/powerstore-pve-plugin/powerstore-pve-plugin.git
cd powerstore-pve-plugin

# Run the installer
bash install.sh install

# Or use the interactive menu:
bash install.sh
```

---

## Option C — Manual Install

```bash
# 1. Install Perl dependencies
apt install -y libwww-perl liblwp-protocol-https-perl libjson-perl \
               libio-socket-ssl-perl open-iscsi

# 2. Copy plugin file
install -D -m 0644 PowerStorePlugin.pm \
    /usr/share/perl5/PVE/Storage/Custom/PowerStorePlugin.pm

# 3. Restart Proxmox services
systemctl restart pvedaemon pvestatd
```

---

## Adding a Storage Entry

After installation, add a storage entry either via the **Proxmox web UI** (*Datacenter → Storage → Add → PowerStore Plugin*) or by editing `/etc/pve/storage.cfg`:

```
powerstoreplugin: ps-prod
        api_host        192.168.10.50
        api_password    MySecret
        pool_id         a1b2c3d4-e5f6-7890-abcd-ef1234567890
        portal          192.168.10.51
        content         images
        shared          1
```

Then verify:

```bash
pvesm status --storage ps-prod
```

See [Configuration.md](Configuration.md) for all parameters.

---

## Cluster Installation

For a multi-node Proxmox cluster, the plugin file must be present on **every node** (though `storage.cfg` is shared via pmxcfs):

```bash
# Use the cluster installer (runs via SSH to each node):
bash install.sh cluster-install

# Or manually copy to each node:
for node in pve1 pve2 pve3; do
    scp PowerStorePlugin.pm root@${node}:/tmp/
    ssh root@${node} "install -D -m 0644 /tmp/PowerStorePlugin.pm \
        /usr/share/perl5/PVE/Storage/Custom/PowerStorePlugin.pm \
        && systemctl restart pvedaemon pvestatd"
done
```

---

## Building the Debian Package from Source

```bash
# Install build dependencies
apt install devscripts debhelper

# Build
bash tools/build-deb.sh
# Output in build/
```

---

## Uninstalling

```bash
# Via dpkg:
dpkg -r powerstore-pve-plugin

# Or via installer:
bash install.sh remove
```

Remove any `powerstoreplugin:` entries from `/etc/pve/storage.cfg` after removal.
