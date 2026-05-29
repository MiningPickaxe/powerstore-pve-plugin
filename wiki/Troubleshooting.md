# Troubleshooting Guide

## Log Locations

| Log | Purpose |
|---|---|
| `/var/log/syslog` | Main system log — iSCSI and plugin messages |
| `journalctl -u pvedaemon` | Proxmox daemon log |
| `journalctl -u pvestatd` | Proxmox storage status daemon |
| `journalctl -u iscsid` | iSCSI daemon |

Enable verbose plugin logging in `storage.cfg` with `debug 2`, then restart services:

```bash
systemctl restart pvedaemon pvestatd
# Trigger an operation (e.g. pvesm status), then:
grep -i powerstore /var/log/syslog | tail -50
```

---

## API Connectivity

### Cannot connect to PowerStore API

```bash
# Test HTTPS reachability
curl -vsk https://<api_host>/api/rest/login_session \
  -u admin:PASSWORD

# Expected: HTTP 200 with JSON body and DELL-EMC-TOKEN in response headers
```

**Common causes:**
- Management IP unreachable — check network route, firewall
- Wrong credentials — verify in PowerStore Manager → Users
- Certificate error with `api_insecure 0` — set `api_insecure 1` for self-signed certs (test only)

### API returns 401 Unauthorized

- Credentials wrong or the user account is locked in PowerStore Manager
- Verify the user has at least "Storage Operator" role

### API returns 403 Forbidden

- The user account lacks permission for the requested operation
- Assign "Storage Administrator" role for full functionality

---

## iSCSI Issues

### Volume activates but device does not appear

```bash
# 1. Check initiator name is configured
cat /etc/iscsi/initiatorname.iscsi

# 2. Verify iscsid is running
systemctl status iscsid

# 3. Test iSCSI discovery manually
iscsiadm -m discovery -t st -p <portal_ip>:3260

# 4. List active sessions
iscsiadm -m session

# 5. Force rescan of all sessions
iscsiadm -m session --rescan

# 6. Check if WWN device path exists
ls -la /dev/disk/by-id/wwn-0x*
```

### "No route to host" on iSCSI portal

- Confirm `portal` config param is the **data-network** IP, not the management IP
- Check firewall rules: port 3260/TCP must be open

### Stale iSCSI sessions after node reboot

```bash
# Logout all sessions
iscsiadm -m session | awk '{print $3}' | while read target; do
    iscsiadm -m node -T "$target" -u
done

# Clear persistent nodes for the PowerStore target
iscsiadm -m node | grep -i powerstore | awk '{print $2}' | while read target; do
    iscsiadm -m node -T "$target" -o delete
done

systemctl restart iscsid
```

### Multiple paths showing for same volume (multipath)

This is expected and desirable with `multipath-tools` installed. Install it:

```bash
apt install multipath-tools
systemctl enable --now multipathd
```

The plugin uses the WWN-based `/dev/disk/by-id/wwn-0x...` path, which correctly follows multipath device-mapper paths when multipath is active.

---

## Volume Operations

### `pvesm alloc` fails with "pool not found"

- Verify `pool_id` in `storage.cfg` is the correct UUID
- Query pools: `curl -sk -u admin:PASS "https://<host>/api/rest/storage_pool?select=id,name"`

### `pvesm free` fails — volume in use

```bash
# Check if volume is attached on PowerStore (mapped_volumes field)
curl -sk -u admin:PASS \
  "https://<host>/api/rest/volume?name=eq.vm-100-disk-0&select=id,name,mapped_volumes"

# Detach on PowerStore if leftover:
# POST /api/rest/volume/{id}/detach  {"host_id": "..."}
```

### Snapshot rollback fails

The plugin calls `POST /api/rest/volume/{id}/restore`. This requires the volume to be **detached** (not mapped to any host). If a VM is running, shut it down before rolling back.

---

## Host Registration

### PowerStore shows duplicate host entries

The plugin does an idempotent lookup by IQN before creating. If duplicates appeared (e.g. from manual creation), delete the extras in PowerStore Manager, keeping the one named `<host_name_prefix><hostname>`.

### Wrong host gets the volume attached

Each node registers its own host entry. If a node's IQN changed (e.g. after OS reinstall), the old host entry in PowerStore still exists. Either:
- Update the IQN in the PowerStore host entry manually, or
- Delete the old host entry so the plugin recreates it

---

## Common Error Messages

| Error | Cause | Fix |
|---|---|---|
| `Failed to connect to PowerStore API` | Network or TLS issue | See API Connectivity section |
| `Could not find storage pool` | Wrong `pool_id` | Verify UUID in PowerStore Manager |
| `Device /dev/disk/by-id/wwn-... not found after 30s` | iSCSI attach/discover timeout | Check portal reachability and iSCSI sessions |
| `Volume vm-N-disk-N already exists` | Duplicate allocation attempt | Use `pvesm list` to check existing volumes |
| `Cannot restore: volume is mapped` | Volume attached during rollback | Shut down VM first |
| `Perl syntax error in PowerStorePlugin.pm` | Corrupt install | Reinstall the package |

---

## Resetting a Stuck Volume

If a volume gets stuck in an intermediate state:

```bash
# 1. Identify the WWN
VOLNAME="vm-100-disk-0"
curl -sk -u admin:PASS \
  "https://<host>/api/rest/volume?name=eq.${VOLNAME}&select=id,name,wwn,mapped_volumes"

# 2. Remove the SCSI device from the OS (replace WWN)
echo 1 > /sys/block/sdb/device/delete   # replace sdb with actual device

# 3. Logout iSCSI session for the target
iscsiadm -m session   # find session
iscsiadm -m node -T iqn.xxx -p <portal>:3260 --logout

# 4. Re-activate via pvesm
pvesm activate ps-prod:${VOLNAME}
```

---

## Filing a Bug Report

When opening an issue include:

- Output of `pvesm status --storage <storage-id>`
- Output of `perl -c /usr/share/perl5/PVE/Storage/Custom/PowerStorePlugin.pm`
- Relevant syslog lines (`grep -i powerstore /var/log/syslog | tail -100`)
- PowerStore OS version (`curl -sk -u admin:PASS https://<host>/api/rest/software_installed?select=release_version`)
- Plugin version (`grep VERSION /usr/share/perl5/PVE/Storage/Custom/PowerStorePlugin.pm`)
