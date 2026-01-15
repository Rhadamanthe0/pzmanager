# Project Zomboid Server Manager

[![License: CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey.svg)](https://creativecommons.org/licenses/by-nc-sa/4.0/)
[![Platform](https://img.shields.io/badge/platform-Debian%2012%20%7C%20Ubuntu%2022.04%2B-blue.svg)](https://www.debian.org/)

**Out-of-the-box** Project Zomboid server manager: simplified, secure, and automated installation for system administration beginners.

**🎯 Philosophy**: Zero manual configuration - everything works right after installation with secure default parameters.

**👋 New here?** Follow the [Quick Start Guide](docs/QUICKSTART.md) - 10-minute installation.

## Features

- **Simplified management**: Start, stop, restart with player warnings
- **Automatic backups**: Hourly incremental, 14-day retention
- **Daily maintenance**: System/server updates, complete backups, reboot
- **Mod update monitoring**: Checks every 5 minutes, triggers maintenance if updates detected
- **Discord** (optional): Real-time notifications
- **Remote maintenance**: Trigger via SSH
- **Centralized configuration**: Single .env file
- **Safe deployment**: Automatic .env creation from template

## Quick Installation

⚠️ **Installation as root** - operation as pzuser

```bash
git clone https://github.com/YOUR_USERNAME/pzmanager.git /opt/pzmanager
cd /opt/pzmanager
./scripts/install/setupSystem.sh
visudo -cf data/setup/pzuser-sudoers && cp data/setup/pzuser-sudoers /etc/sudoers.d/pzuser
mv /opt/pzmanager /home/pzuser/
chown -R pzuser:pzuser /home/pzuser/pzmanager
sudo -u pzuser crontab /home/pzuser/pzmanager/data/setup/pzuser-crontab
/home/pzuser/pzmanager/scripts/install/configurationInitiale.sh zomboid
```

**Installed version**: Project Zomboid Build 41 (branch `legacy_41_78_7`)

**Installation details**: [docs/WHAT_IS_INSTALLED.md](docs/WHAT_IS_INSTALLED.md) - Complete list of everything installed/configured

**Operation**: All operational commands are run as pzuser (`su - pzuser`)

Complete guide: [docs/INSTALLATION.md](docs/INSTALLATION.md)

## Usage

### Unified interface (recommended)

```bash
pzm server start              # Start
pzm server stop [delay]       # Stop (default: 2m)
pzm server restart [delay]    # Restart
pzm server status             # Status + recent logs
pzm backup create             # Incremental backup
pzm whitelist list            # View whitelist
pzm config ram 8g             # Configure server RAM
pzm admin maintenance [delay] # Maintenance
```

**Available delays**: `30m`, `15m`, `5m`, `2m`, `30s`, `now`

**Warnings**:
- In-game messages to all players
- Discord notifications (if configured)

### Direct scripts (alternative)

```bash
./scripts/core/pz.sh start
./scripts/backup/dataBackup.sh
./scripts/admin/manageWhitelist.sh list
```

## Prerequisites

**System**:
- Debian 12 (recommended) or Ubuntu 22.04+
- Fresh installation preferred

**Hardware**:
- 4GB RAM minimum (8GB recommended)
- 20GB+ free disk space
- 2+ CPU cores recommended

**Access**:
- Root/sudo
- SSH (for remote management)

**Network**:
- Ports 16261/UDP, 16262/UDP, 8766/UDP, 27015/TCP
- Automatically opened by the installer

## Configuration

### Environment Variables

The `scripts/.env` file centralizes all variables:
- Paths (server, backups, logs, sync)
- SteamCMD and Java parameters
- Backup/log retention (14 days)
- Discord webhook (optional)

Automatically created from `data/setup/.env.example` on first run.

**Editing**: `nano scripts/.env`

### Discord (Optional)

1. Create Discord webhook (Server Settings → Integrations → Webhooks)
2. Edit `scripts/.env`: `DISCORD_WEBHOOK="URL"`
3. Leave empty to disable

## Structure

```
pzmanager/
├── pzm                       # Main interface (in PATH)
├── Zomboid/                  # Server data (saves, configs)
├── scripts/
│   ├── .env                  # Personal config (NOT versioned)
│   ├── lib/
│   │   └── common.sh         # Common library for shared functions
│   ├── core/
│   │   └── pz.sh             # Server management (start/stop/restart/status)
│   ├── backup/
│   │   ├── dataBackup.sh     # Hourly incremental backup
│   │   ├── fullBackup.sh     # Complete backup with sync
│   │   └── restoreZomboidData.sh  # Data-only restoration
│   ├── admin/
│   │   ├── checkModUpdates.sh      # Mod update detection (automated)
│   │   ├── manageWhitelist.sh      # Whitelist management
│   │   ├── resetServer.sh          # Complete server reset
│   │   └── performFullMaintenance.sh  # Daily maintenance
│   ├── install/
│   │   ├── setupSystem.sh         # Initial system config
│   │   └── configurationInitiale.sh  # Server install/restore
│   ├── internal/
│   │   ├── sendCommand.sh         # RCON (with output capture)
│   │   ├── sendDiscord.sh         # Discord notifications
│   │   ├── captureLogs.sh         # Journald log capture
│   │   └── notifyServerReady.sh   # Startup notification
│   └── logs/
└── data/
    ├── setup/                # System config files
    │   ├── .env.example      # Config template (versioned)
    │   ├── pzuser-crontab
    │   └── pzuser-sudoers
    ├── pzserver/             # Server installation
    ├── dataBackups/          # Hourly backups (14 days)
    ├── fullBackups/          # Timestamped complete backups
    └── versionning/          # Version history
```

## Sudo Permissions (pzuser)

Configuration in `/etc/sudoers.d/pzuser`:

- **APT**: update, upgrade, install openjdk, autoremove, autoclean
- **Java**: Manage symlink `/home/pzuser/pzmanager/data/pzserver/jre64`
- **Backup**: Execute fullBackup.sh as root
- **Reboot**: `/sbin/reboot`

## Automations (crontab)

**Mod update check (every 5 minutes)**:
- RCON `checkModsNeedUpdate`
- Triggers maintenance (5m delay) if updates found
- Discord notifications

**Daily maintenance (4:30 AM)**:
- Server shutdown (warnings)
- Backup rotation
- System updates (APT + Java + SteamCMD)
- Complete backup
- System reboot

**Hourly backup (:14)**:
- Incremental backup with hard links
- 14-day retention

**View**: `crontab -l`

## Remote Maintenance

Special SSH key forces execution of `performFullMaintenance.sh`:

```bash
# From local machine
ssh pzuser@SERVER 30m   # Maintenance with 30-minute warning
ssh pzuser@SERVER 2m    # Maintenance with 2-minute warning
```

**Restrictions**: Forced command, no forwarding

## Documentation

- [docs/QUICKSTART.md](docs/QUICKSTART.md) - Quick installation (10 min)
- [docs/INSTALLATION.md](docs/INSTALLATION.md) - Detailed installation
- [docs/WHAT_IS_INSTALLED.md](docs/WHAT_IS_INSTALLED.md) - Complete installation details
- [docs/USAGE.md](docs/USAGE.md) - Complete command guide
- [docs/CONFIGURATION.md](docs/CONFIGURATION.md) - .env variables, backups, Discord
- [docs/SERVER_CONFIG.md](docs/SERVER_CONFIG.md) - PZ server configuration
- [docs/ADVANCED.md](docs/ADVANCED.md) - Optimizations, RCON
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) - Troubleshooting

## License

CC BY-NC-SA 4.0 (Creative Commons Attribution-NonCommercial-ShareAlike 4.0)

**Summary**: Use/share/modify for personal/non-commercial use. Modifications under same license. Commercial use requires permission.

## Support

Issues, questions, suggestions: Open an issue on GitHub
