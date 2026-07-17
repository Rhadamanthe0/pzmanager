# Troubleshooting Guide

Guide to resolving common issues with pzmanager.

## Table of Contents

- [Server Won't Start](#server-wont-start)
- [Cannot Connect](#cannot-connect)
- [Server Crashes Regularly](#server-crashes-regularly)
- [Complete Server Reset](#complete-server-reset)
- [Backups Not Working](#backups-not-working)
- [Restore Zomboid Data](#restore-zomboid-data)
- [Discord Notifications Failing](#discord-notifications-failing)
- [Permission Errors](#permission-errors)
- [Insufficient Disk Space](#insufficient-disk-space)
- [Performance Issues](#performance-issues)
- [Getting Help](#getting-help)

## Server Won't Start

### Check Service Status

```bash
# En tant que l'utilisateur du serveur (pzuser par défaut)
systemctl --user status zomboid.service
journalctl --user -u zomboid.service -n 100
```

### Common Causes

**Java not found**
```bash
# B42 uses its own embedded JRE in data/pzserver/jre64/
# If missing, re-validate the server installation:
pzm admin maintenance now
```

**Permission denied**
```bash
# Check permissions
ls -la ~/pzmanager/data/pzserver/

# Fix if necessary
sudo chown -R $USER:$USER ~/pzmanager
```

**Port already in use**
```bash
# Check ports
sudo netstat -tulpn | grep 16261

# If occupied, kill conflicting process
sudo kill <PID>
```

## Cannot Connect

### Check Firewall

```bash
sudo ufw status verbose
# Should show: 16261/udp, 16262/udp, 8766/udp, 27015/tcp ALLOW
```

**Open ports manually**
```bash
sudo ufw allow 16261/udp
sudo ufw allow 16262/udp
sudo ufw allow 8766/udp
sudo ufw allow 27015/tcp
```

### Check Server Listening

```bash
sudo netstat -tulpn | grep java
# Should show java on ports 16261, 8766, 27015
```

### External Network Test

From another computer:
```bash
nc -vuz YOUR_SERVER_IP 16261
```

### Public Server

- Check NAT/port forwarding on your router
- Check firewall rules from your hosting provider (AWS, OVH, etc.)

### Private Server

- Use direct IP in Project Zomboid
- No need to be in the server browser

## Server Crashes Regularly

### Check Resources

```bash
# Available RAM
free -h

# Disk space
df -h

# CPU load
top
```

### Common Causes

**Insufficient RAM** (< 4GB)
- Reduce MaxPlayers in servertest.ini
- Increase server RAM
- Disable mods

**Full Disk** (< 10GB free)
- Reduce backup retention
- Manually clean old backups

**Too Many Mods**
- Disable mods one by one to identify the issue
- Check mod compatibility

### Analyze Crashes

```bash
# Complete logs of last crash
pzm server status

# System logs
sudo journalctl -xe
```

## Complete Server Reset

Last resort for irreparable world corruption, a complete rules/mods change, or
persistent degraded performance that nothing else fixes.

```bash
pzm admin reset
```

> ⚠️ **Deletes all current data, with no confirmation prompt.** A backup is
> written to `~/OLD/Zomboid_OLD_TIMESTAMP/` first, and `--keep-config` /
> `--keep-whitelist` preserve configs and player access.

Procedure and options: [ADVANCED.md — Complete Server Reset](ADVANCED.md#complete-server-reset).

## Player Character Won't Load

Symptom: a player connects and is told *"the server cannot load player data"* / asked
to **recreate** a character. This is usually a **load** failure (the character is still
in `players.db`), most often after a mod that adds character data was removed — see the
mod gotcha in [CLAUDE.md](../CLAUDE.md). First, restore the missing mod and restart.

If the character row was actually lost/overwritten, restore just that one character
from a backup (no full-world rollback):

```bash
pzm server stop 2m --reason "Restauration perso"   # server MUST be stopped
pzm backup restore-character <name> backup_YYYY-MM-DD_HHhMMmSSs
pzm server start
```

`<backup>` is required (the folder name under `data/dataBackups/`, or a full path). The
player's current character is **overwritten** by the backup's; the stop already makes a
backup, so you can roll back if needed. See [USAGE.md](USAGE.md#backups).

## Backups Not Working

### Check Timers

```bash
systemctl --user list-timers
# Should show pz-backup, pz-maintenance, pz-modcheck, pz-heapcheck, pz-creation-date-init
```

**Re-enable timers**:
```bash
systemctl --user enable --now pz-backup.timer pz-maintenance.timer pz-modcheck.timer pz-heapcheck.timer pz-creation-date-init.timer
```

### Check Timer Logs

```bash
journalctl --user -u pz-backup.service -n 20
```

### Manual Test

```bash
# Test hourly backup
pzm backup create

# Check result
ls -la ~/pzmanager/data/dataBackups/
```

### Disk Space

```bash
du -sh ~/pzmanager/data/dataBackups/*
```

If too large, reduce BACKUP_RETENTION_DAYS in .env.

## Restore Zomboid Data

### Targeted Restoration (game data only)

**When to use**: Corrupted world, rollback to old save, test old version.

```bash
# List available backups
./scripts/backup/restoreZomboidData.sh

# Restore specific backup
./scripts/backup/restoreZomboidData.sh data/dataBackups/backup_2026-01-11_14h15m00s

# Restore latest backup
./scripts/backup/restoreZomboidData.sh data/dataBackups/latest
```

**How it works**:
- Creates safety backup of current Zomboid (`ZomboidBROKEN_TIMESTAMP`)
- Restores only Zomboid data (Saves, db, Server)
- Preserves system configuration and scripts

**Apply**:
```bash
pzm server restart 2m
```

### Complete Restoration (system + data)

**When to use**: System crash, server migration, complete reconfiguration.

```bash
# List complete backups
ls -lt ~/pzmanager/data/fullBackups/

# Restore everything
sudo ./scripts/install/configurationInitiale.sh restore ~/pzmanager/data/fullBackups/2026-01-11_04-30
```

**Restores**: Sudoers, SSH, systemd services/timers, scripts, .env, Zomboid data.

### Comparison

| Type | Scope | Safety Backup | Usage |
|------|-------|---------------|-------|
| `restoreZomboidData.sh` | Game data | ✅ Yes | World/save issue |
| `configurationInitiale.sh restore` | Complete system | ❌ No | System crash, migration |

## Discord Notifications Failing

### Manual Test

```bash
./scripts/internal/sendDiscord.sh "Test message"
```

**If no message received**:
1. Check webhook URL in .env
2. Check that webhook still exists in Discord
3. Check that channel hasn't been deleted

### Check Configuration

```bash
cat scripts/.env | grep DISCORD_WEBHOOK
# Should not be empty if Discord enabled
```

### Invalid Webhook

- Recreate webhook in Discord (Server Settings → Integrations → Webhooks)
- Copy new URL to .env

## Permission Errors

### Reset Permissions

```bash
# Entire project
sudo chown -R $USER:$USER ~/pzmanager

# Executable scripts
chmod +x ~/pzmanager/scripts/*.sh

# SSH (if configured)
chmod 700 ~/.ssh
chmod 600 ~/.ssh/* 2>/dev/null
```

### Invalid Sudoers

```bash
# Check file
# Le sudoers est maintenant installé automatiquement par setupSystem.sh
# Pour réinstaller manuellement :
sudo ~/pzmanager/scripts/install/setupSystem.sh $USER
```

## Insufficient Disk Space

### Identify Usage

```bash
du -sh ~/pzmanager/*
du -sh ~/pzmanager/data/*
```

### Clean Backups

```bash
# Manually delete old backups
rm -rf ~/pzmanager/data/dataBackups/backup_YYYY-MM-DD*
rm -rf ~/pzmanager/data/fullBackups/YYYY-MM-DD*

# Or reduce retention
nano scripts/.env
# Modify: BACKUP_RETENTION_DAYS=7
```

### Clean Logs

```bash
# Delete old logs
find ~/pzmanager/scripts/logs -type f -mtime +7 -delete
```

### Purge APT

```bash
sudo apt-get autoclean
sudo apt-get autoremove
```

## Performance Issues

### Significant Lag

**Reduce save frequency**
```ini
# In Zomboid/Server/servertest.ini
SaveWorldEveryMinutes=60  # Instead of 30
```

**Limit players**
```ini
MaxPlayers=16  # Instead of 32
```

**Enable pause if empty**
```ini
PauseEmpty=true
```

### Java Heap Too Small (OutOfMemoryError)

JVM args live in `ProjectZomboid64.json` (the `vmArgs` array), not in the
systemd service. They are written by `scripts/internal/configureJvm.sh`, which
re-applies them after every SteamCMD update — edit the script, not the JSON
(a manual JSON edit is overwritten by the nightly maintenance):

```bash
# Simplest: set the heap size in .env, then apply and restart
nano ~/pzmanager/scripts/.env        # uncomment / set: export PZ_XMX_GB=8
~/pzmanager/scripts/internal/configureJvm.sh
pzm server restart 5m
```

There is no `-Xms` (removed); `-Xmx` defaults to half of physical RAM unless
`PZ_XMX_GB` is set. Full model: [ADVANCED.md](ADVANCED.md#ram--jvm-configuration).

> ⚠️ Keep `-Xmx` at roughly half of physical RAM. PZ B42 modded uses 6-9 GB of
> native memory *on top of* the Java heap, and with `AlwaysPreTouch` the whole
> `Xmx` is resident from boot; an `Xmx` close to total RAM will exhaust the
> machine and trigger a brutal Linux OOM-kill instead of a clean Java OOM.
> Do **not** add a cgroup `MemoryMax`/`MemoryHigh` — it throttles/crashes PZ at
> the cap.

> **Note:** a `java.lang.OutOfMemoryError: Java heap space` after ~15 h of uptime
> is expected on a large explored map — the heap fills with live map cells that
> nothing can free at runtime. pzmanager restarts the server automatically before
> this (see [ADVANCED.md](ADVANCED.md#memory-driven-restart-why-the-server-restarts-on-its-own)).
> Raising `Xmx` only delays it.

## Getting Help

If the issue persists:

1. **Check logs**: `pzm server status`
2. **Consult docs**: [QUICKSTART.md](QUICKSTART.md), [CONFIGURATION.md](CONFIGURATION.md)
3. **Open an issue** on GitHub with:
   - OS version (Debian/Ubuntu)
   - Relevant logs
   - Configuration (.env without secrets)
   - Steps to reproduce the issue
