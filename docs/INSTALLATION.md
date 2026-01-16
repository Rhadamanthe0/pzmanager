# Installation Guide

Detailed installation of pzmanager - Project Zomboid Server Manager.

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

## Installation

### One-Command Install (Recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/pzmanager/main/install.sh | sudo bash
```

**Duration**: 10-30 minutes

The installer automatically:
1. Updates system packages
2. Creates `pzuser` account
3. Configures firewall
4. Installs SteamCMD, Java 25, dependencies
5. Downloads Project Zomboid server (~1-2GB)
6. Sets up systemd services and timers
7. Configures sudo permissions

### Manual Installation

<details>
<summary>Click to expand manual steps</summary>

```bash
# As root
apt update && apt upgrade -y
apt install -y git

# Clone
git clone https://github.com/YOUR_USERNAME/pzmanager.git /opt/pzmanager
cd /opt/pzmanager

# System setup
./scripts/install/setupSystem.sh

# Sudo permissions
visudo -cf data/setupTemplates/pzuser-sudoers && \
cp data/setupTemplates/pzuser-sudoers /etc/sudoers.d/pzuser

# Move to home
mv /opt/pzmanager /home/pzuser/
chown -R pzuser:pzuser /home/pzuser/pzmanager

# Install server
/home/pzuser/pzmanager/scripts/install/configurationInitiale.sh zomboid
```

</details>

## First Start

```bash
su - pzuser
pzm server start
pzm server status
```

First startup takes 2-5 minutes (world generation).

Expected output:
```
Status: RUNNING
Active since: [timestamp]
Control pipe: Available
```

## Post-Installation

### Server Configuration

```bash
nano ~/pzmanager/Zomboid/Server/servertest.ini
```

**Important**: Change `AdminPassword`!

Apply changes: `pzm server restart 5m`

See [SERVER_CONFIG.md](SERVER_CONFIG.md) for all options.

### Discord Notifications (Optional)

```bash
nano ~/pzmanager/scripts/.env
```

Add:
```
DISCORD_WEBHOOK="https://discord.com/api/webhooks/..."
```

See [CONFIGURATION.md](CONFIGURATION.md) for all variables.

## Restore from Backup

### Complete Restore

```bash
sudo ./scripts/install/configurationInitiale.sh restore /path/to/fullBackup
```

### Data Only Restore

```bash
pzm backup restore data/dataBackups/backup_YYYY-MM-DD_HHhMMmSSs
```

## Uninstallation

```bash
# Stop and disable
su - pzuser
pzm server stop now
systemctl --user disable zomboid.service pz-backup.timer pz-modcheck.timer pz-maintenance.timer
exit

# Remove configuration
sudo rm /etc/sudoers.d/pzuser

# Remove installation
sudo rm -rf /home/pzuser/pzmanager

# (Optional) Remove user
sudo userdel -r pzuser
```

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

**Server won't start**:
```bash
journalctl --user -u zomboid.service -n 50
```

**Cannot connect**:
```bash
sudo ufw status
pzm server status
```
