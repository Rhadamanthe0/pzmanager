# Quick Start Guide

Get your Project Zomboid server running in 10 minutes.

## Prerequisites

- **OS**: Debian 12 or Ubuntu 22.04+
- **RAM**: 4GB minimum (8GB recommended)
- **Disk**: 20GB+ free
- **Access**: Root/sudo
- **APT**: SteamCMD must be available: enable Debian `non-free` or Ubuntu
  `multiverse` through your OS package configuration before installation. The
  installer does not add those components or a new repository for you.

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/Rhadamanthe0/pzmanager/main/data/scripts/install.sh | sudo bash
```

**Duration**: 10-30 minutes

The installer will:
1. Create a dedicated user account (`pzuser` by default)
2. Configure firewall (ports configurable via `PZ_PORT_*` in `.env`)
3. Install SteamCMD, Java 25, dependencies
4. Download Project Zomboid server
5. Set up systemd services and timers
6. Prepare [initial administrator credentials](SERVER_CONFIG.md#administrator-credentials)

For multiple servers, use a custom username:
```bash
curl -fsSL ... | sudo PZ_USER=pzuser42 bash
```

<details>
<summary>Manual installation (advanced)</summary>

Root installation helpers must run from a root-owned checkout whose ancestors
cannot be replaced by another user. Do not run a helper as root after moving it
into the manager's writable home. The installer prepares privileged system
configuration; routine `pzm` operations run as the manager account.
Use the installer above for the complete setup.

</details>

## First Start

Save the password displayed by installation before starting; see
[administrator credentials](SERVER_CONFIG.md#administrator-credentials).

```bash
su - pzuser
pzm server start
pzm server status
```

First startup generates the world.

## Basic Commands

```bash
pzm server start           # Start server
pzm server stop 5m         # Stop with 5-min warning
pzm server restart 2m      # Restart with 2-min warning
pzm server status          # Check status
pzm backup create          # Manual backup

# Maintenance with context (optional)
pzm admin maintenance 2m --reason "Augmentation de la RAM"
```

**Delays**: `30m`, `15m`, `5m`, `2m`, `30s`, `now`, `auto` (default for
`server stop/restart`: 5m if 2+ players are connected, 2m if 1, now if none)

**`--reason TEXT`** adds context to the Discord and in-game messages, on
`server stop/start/restart` as well as `admin maintenance`; see
[USAGE.md — Administration](USAGE.md#administration) for announcements.

## Server Configuration

```bash
nano ~/pzmanager/Zomboid/Server/servertest.ini
```

Key settings:
```ini
PublicName=My Server       # Server name
Password=                  # Empty = no shared join password
MaxPlayers=32
```

Apply changes: `pzm server restart 5m`

## Discord Notifications (Optional)

```bash
nano ~/pzmanager/.env
```

Add your webhook:
```
DISCORD_WEBHOOK="https://discord.com/api/webhooks/..."
```

## What's Automated

| Task | Schedule | Description |
|------|----------|-------------|
| Mod & server check | Every 5 min | Auto-maintenance if mod or server updates detected |
| Memory check | Every ~30 s | Restart at 18 GiB total service RAM or when the heap fills up |
| Backup | Hourly (:14) | Hardlinked snapshots; [retention settings](CONFIGURATION.md#backups) |
| Maintenance | Daily 4:30 AM | Updates + full backup + reboot/restart |
| Whitelist dates | Daily 00:00 | Init creation dates for purge |

View timers: `systemctl --user list-timers`

## Restore from Backup

```bash
# Data only (world, saves), using an existing snapshot directory
pzm server stop 2m --reason "Restauration du monde"
pzm backup restore data/dataBackups/backup_YYYY-MM-DD_HHhMMmSSs
```

For full-backup ZIPs and privileged restoration, follow
[complete restoration](TROUBLESHOOTING.md#complete-restoration-system--data).

## Uninstallation

Keep a verified backup before removing data. As root, select the manager account
and its real home. Run user-manager commands with that account's runtime directory.
Omit optional units that were never installed. Resolve stop failures before
removing files; close other operator sessions that could restart PZ.

```bash
PZ_REMOVE_USER=pzuser
PZ_REMOVE_HOME="$(getent passwd "$PZ_REMOVE_USER" | cut -d: -f6)"
PZ_REMOVE_UID="$(id -u "$PZ_REMOVE_USER")"
as_manager() {
    sudo -u "$PZ_REMOVE_USER" env XDG_RUNTIME_DIR="/run/user/$PZ_REMOVE_UID" "$@"
}

# Stop new periodic/bot requests before the guarded game shutdown.
as_manager systemctl --user disable --now pz-backup.timer pz-modcheck.timer \
    pz-heapcheck.timer pz-maintenance.timer pz-creation-date-init.timer \
    pz-stallwatch.timer pz-discord-bot.service
as_manager "$PZ_REMOVE_HOME/pzmanager/pzm" server stop now

# Remove socket activation and stop remaining units before deleting their files.
as_manager systemctl --user disable --now zomboid.socket zomboid.service \
    zomboid_logger.service pz-backup.service pz-modcheck.service \
    pz-heapcheck.service pz-maintenance.service pz-creation-date-init.service \
    pz-stallwatch.service
```

Stopping and disabling preserves the account and its data. If you choose to
remove the installation, delete its user-unit files and reload the user manager,
then remove `/etc/sudoers.d/<manager>` and the manager's `pzmanager` directory.
After any chosen cleanup and user-manager reload, disable lingering:

```bash
loginctl disable-linger "$PZ_REMOVE_USER"
```

Deleting the account/home is a separate optional choice. Packages and firewall
rules remain; review their other users before changing them.

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
