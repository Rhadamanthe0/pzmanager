# Quick Start Guide

Quick installation of Project Zomboid server in 10 minutes.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Server Configuration](#server-configuration)
- [Commands](#commands)
- [Discord (Optional)](#discord-optional)
- [Automations](#automations)
- [Common Issues](#common-issues)
- [Resources](#resources)

## Prerequisites

- **OS**: Debian 12 or Ubuntu 22.04+
- **Access**: Root/sudo
- **RAM**: 4GB minimum
- **Disk**: 20GB+ free

**Ports**: 16261/UDP, 16262/UDP, 8766/UDP, 27015/TCP (automatically opened)

## Installation

⚠️ **Installation as root** - operation as pzuser after installation

```bash
# Clone
git clone https://github.com/YOUR_USERNAME/pzmanager.git /opt/pzmanager
cd /opt/pzmanager

# If git missing
apt install -y git

# System configuration (creates pzuser, firewall, packages)
./scripts/install/setupSystem.sh

# Sudo permissions
visudo -cf data/setupTemplates/pzuser-sudoers && \
cp data/setupTemplates/pzuser-sudoers /etc/sudoers.d/pzuser

# Final installation
mv /opt/pzmanager /home/pzuser/
chown -R pzuser:pzuser /home/pzuser/pzmanager
cp /home/pzuser/pzmanager/data/setupTemplates/pzuser-crontab /etc/cron.d/pzuser
/home/pzuser/pzmanager/scripts/install/configurationInitiale.sh zomboid
```

**Total duration**: 15-35 minutes (depending on connection)

**Installed version**: Project Zomboid Build 41 (branch `legacy_41_78_7`)

**Automatically applied optimizations**:
- ZGC (Java Garbage Collector)
- 8GB RAM by default

---

**Startup** (as pzuser):
```bash
su - pzuser
cd /home/pzuser/pzmanager
pzm server start
pzm server status
```

**Expected**:
```
Status: RUNNING
Active since: [timestamp]
Control pipe: Available
Recent logs:
[...] RCON: listening on port 27015
```

✅ Server operational!

## Server Configuration

```bash
nano /home/pzuser/pzmanager/Zomboid/Server/servertest.ini
```

Important parameters:
```ini
ServerName=MyServer
PublicName=My Public Server
Password=                    # Empty = public
AdminPassword=CHANGEME       # ⚠️ CHANGE IT!
MaxPlayers=32
PauseEmpty=true
```

Apply: `pzm server restart 5m`

Complete documentation: [SERVER_CONFIG.md](SERVER_CONFIG.md)

## Commands

```bash
pzm server start              # Start
pzm server stop [delay]       # Stop (default: 2m warning)
pzm server restart [delay]    # Restart
pzm server status             # Status + logs
```

**Delays**: `30m`, `15m`, `5m`, `2m`, `30s`, `now`

Examples:
```bash
pzm server restart 30m    # Warn 30min before
pzm server stop now       # Immediate stop
```

## Discord (Optional)

Configuration: [CONFIGURATION.md - Discord](CONFIGURATION.md#notifications-discord)

## Automations

**Daily maintenance (4:30 AM)**:
- Server shutdown (30m warning)
- Backup rotation
- System updates (apt + Java + SteamCMD)
- Complete backup
- Reboot

**Hourly backups (:14)**:
- Incremental Zomboid data backup
- 14-day retention (configurable in .env)

## Common Issues

**Server won't start**
```bash
sudo -u pzuser systemctl --user status zomboid.service
sudo -u pzuser journalctl --user -u zomboid.service -n 50
```

**Cannot connect**
```bash
sudo ufw status    # Check firewall
pzm server status    # Check server active
```

**Backups not working**
```bash
cat /etc/cron.d/pzuser    # Check scheduling
pzm backup create  # Manual test
```

Complete documentation: [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

## Resources

- [INSTALLATION.md](INSTALLATION.md) - Detailed installation
- [CONFIGURATION.md](CONFIGURATION.md) - .env variables, backups
- [SERVER_CONFIG.md](SERVER_CONFIG.md) - PZ server configuration
- [ADVANCED.md](ADVANCED.md) - Optimizations, RCON
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Troubleshooting
- [PZ Wiki](https://pzwiki.net/wiki/Dedicated_Server) - Official documentation
