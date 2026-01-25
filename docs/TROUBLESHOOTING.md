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
sudo -u pzuser systemctl --user status zomboid.service
sudo -u pzuser journalctl --user -u zomboid.service -n 100
```

### Common Causes

**Java not found**
```bash
# Check Java symlink
ls -la /home/pzuser/pzmanager/data/pzserver/jre64

# If missing or broken, recreate
sudo rm -rf /home/pzuser/pzmanager/data/pzserver/jre64
sudo ln -s /usr/lib/jvm/java-25-openjdk-amd64 /home/pzuser/pzmanager/data/pzserver/jre64
```

**Permission denied**
```bash
# Check permissions
ls -la /home/pzuser/pzmanager/data/pzserver/

# Fix if necessary
sudo chown -R pzuser:pzuser /home/pzuser/pzmanager
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

### When to Use

Ultimate solution when:
- Irreparable world corruption
- Complete rules/mods change
- Persistent degraded performance
- Starting from scratch

### Complete Reset (new world)

```bash
./scripts/admin/resetServer.sh
```

Creates completely clean server, new world.

### Reset with Data Preservation

```bash
./scripts/admin/resetServer.sh --keep-whitelist
```

New world but preserves:
- Player whitelist (except admin)
- Server configuration (servertest.ini)
- Game rules (servertest_SandboxVars.lua)

### Automatic Process

1. **Confirmation**: Type `RESET` in uppercase
2. **Backup**: Saved to `/home/pzuser/OLD/Zomboid_OLD_TIMESTAMP/`
3. **Initial setup**:
   - Enter admin password (twice)
   - When "If the server hangs here, set UPnP=false" → **Ctrl+C**
4. **Restoration** (if --keep-whitelist): Whitelist and configs
5. **Startup**: New server ready

**⚠️ Warning**: Deletes all current data! Automatic backup created.

Complete documentation: [ADVANCED.md - Complete Server Reset](ADVANCED.md#reset-complet-serveur)

## Backups Not Working

### Check Timers

```bash
systemctl --user list-timers
# Should show pz-backup.timer, pz-maintenance.timer, pz-modcheck.timer
```

**Re-enable timers**:
```bash
systemctl --user enable --now pz-backup.timer pz-maintenance.timer pz-modcheck.timer
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
ls -la /home/pzuser/pzmanager/data/dataBackups/
```

### Disk Space

```bash
du -sh /home/pzuser/pzmanager/data/dataBackups/*
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
ls -lt /home/pzuser/pzmanager/data/fullBackups/

# Restore everything
sudo ./scripts/install/configurationInitiale.sh restore /home/pzuser/pzmanager/data/fullBackups/2026-01-11_04-30
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
sudo chown -R pzuser:pzuser /home/pzuser/pzmanager

# Executable scripts
chmod +x /home/pzuser/pzmanager/scripts/*.sh

# SSH (if configured)
chmod 700 /home/pzuser/.ssh
chmod 600 /home/pzuser/.ssh/* 2>/dev/null
```

### Invalid Sudoers

```bash
# Check file
sudo visudo -cf /home/pzuser/pzmanager/data/setupTemplates/pzuser-sudoers

# Reinstall if OK
sudo cp /home/pzuser/pzmanager/data/setupTemplates/pzuser-sudoers /etc/sudoers.d/pzuser
sudo chmod 440 /etc/sudoers.d/pzuser
```

## Insufficient Disk Space

### Identify Usage

```bash
du -sh /home/pzuser/pzmanager/*
du -sh /home/pzuser/pzmanager/data/*
```

### Clean Backups

```bash
# Manually delete old backups
rm -rf /home/pzuser/pzmanager/data/dataBackups/backup_YYYY-MM-DD*
rm -rf /home/pzuser/pzmanager/data/fullBackups/YYYY-MM-DD*

# Or reduce retention
nano scripts/.env
# Modify: BACKUP_RETENTION_DAYS=7
```

### Clean Logs

```bash
# Delete old logs
find /home/pzuser/pzmanager/scripts/logs -type f -mtime +7 -delete
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

### Java Heap Too Small

```bash
# Edit service
nano ~/.config/systemd/user/zomboid.service

# Modify under [Service]:
Environment="JAVA_OPTS=-Xms4g -Xmx8g -XX:+UseZGC"

# Reload
systemctl --user daemon-reload
pzm server restart 5m
```

### Optimize Garbage Collector

For servers > 16 players, use ZGC:
```bash
Environment="JAVA_OPTS=-Xms4g -Xmx8g -XX:+UseZGC -XX:ZCollectionInterval=30"
```

## Getting Help

If the issue persists:

1. **Check logs**: `pzm server status`
2. **Consult docs**: [QUICKSTART.md](QUICKSTART.md), [CONFIGURATION.md](CONFIGURATION.md)
3. **Open an issue** on GitHub with:
   - OS version (Debian/Ubuntu)
   - Relevant logs
   - Configuration (.env without secrets)
   - Steps to reproduce the issue
