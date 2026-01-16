# Installation Guide

Detailed installation of pzmanager - Project Zomboid Server Manager.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Installation](#quick-installation)
- [Detailed Installation](#detailed-installation)
- [Post-installation](#post-installation)
- [Restore from Backup](#restore-from-backup)
- [Troubleshooting](#troubleshooting)
- [Uninstallation](#uninstallation)
- [Resources](#resources)

## Prerequisites

### System
- **Debian 12** (Bookworm) or **Ubuntu 22.04 LTS+**
- Fresh installation recommended

### Hardware
- **CPU**: 2+ cores
- **RAM**: 4GB minimum, 8GB recommended
- **Disk**: 20GB+ free (SSD recommended)

### Network
Required ports (automatically opened):
- **16261/UDP** - Main game
- **16262/UDP** - Secondary game
- **8766/UDP** - RCON
- **27015/TCP** - Steam query
- **22/TCP** - SSH (management)

### Dependencies
Automatically installed:
- rsync, unzip, ufw
- steamcmd
- openjdk-*-jre-headless

## Quick Installation

See [QUICKSTART.md](QUICKSTART.md) for condensed version.

## Detailed Installation

⚠️ **Installation as root** - operation as pzuser after installation

### 1. System Update

```bash
apt update && apt upgrade -y
```

### 2. Clone and Configure

```bash
git clone https://github.com/YOUR_USERNAME/pzmanager.git /opt/pzmanager
cd /opt/pzmanager

# If git missing
apt install -y git
```

### 3. System Configuration

```bash
./scripts/install/setupSystem.sh
```

**Actions**:
- Creates pzuser user
- Installs rsync, unzip, ufw
- Configures firewall (ports + default rules)
- Enables firewall

**Verification**:
```bash
id pzuser       # User exists
ufw status      # Firewall active
```

### 4. Sudo Permissions

```bash
visudo -cf data/setupTemplates/pzuser-sudoers && \
cp data/setupTemplates/pzuser-sudoers /etc/sudoers.d/pzuser

# Verify
sudo -u pzuser sudo -l
```

### 5. Final Installation

```bash
mv /opt/pzmanager /home/pzuser/
chown -R pzuser:pzuser /home/pzuser/pzmanager
cp /home/pzuser/pzmanager/data/setupTemplates/pzuser-crontab /etc/cron.d/pzuser
/home/pzuser/pzmanager/scripts/install/configurationInitiale.sh zomboid
```

**Duration**: 10-30 minutes (download ~1-2GB)

**Installed version**: Project Zomboid Build 41 (branch `legacy_41_78_7`)

**Automatically applied optimizations**:
- ZGC (Java Garbage Collector)
- 8GB RAM by default (modifiable via `pzm config ram <value>`)

**Verification**:
```bash
ls -la /home/pzuser/pzmanager/data/pzserver/
sudo -u pzuser systemctl --user status zomboid.service
```

### 6. Server Startup

⚠️ **As pzuser for operation**

```bash
su - pzuser
cd /home/pzuser/pzmanager
pzm server start
pzm server status
```

First startup: 2-5 minutes (world generation).

**Expected**:
```
Status: RUNNING
Active since: [timestamp]
Control pipe: Available
Recent logs:
[...] RCON: listening on port 27015
```

## Post-installation

All post-installation commands are executed as **pzuser** (`su - pzuser`).

### .env Configuration (optional)

`.env` file automatically created from `.env.example` on first run.

To customize: `nano /home/pzuser/pzmanager/scripts/.env`

Useful variables:
- `JAVA_VERSION`: Java version (default: 25)
- `STEAM_BETA_BRANCH`: PZ branch (default: legacy_41_78_7)
- `BACKUP_RETENTION_DAYS`: Backup retention (default: 30)
- `DISCORD_WEBHOOK`: Discord notifications

Documentation: [CONFIGURATION.md](CONFIGURATION.md)

### Server Configuration

File: `/home/pzuser/pzmanager/Zomboid/Server/servertest.ini`

Parameters to modify:
- `AdminPassword`: ⚠️ MUST CHANGE!
- `PublicName`: Name displayed in server list
- `Password`: Server password (empty = public)

**Apply**: `pzm server restart 2m`

Documentation: [SERVER_CONFIG.md](SERVER_CONFIG.md)

### Admins and Whitelist

- **Admins**: [SERVER_CONFIG.md - Admins](SERVER_CONFIG.md#gestion-admins)
- **Whitelist**: [SERVER_CONFIG.md - Whitelist](SERVER_CONFIG.md#gestion-whitelist)

### Discord (optional)

Configuration: [CONFIGURATION.md - Discord](CONFIGURATION.md#notifications-discord)

### Remote Maintenance (Optional)

**Generate key (local machine)**:
```bash
ssh-keygen -t ed25519 -f ~/.ssh/pz_maintenance
```

**Add to server**:
```bash
nano ~/.ssh/authorized_keys

# Add
command="/home/pzuser/pzmanager/scripts/admin/performFullMaintenance.sh $SSH_ORIGINAL_COMMAND",no-port-forwarding,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAA...
```

**Use**:
```bash
ssh -i ~/.ssh/pz_maintenance pzuser@SERVER_IP 30m
```

Documentation: [ADVANCED.md](ADVANCED.md)

## Restore from Backup

### Complete Restore (system + data)

```bash
sudo ./scripts/install/configurationInitiale.sh restore /home/pzuser/pzmanager/data/fullBackups/YYYY-MM-DD_HH-MM
```

Restores:
- System configuration (crontab, sudoers)
- SSH keys, systemd services
- Scripts and .env
- Latest Zomboid backup (auto-decompressed)

### Zomboid Data Only Restore

```bash
./scripts/backup/restoreZomboidData.sh data/dataBackups/backup_YYYY-MM-DD_HHhMMmSSs
```

Restores only game data (Saves, db, Server).
Creates safety backup before overwriting.

Documentation: [TROUBLESHOOTING.md - Restore Zomboid Data](TROUBLESHOOTING.md#restaurer-données-zomboid)

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for complete guide.

**Common issues**:

**Server won't start**
```bash
sudo -u pzuser systemctl --user status zomboid.service
sudo -u pzuser journalctl --user -u zomboid.service -n 100
```

**Cannot connect**
```bash
sudo ufw status                    # Check firewall
sudo netstat -tulpn | grep java    # Check port listening
```

**Backups not working**
```bash
cat /etc/cron.d/pzuser       # Check scheduling
pzm backup create  # Manual test
```

## Uninstallation

```bash
# 1. Stop server
sudo su - pzuser
pzm server stop now
exit

# 2. Disable service
sudo -u pzuser systemctl --user disable zomboid.service
sudo -u pzuser systemctl --user stop zomboid.service

# 3. Remove crontab
sudo rm /etc/cron.d/pzuser

# 4. Remove sudoers
sudo rm /etc/sudoers.d/pzuser

# 5. Remove installation (⚠️ deletes all data!)
sudo rm -rf /home/pzuser/pzmanager

# 6. (Optional) Remove user
sudo userdel -r pzuser
```

## Resources

- [QUICKSTART.md](QUICKSTART.md) - Quick installation
- [CONFIGURATION.md](CONFIGURATION.md) - .env configuration, backups
- [SERVER_CONFIG.md](SERVER_CONFIG.md) - PZ server configuration
- [ADVANCED.md](ADVANCED.md) - Optimizations, RCON
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Troubleshooting
- [PZ Wiki](https://pzwiki.net/wiki/Dedicated_Server) - Official documentation
