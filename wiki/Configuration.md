# Configuration Reference

A `powerstoreplugin:` storage entry in `/etc/pve/storage.cfg` accepts the following parameters.

---

## Required Parameters

| Parameter | Type | Description |
|---|---|---|
| `api_host` | string | Hostname or IP address of the PowerStore management interface |
| `api_password` | string | Management user password |
| `pool_id` | string (UUID) | PowerStore storage pool ID — all volumes are created here |

### Finding your pool_id

```bash
# Query PowerStore REST API directly
curl -sk -u admin:PASSWORD \
  "https://POWERSTORE-IP/api/rest/storage_pool?select=id,name" \
  | python3 -m json.tool
```

Or navigate to **PowerStore Manager → Storage → Storage Pools** and copy the pool UUID from the URL.

---

## Optional Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `api_user` | string | `admin` | Management username |
| `api_port` | integer | `443` | HTTPS API port |
| `api_insecure` | boolean | `0` | Skip TLS certificate verification. Only for self-signed certs in test environments |
| `portal` | string | *(api_host)* | iSCSI discovery portal IP or hostname. Strongly recommended to set explicitly |
| `transport_mode` | enum | `iscsi` | Storage transport. Currently only `iscsi` is supported |
| `host_name_prefix` | string | `pve-` | Prefix for PowerStore Host entries auto-created by the plugin |
| `chap_user` | string | — | CHAP username for iSCSI authentication |
| `chap_password` | string | — | CHAP password for iSCSI authentication |
| `performance_policy_id` | string (UUID) | — | PowerStore performance policy to assign to new volumes |
| `debug` | integer 0–2 | `0` | Log verbosity: 0=errors only, 1=informational, 2=verbose (API calls) |

---

## Standard PVE Storage Parameters

These are standard Proxmox storage parameters accepted by all plugins:

| Parameter | Description |
|---|---|
| `content images` | Content types stored here. Only `images` is supported |
| `shared 1` | Mark as shared storage (required for cluster live migration) |
| `nodes node1,node2` | Restrict storage to specific cluster nodes. Omit for all nodes |
| `disable 1` | Disable this storage without removing the entry |
| `maxfiles N` | Maximum number of backups to keep (not used for block storage) |

---

## Example Configurations

### Minimal

```
powerstoreplugin: ps-prod
        api_host        192.168.10.50
        api_password    MyPassword
        pool_id         a1b2c3d4-e5f6-7890-abcd-ef1234567890
        portal          192.168.10.51
        content         images
```

### Full — with CHAP and debug logging

```
powerstoreplugin: ps-prod
        api_host              192.168.10.50
        api_user              admin
        api_password          MyPassword
        pool_id               a1b2c3d4-e5f6-7890-abcd-ef1234567890
        api_port              443
        api_insecure          0
        portal                192.168.10.51
        transport_mode        iscsi
        host_name_prefix      pve-
        chap_user             chapuser
        chap_password         chapSecret123
        performance_policy_id 00000000-0000-0000-0000-000000000001
        debug                 1
        content               images
        shared                1
```

### Multiple pools on the same array

```
powerstoreplugin: ps-fast
        api_host        192.168.10.50
        api_password    MyPassword
        pool_id         <UUID-of-NVMe-pool>
        portal          192.168.10.51
        content         images

powerstoreplugin: ps-capacity
        api_host        192.168.10.50
        api_password    MyPassword
        pool_id         <UUID-of-SAS-pool>
        portal          192.168.10.51
        content         images
```

---

## PowerStore Host Auto-registration

When a volume is attached to a Proxmox node for the first time, the plugin automatically:

1. Reads the node's iSCSI IQN from `/etc/iscsi/initiatorname.iscsi`
2. Checks whether a Host with that IQN already exists on PowerStore
3. Creates a Host entry (name: `<host_name_prefix><hostname>`) if needed

This means you do **not** need to pre-register hosts in PowerStore Manager. The plugin handles it transparently on first use.

If you use CHAP, set `chap_user` and `chap_password` — these are applied when the Host entry is created. Changing them later requires updating the Host entry on PowerStore manually.

---

## iSCSI Portal vs Management IP

`api_host` is used for REST API calls (HTTPS port 443).  
`portal` is used for iSCSI target discovery (TCP port 3260).

These are often the same IP, but on production deployments the management interface and iSCSI data interfaces are typically on separate networks. Set `portal` to the data-network IP of the PowerStore for correct traffic separation.
