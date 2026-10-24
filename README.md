# PZManager

[![License: CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey.svg)](https://creativecommons.org/licenses/by-nc-sa/4.0/)
[![Platform](https://img.shields.io/badge/platform-Debian%2012%20%7C%20Ubuntu%2022.04%2B-blue.svg)](https://www.debian.org/)
[![Build 42](https://img.shields.io/badge/Project%20Zomboid-Build%2042-green.svg)](https://projectzomboid.com/)

**Zero-config** Project Zomboid **Build 42** dedicated server manager. Install in one command, everything works out of the box.

## Features

- **Simple CLI** - `pzm server start`, `pzm server stop`, `pzm backup create`...
- **Auto-updates** - Detects mod and server updates every 5 min, triggers maintenance automatically
- **Auto-backups** - Hourly incremental snapshots with [GFS retention](docs/CONFIGURATION.md#backups) + off-site ZIPs
- **Local map recovery** - Restore constructions in a rectangle from a snapshot, with preview and automatic rollback on failure (`pzm backup restore-zone`)
- **Auto-maintenance** - Daily system/server updates at 4:30 AM
- **Adaptive memory restart** - Requests a restart at 18 GiB resident service RAM or near-full heap; heap capped at 16 GiB within a 20 GiB service budget
- **Discord notifications** - Server status, mod updates, maintenance alerts, periodic health monitoring
- **Discord command bot** - Run `pzm` from Discord (`/pzm …`)
- **Player warnings** - In-game countdown messages before restarts
- **SteamID whitelist** - B42 access control (`Open=false`); auto-removes access of long-inactive players (keeps their character)

## Installation

**Requirements**: Debian 12 / Ubuntu 22.04+, 4GB+ RAM, root access

```bash
curl -fsSL https://raw.githubusercontent.com/Rhadamanthe0/pzmanager/main/data/scripts/install.sh | sudo bash
```

Custom username (for multiple servers on the same machine):
```bash
curl -fsSL https://raw.githubusercontent.com/Rhadamanthe0/pzmanager/main/data/scripts/install.sh | sudo PZ_USER=pzuser42 bash
```

That's it. Server ready in ~10 minutes.

## Usage

```bash
su - pzuser                    # Switch to server user (pzuser by default)
pzm server start               # Start server
pzm server stop 5m             # Stop with 5-min warning
pzm server status              # Check status
pzm backup create              # Manual backup
pzm admin maintenance now      # Immediate maintenance
```

**Delays**: `30m`, `15m`, `5m`, `2m`, `30s`, `now`

## Discord Setup (Optional)

```bash
nano ~/pzmanager/.env
# Add: DISCORD_WEBHOOK="https://discord.com/api/webhooks/..."
```

Want to run `pzm` **from** Discord (`/pzm server …`, `/pzm rcon …`)? Set up the
command bot: [docs/DISCORD_BOT.md](docs/DISCORD_BOT.md).

## Documentation

Full index, including which document owns which topic:
**[docs/README.md](docs/README.md)**.

| Guide | Description |
|-------|-------------|
| [QUICKSTART](docs/QUICKSTART.md) | 10-minute setup guide |
| [ARCHITECTURE](docs/ARCHITECTURE.md) | How the code is organised, control-FIFO design |
| [USAGE](docs/USAGE.md) | All commands explained |
| [CONFIGURATION](docs/CONFIGURATION.md) | Environment variables |
| [DISCORD_BOT](docs/DISCORD_BOT.md) | Run pzm from Discord (/pzm bot) |
| [SERVER_CONFIG](docs/SERVER_CONFIG.md) | PZ server settings |
| [MOD_UPDATES](docs/MOD_UPDATES.md) | Adding/removing Workshop mods (agentic-AI-driven) |
| [ADVANCED](docs/ADVANCED.md) | RAM/JVM tuning & server reset |
| [TROUBLESHOOTING](docs/TROUBLESHOOTING.md) | Common issues |
| [WHAT_IS_INSTALLED](docs/WHAT_IS_INSTALLED.md) | Full system details |
| [HOST_ENVIRONMENT](docs/HOST_ENVIRONMENT.md) | The machine itself: RAM budget, freezes, networking |
| [INCIDENTS](docs/INCIDENTS.md) | Post-mortems |
| [PROCEDURE_JOUEURS](docs/PROCEDURE_JOUEURS.md) | Player connection guide (FR) |

## License

CC BY-NC-SA 4.0 - Free for personal use. Commercial use requires permission.

Le plafond partagé PZ (jeu et gestion), sa migration et ses limites sont décrits
dans [ADVANCED.md](docs/ADVANCED.md#budget-memoire-partage-de-pz).
