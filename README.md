# PZManager

[![License: CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey.svg)](https://creativecommons.org/licenses/by-nc-sa/4.0/)
[![Platform](https://img.shields.io/badge/platform-Debian%2012%20%7C%20Ubuntu%2022.04%2B-blue.svg)](https://www.debian.org/)

**Zero-config** Project Zomboid dedicated server manager. Install in one command, everything works out of the box.

## Features

- **Simple CLI** - `pzm server start`, `pzm server stop`, `pzm backup create`...
- **Auto-updates** - Detects mod updates every 5 min, triggers maintenance automatically
- **Auto-backups** - Hourly incremental backups, 14-day retention
- **Auto-maintenance** - Daily system/server updates at 4:30 AM
- **Discord notifications** - Server status, mod updates, maintenance alerts
- **Player warnings** - In-game countdown messages before restarts

## Installation

**Requirements**: Debian 12 / Ubuntu 22.04+, 4GB+ RAM, root access

```bash
curl -fsSL curl -fsSL https://raw.githubusercontent.com/Rhadamanthe0/pzmanager/main/install.sh | sudo bash
```

That's it. Server ready in ~10 minutes.

## Usage

```bash
su - pzuser                    # Switch to pzuser
pzm server start               # Start server
pzm server stop 5m             # Stop with 5-min warning
pzm server status              # Check status
pzm backup create              # Manual backup
pzm admin maintenance now      # Immediate maintenance
```

**Delays**: `30m`, `15m`, `5m`, `2m`, `30s`, `now`

## Discord Setup (Optional)

```bash
nano ~/pzmanager/scripts/.env
# Add: DISCORD_WEBHOOK="https://discord.com/api/webhooks/..."
```

## Documentation

| Guide | Description |
|-------|-------------|
| [QUICKSTART](docs/QUICKSTART.md) | 10-minute setup guide |
| [USAGE](docs/USAGE.md) | All commands explained |
| [CONFIGURATION](docs/CONFIGURATION.md) | Environment variables |
| [SERVER_CONFIG](docs/SERVER_CONFIG.md) | PZ server settings |
| [TROUBLESHOOTING](docs/TROUBLESHOOTING.md) | Common issues |
| [WHAT_IS_INSTALLED](docs/WHAT_IS_INSTALLED.md) | Full system details |

## License

CC BY-NC-SA 4.0 - Free for personal use. Commercial use requires permission.
