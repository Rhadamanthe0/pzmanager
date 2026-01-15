# Usage Guide

Complete documentation of all pzmanager commands and operations.

## Prerequisites

⚠️ **All operational commands must be executed as pzuser**

```bash
su - pzuser
cd /home/pzuser/pzmanager
```

## Table of Contents

- [pzm Interface](#pzm-interface)
- [Server Management](#server-management)
- [Backups](#backups)
- [Whitelist](#whitelist)
- [Administration](#administration)
- [Configuration](#configuration)
- [RCON](#rcon)
- [Direct Scripts](#direct-scripts)
- [Use Cases](#use-cases)

---

## pzm Interface

**Main command**: `pzm`

**Help**: `pzm --help`

**General syntax**:
```bash
pzm <command> <subcommand> [arguments]
```

---

## Server Management

### Start

```bash
pzm server start
```

**Effect**:
- Starts the zomboid service
- Discord notification (if configured)
- Logs available via `status`

**Duration**: 2-5 minutes (first startup generates world)

### Stop

```bash
pzm server stop [delay]
```

**Available delays**:
- `30m`: Warning 30 minutes before
- `15m`: Warning 15 minutes before
- `5m`: Warning 5 minutes before
- `2m`: Warning 2 minutes before (default)
- `30s`: Warning 30 seconds before
- `now`: Immediate stop without warning

**Effect**:
- In-game messages to all players
- Discord notifications (if configured)
- Clean server shutdown

**Examples**:
```bash
pzm server stop           # Stop in 2 minutes
pzm server stop 30m       # Stop in 30 minutes
pzm server stop now       # Immediate stop
```

### Restart

```bash
pzm server restart [delay]
```

**Identical to `stop`**: Same delays, then automatic restart

**Examples**:
```bash
pzm server restart        # Restart in 2 minutes
pzm server restart 5m     # Restart in 5 minutes
```

**Use case**: Apply server configuration changes

### Status

```bash
pzm server status
```

**Displays**:
- Service status (RUNNING / STOPPED)
- Uptime duration
- Last save
- Last 30 log lines

**Example output**:
```
===== PROJECT ZOMBOID SERVER STATUS =====
Status: RUNNING
Active since: Sun 2026-01-12 10:30:00 UTC (5h ago)
Control pipe: Available

===== LAST SAVE =====
Last save: 2026-01-12 15:20:15

===== RECENT LOGS (last 30 lines) =====
[...] RCON: listening on port 27015
[...] SERVER STARTED
```

---

## Backups

### Incremental Backup

```bash
pzm backup create
```

**Effect**:
- Backup of Zomboid data only
- Hard links (optimized space)
- Retention: 14 days (configurable)

**Destination**: `data/dataBackups/backup_YYYY-MM-DD_HHhMMmSSs/`

**Automatic**: Every hour at :14 (crontab)

**Duration**: 10-60 seconds

### Complete Backup

```bash
pzm backup full
```

**Effect**:
- Complete system backup (Zomboid + pzserver)
- External synchronization (if configured)
- Used by daily maintenance

**Destination**: `data/fullBackups/YYYY-MM-DD_HH-MM/`

**Duration**: 2-10 minutes (depending on size)

### Restore

```bash
pzm backup restore <path>
```

**Parameters**:
- `<path>`: Relative or absolute path to backup

**Effect**:
- Server shutdown
- Safety backup of current state
- Data restoration from backup
- Permissions corrected

**Examples**:
```bash
# Relative path
pzm backup restore data/dataBackups/backup_2026-01-12_14h14m00s

# Absolute path
pzm backup restore /home/pzuser/pzmanager/data/dataBackups/backup_2026-01-12_14h14m00s
```

**⚠️ Caution**: Safety backup created in `OLD/ZomboidBROKEN_TIMESTAMP/`

### List Backups

```bash
pzm backup list
```

**Displays**:
- 20 most recent incremental backups
- 10 most recent complete backups
- Size and date

---

## Whitelist

### List

```bash
pzm whitelist list
```

**Displays**:
- Username
- Steam ID 32
- Last connection
- Sorted by last connection

**Example output**:
```
Username       | Steam ID           | Last Connection
---------------|--------------------|-----------------
PlayerOne      | STEAM_0:1:12345678 | 2026-01-12 14:30
PlayerTwo      | STEAM_0:0:87654321 | 2026-01-10 18:45
```

### Add

```bash
pzm whitelist add "<name>" "<steam_id_32>"
```

**Parameters**:
- `<name>`: Player name (quotes if spaces)
- `<steam_id_32>`: Steam ID format `STEAM_0:X:YYYYYYYY`

**Validation**: Steam ID 32 format verified automatically

**Conversion**: Steam64 ID → Steam ID 32 via https://steamid.xyz/

**Examples**:
```bash
pzm whitelist add "John Doe" "STEAM_0:1:12345678"
pzm whitelist add PlayerOne "STEAM_0:0:87654321"
```

**Immediate effect**: No need to restart server

### Remove

```bash
pzm whitelist remove "<steam_id_32>"
```

**Parameters**:
- `<steam_id_32>`: Steam ID to remove

**Confirmation**: Requested before deletion

**Examples**:
```bash
pzm whitelist remove "STEAM_0:1:12345678"
```

---

## Administration

### Server Reset

```bash
pzm admin reset [--keep-whitelist]
```

**Options**:
- Without option: Complete reset (new world, whitelist cleared)
- `--keep-whitelist`: Preserve whitelist and `.ini` files

**Effect**:
- Server shutdown
- Automatic backup in `OLD/Zomboid_OLD_TIMESTAMP/`
- Server data deletion
- Interactive initial configuration
- Whitelist restoration (if `--keep-whitelist`)

**⚠️ WARNING**: Destructive operation! Backup created automatically.

**Confirmation**: Type "RESET" to confirm

**Examples**:
```bash
# Complete reset (fresh new world)
pzm admin reset

# Reset with whitelist preservation
pzm admin reset --keep-whitelist
```

**Use cases**:
- New world (wipe)
- Fundamental parameter changes
- Data corruption

### Maintenance

```bash
pzm admin maintenance [delay]
```

**Default delay**: `30m`

**Steps**:
1. Server shutdown with warnings
2. Backup rotation (deletion > 14 days)
3. System update (`apt upgrade`)
4. Java update
5. PZ server update (SteamCMD)
6. Java symlink restoration
7. External complete backup
8. System reboot

**Automatic**: Daily at 4:30 AM (crontab)

**Logs**: `scripts/logs/maintenance/maintenance_YYYY-MM-DD_HHhMMmSSs.log`

**Duration**: 15-45 minutes

**Examples**:
```bash
pzm admin maintenance        # Maintenance in 30 minutes
pzm admin maintenance 15m    # Maintenance in 15 minutes
pzm admin maintenance 2m     # Maintenance in 2 minutes
```

**Remote trigger**:
```bash
# From local machine
ssh pzuser@SERVER 30m
```

---

## Configuration

### Server RAM

```bash
pzm config ram <value>
```

**Accepted values**: `2g`, `4g`, `6g`, `8g`, `12g`, `16g`, `20g`, `24g`, `32g`

**Effect**:
- Modification of `ProjectZomboid64.json`
- Automatic backup before modification
- Detection if value already configured

**⚠️ Important**: Restart server to apply

**Examples**:
```bash
pzm config ram 4g    # 4GB RAM
pzm config ram 8g    # 8GB RAM (default)
pzm config ram 16g   # 16GB RAM
pzm config ram 32g   # 32GB RAM
```

**Recommendations**:
- **4GB**: 1-10 players
- **8GB**: 10-20 players (default)
- **16GB**: 20-50 players
- **32GB**: 50+ players or large mods

**Apply**:
```bash
pzm config ram 16g
pzm server restart 5m
```

---

## RCON

### Send Command

```bash
pzm rcon "<command>"
```

**Useful commands**:

#### Save
```bash
pzm rcon "save"
```

#### Broadcast Message
```bash
pzm rcon "servermsg 'Restart in 5 minutes'"
```

#### Stop Server
```bash
pzm rcon "quit"
```

#### List Players
```bash
pzm rcon "players"
```

#### Teleport Player
```bash
pzm rcon "teleport PlayerName 1000 1000 0"
```

#### Add Item
```bash
pzm rcon "giveitem PlayerName Base.Axe"
```

#### Ban/Unban
```bash
pzm rcon "banuser PlayerName"
pzm rcon "unbanuser PlayerName"
```

#### Kick Player
```bash
pzm rcon "kickuser PlayerName"
```

#### God Mode
```bash
pzm rcon "godmode PlayerName"
```

#### Invisible
```bash
pzm rcon "invisible PlayerName"
```

#### Change Weather
```bash
pzm rcon "setweather rain"
pzm rcon "setweather sunny"
```

#### Complete Help
```bash
pzm rcon "help"
```

**Official documentation**: [PZ Wiki - Server Commands](https://pzwiki.net/wiki/Server_commands)

---

## Direct Scripts

Alternative to `pzm`: direct scripts with new paths.

### Server

```bash
./scripts/core/pz.sh start
./scripts/core/pz.sh stop [delay]
./scripts/core/pz.sh restart [delay]
./scripts/core/pz.sh status
```

### Backups

```bash
./scripts/backup/dataBackup.sh
./scripts/backup/fullBackup.sh
./scripts/backup/restoreZomboidData.sh <path>
```

### Administration

```bash
./scripts/admin/manageWhitelist.sh list
./scripts/admin/manageWhitelist.sh add "<name>" "<steam_id>"
./scripts/admin/manageWhitelist.sh remove "<steam_id>"
./scripts/admin/resetServer.sh [--keep-whitelist]
./scripts/admin/setram.sh <value>
./scripts/admin/performFullMaintenance.sh [delay]
```

### RCON

```bash
./scripts/internal/sendCommand.sh "<command>"
./scripts/internal/sendDiscord.sh "<message>"
```

**Recommendation**: Use `pzm` for unified interface

---

## Use Cases

### Daily Startup

```bash
su - pzuser
cd /home/pzuser/pzmanager
pzm server status
# If stopped:
pzm server start
```

### Apply Server Configuration

```bash
# 1. Edit configuration
nano /home/pzuser/pzmanager/Zomboid/Server/servertest.ini

# 2. Restart with warning
pzm server restart 5m
```

### Manual Update

```bash
# Complete maintenance (system + server update)
pzm admin maintenance 30m
```

### Add Player to Whitelist

```bash
# 1. Get Steam ID 32 from Steam64 ID
# https://steamid.xyz/ → Convert 76561198XXXXXXXXX

# 2. Add to whitelist
pzm whitelist add "PlayerName" "STEAM_0:1:12345678"

# 3. Verify
pzm whitelist list
```

### Restore Backup

```bash
# 1. List available backups
pzm backup list

# 2. Restore specific backup
pzm backup restore data/dataBackups/backup_2026-01-12_14h14m00s

# 3. Start server
pzm server start
```

### New World (Wipe)

```bash
# With whitelist preservation
pzm admin reset --keep-whitelist
# Confirm by typing "RESET"

# Start new world
pzm server start
```

### Increase Server RAM

```bash
# 1. Configure RAM
pzm config ram 16g

# 2. Apply with restart
pzm server restart 5m
```

### Send Message to Players

```bash
pzm rcon "servermsg 'Maintenance in 10 minutes'"
```

### Manual Save

```bash
# Via RCON
pzm rcon "save"

# Via incremental backup
pzm backup create
```

### Check Logs

```bash
# Recent logs
pzm server status

# Complete server logs
ls -lh scripts/logs/zomboid/
cat scripts/logs/zomboid/zomboid_2026-01-12_10h30m00s.log

# Maintenance logs
ls -lh scripts/logs/maintenance/
cat scripts/logs/maintenance/maintenance_2026-01-12_04h30m00s.log

# Backup logs
cat scripts/logs/data_backup.log
```

### Test Discord

```bash
# Via direct script
./scripts/internal/sendDiscord.sh "Test notification"

# Via RCON (triggers notification)
pzm rcon "save"
```

### Server Monitoring

```bash
# Systemd service status
systemctl --user status zomboid.service

# Real-time journald logs
journalctl --user -u zomboid.service -f

# System resources
htop
# Search for "java" process
```

### Bulk Whitelist Modification

```bash
# Via direct SQLite
sqlite3 /home/pzuser/pzmanager/Zomboid/db/servertest.db

# List all
SELECT username, steamid FROM whitelist;

# Delete all (except admin)
DELETE FROM whitelist WHERE username != 'admin';

# Quit
.quit
```

### Backup Before Maintenance

```bash
# 1. Manual complete backup
pzm backup full

# 2. Verify creation
ls -lh data/fullBackups/

# 3. Maintenance
pzm admin maintenance 30m
```

---

## Quick Troubleshooting

### Server Won't Start

```bash
# Check logs
pzm server status
journalctl --user -u zomboid.service -n 100

# Check service
systemctl --user status zomboid.service

# Restart service
systemctl --user restart zomboid.service
```

### Server Slow / Lag

```bash
# Increase RAM
pzm config ram 16g
pzm server restart 5m

# Check resources
htop
```

### Data Corruption

```bash
# Restore recent backup
pzm backup list
pzm backup restore data/dataBackups/backup_RECENT

# Or complete reset
pzm admin reset --keep-whitelist
```

### Backup Fails

```bash
# Check disk space
df -h

# Check logs
cat scripts/logs/data_backup.log

# Old backup cleanup
# (automatic via daily maintenance)
```

---

## Environment Variables

**File**: `scripts/.env`

**Edit**:
```bash
nano scripts/.env
```

**Useful variables**:

```bash
# RAM / Java
JAVA_VERSION="25"

# Backups
BACKUP_RETENTION_DAYS="30"

# Discord (optional)
DISCORD_WEBHOOK="https://discord.com/api/webhooks/..."

# PZ Server
STEAM_BETA_BRANCH="legacy_41_78_7"
```

**Apply**: Restart affected services

**Documentation**: [CONFIGURATION.md](CONFIGURATION.md)

---

## Automations

### Crontab

**View tasks**:
```bash
crontab -l
```

**Configured tasks**:

#### Hourly Backup (:14)
```
14 * * * *  /bin/bash  /home/pzuser/pzmanager/scripts/backup/dataBackup.sh >> /home/pzuser/pzmanager/scripts/logs/data_backup.log 2>&1
```

#### Daily Maintenance (4:30 AM)
```
30 4 * * *  /bin/bash  /home/pzuser/pzmanager/scripts/admin/performFullMaintenance.sh
```

**Edit crontab**:
```bash
crontab -e
```

---

## Help and Support

**pzm Help**:
```bash
pzm --help
```

**Specific script help**:
```bash
./scripts/admin/setram.sh --help
```

**Documentation**:
- [INSTALLATION.md](INSTALLATION.md) - Detailed installation
- [CONFIGURATION.md](CONFIGURATION.md) - .env variables
- [SERVER_CONFIG.md](SERVER_CONFIG.md) - PZ server config
- [ADVANCED.md](ADVANCED.md) - Optimizations
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Troubleshooting
- [WHAT_IS_INSTALLED.md](WHAT_IS_INSTALLED.md) - Installation details

**Support**: Open issue on GitHub
