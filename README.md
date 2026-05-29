# powerstore-pve-plugin

**Proxmox VE Storage Plugin for Dell PowerStore appliances.**

Provides native block storage integration between Proxmox VE clusters and Dell PowerStore arrays over iSCSI. Volumes are created on-demand on the array and presented as raw block devices to VMs and containers.

## Features

- Automatic volume lifecycle (create, delete, resize) via PowerStore REST API
- Full snapshot support at the appliance level (instant, space-efficient)
- Volume cloning from snapshots (PowerStore CoW clone)
- Snapshot rollback
- Per-node iSCSI host registration (auto-creates Host entries using node IQN)
- CHAP authentication support
- Thin provisioning
- Live VM migration (attach/detach per-node on demand)
- Optional performance policy assignment per storage pool
- Debian packaging for easy installation and updates

## Requirements

| Component | Version |
|---|---|
| Proxmox VE | ≥ 8.0 |
| Dell PowerStore | OS 3.x or later |
| Perl | ≥ 5.20 |
| open-iscsi | any current |
| libwww-perl | any current |
| libjson-perl | any current |

## Quick Start

```bash
# 1. Install the package
dpkg -i powerstore-pve-plugin_*.deb
# OR use the interactive installer:
bash install.sh

# 2. Add a storage entry to /etc/pve/storage.cfg
powerstoreplugin: ps-prod
        api_host        192.168.10.50
        api_password    MySecret
        pool_id         a1b2c3d4-e5f6-7890-abcd-ef1234567890
        portal          192.168.10.51
        content         images

# 3. Verify
pvesm status --storage ps-prod
```

## Configuration

See [wiki/Configuration.md](wiki/Configuration.md) for all parameters.  
See [storage.cfg.example](storage.cfg.example) for annotated examples.

## Installation

See [wiki/Installation.md](wiki/Installation.md) for full installation instructions including iSCSI prerequisites.

## Troubleshooting

See [wiki/Troubleshooting.md](wiki/Troubleshooting.md).

## License

[GNU Affero General Public License v3.0 or later](LICENSE)

Compatible with the Proxmox VE AGPLv3+ system as required by [Proxmox storage plugin licensing policy](https://pve.proxmox.com/wiki/Storage_Plugin_Development#Licensing).
