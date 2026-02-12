# Quick Start Guide

Get your Project Zomboid server running in 10 minutes.

## Prerequisites

- **OS**: Debian 12 or Ubuntu 22.04+
- **RAM**: 4GB minimum (8GB recommended)
- **Disk**: 20GB+ free
- **Access**: Root/sudo

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/pzmanager/main/install.sh | sudo bash
```

**Duration**: 10-30 minutes

The installer will:
1. Create a dedicated user account (`pzuser` by default)
2. Configure firewall (ports configurable via `PZ_PORT_*` in `.env`)
3. Install SteamCMD, Java 25, dependencies
4. Download Project Zomboid server
5. Set up systemd services and timers
6. Create `admin` user with random password (save it!)

For multiple servers, use a custom username:
```bash
curl -fsSL ... | sudo PZ_USER=pzuser42 bash
```

<details>
<summary>Manual installation (advanced)</summary>

```bash
# As root
apt update && apt upgrade -y
apt install -y git

# Clone
git clone https://github.com/YOUR_USERNAME/pzmanager.git /opt/pzmanager
cd /opt/pzmanager

# System setup (username as argument, default: pzuser)
./scripts/install/setupSystem.sh

# Move to home
mv /opt/pzmanager /home/pzuser/
chown -R pzuser:pzuser /home/pzuser/pzmanager

# Configure .env (edit PZ_USER, ports, STEAM_BETA_BRANCH as needed)
nano /home/pzuser/pzmanager/scripts/.env

# Install server (reads PZ_USER and paths from .env)
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

## Basic Commands

```bash
pzm server start           # Start server
pzm server stop 5m         # Stop with 5-min warning
pzm server restart 2m      # Restart with 2-min warning
pzm server status          # Check status
pzm backup create          # Manual backup
```

**Delays**: `30m`, `15m`, `5m`, `2m`, `30s`, `now`

## Server Configuration

```bash
nano ~/pzmanager/Zomboid/Server/servertest.ini
```

Key settings:
```ini
PublicName=My Server       # Server name
Password=                  # Empty = public
AdminPassword=CHANGEME     # Change this!
MaxPlayers=32
```

Apply changes: `pzm server restart 5m`

## Discord Notifications (Optional)

```bash
nano ~/pzmanager/scripts/.env
```

Add your webhook:
```
DISCORD_WEBHOOK="https://discord.com/api/webhooks/..."
```

## What's Automated

| Task | Schedule | Description |
|------|----------|-------------|
| Mod check | Every 5 min | Auto-maintenance if updates detected |
| Backup | Hourly (:14) | Incremental, 14-day retention |
| Maintenance | Daily 4:30 AM | Updates + full backup + reboot |
| Whitelist dates | Daily 00:00 | Init creation dates for purge |

View timers: `systemctl --user list-timers`

## Restore from Backup

```bash
# Data only (world, saves)
pzm backup restore data/dataBackups/backup_YYYY-MM-DD_HHhMMmSSs

# Complete system restore
sudo ./scripts/install/configurationInitiale.sh restore /path/to/fullBackup
```

## Uninstallation

```bash
# Replace "pzuser" with your username if different
su - pzuser
pzm server stop now
systemctl --user disable zomboid.service pz-backup.timer pz-modcheck.timer pz-maintenance.timer pz-creation-date-init.timer
exit

sudo rm /etc/sudoers.d/pzuser
sudo rm -rf /home/pzuser/pzmanager
# (Optional) sudo userdel -r pzuser
```

## Troubleshooting

**Server won't start**:
```bash
journalctl --user -u zomboid.service -n 50
```

**Can't connect**:
```bash
sudo ufw status
pzm server status
```

## Next Steps

- [USAGE.md](USAGE.md) - All commands
- [SERVER_CONFIG.md](SERVER_CONFIG.md) - PZ server settings
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Problem solving
