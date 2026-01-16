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

The installer will:
1. Create `pzuser` account
2. Configure firewall (ports 16261, 16262, 8766, 27015)
3. Install SteamCMD, Java 25, dependencies
4. Download Project Zomboid server
5. Set up systemd services and timers

**Duration**: 10-30 minutes depending on connection.

## First Start

```bash
su - pzuser
pzm server start
pzm server status
```

Expected output:
```
Status: RUNNING
Active since: [timestamp]
Control pipe: Available
```

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

View timers: `systemctl --user list-timers`

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
- [CONFIGURATION.md](CONFIGURATION.md) - Environment variables
