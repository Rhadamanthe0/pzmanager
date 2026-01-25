# Configuration Guide

Configuration of environment variables, backups, and Discord.

## Table of Contents

- [.env File](#env-file)
- [Backups Configuration](#backups-configuration)
- [Discord Integration](#discord-integration)
- [Logs Configuration](#logs-configuration)

For game server parameters, see [SERVER_CONFIG.md](SERVER_CONFIG.md).
For advanced settings, see [ADVANCED.md](ADVANCED.md).

## .env File

**Location**: `scripts/.env`

The .env file is automatically created from .env.example on first run.

**Edit**: `nano /home/pzuser/pzmanager/scripts/.env`

### Main Paths

⚠️ Only modify for custom installation

```bash
export PZ_USER="pzuser"
export PZ_HOME="/home/${PZ_USER}"
export PZ_MANAGER_DIR="${PZ_HOME}/pzmanager"
export PZ_SCRIPTS_DIR="${PZ_MANAGER_DIR}/scripts"
export PZ_DATA_DIR="${PZ_MANAGER_DIR}/data"
```

### Project Zomboid Server

```bash
export PZ_INSTALL_DIR="${PZ_DATA_DIR}/pzserver"
export PZ_CONTROL_PIPE="${PZ_INSTALL_DIR}/zomboid.control"
export PZ_JRE_LINK="${PZ_INSTALL_DIR}/jre64"
export PZ_SERVICE_NAME="zomboid.service"
export PZ_SOURCE_DIR="${PZ_MANAGER_DIR}/Zomboid"
```

### SteamCMD

```bash
export STEAMCMD_PATH="/usr/games/steamcmd"
export STEAM_APP_ID="380870"
export STEAM_BETA_BRANCH="legacy_41_78_7"
```

**Available branches**:
- `legacy_41_78_7`: Build 41.78.7 (stable, recommended)
- `public`: Latest stable version
- See [SteamDB](https://steamdb.info/app/380870/depots/) for other branches

### Java Runtime

```bash
export JAVA_VERSION="25"
export JAVA_PACKAGE="openjdk-${JAVA_VERSION}-jre-headless"
export JAVA_PATH="/usr/lib/jvm/java-${JAVA_VERSION}-openjdk-amd64"
```

**Compatible versions**: 17, 21, 25
**Recommended**: 25 (optimal performance)

**Change version**:
1. Modify `JAVA_VERSION` in .env
2. Run maintenance: `./scripts/admin/performFullMaintenance.sh now`

### Backups

```bash
export BACKUP_DIR="${PZ_DATA_DIR}/dataBackups"
export BACKUP_LATEST_LINK="${BACKUP_DIR}/latest"
export BACKUP_RETENTION_DAYS=30
```

**BACKUP_RETENTION_DAYS**: Number of days to keep (default: 30)

### External Synchronization

```bash
export SYNC_BACKUPS_DIR="${PZ_DATA_DIR}/fullBackups"
```

Timestamped complete backups (YYYY-MM-DD_HH-MM) created by fullBackup.sh.

### Logs

```bash
export LOG_BASE_DIR="${PZ_SCRIPTS_DIR}/logs"
export LOG_ZOMBOID_DIR="${LOG_BASE_DIR}/zomboid"
export LOG_MAINTENANCE_DIR="${LOG_BASE_DIR}/maintenance"
export LOG_RETENTION_DAYS=30
```

### Discord (Optional)

```bash
export DISCORD_WEBHOOK=""
```

Leave empty to disable. See [Discord Integration](#discord-integration).

## Backups Configuration

### Hourly Backups

**Script**: `scripts/backup/dataBackup.sh`
**Schedule**: Every hour at :14
**Method**: Incremental with hard links (rsync)
**Retention**: Configurable via `BACKUP_RETENTION_DAYS`

**Contents**:
- `Zomboid/Saves/` - World saves
- `Zomboid/db/` - Server database
- `Zomboid/Server/` - Server configuration

**Location**: `/home/pzuser/pzmanager/data/dataBackups/backup_YYYY-MM-DD_HHhMMmSSs/`

### Complete Backups

**Script**: `scripts/backup/fullBackup.sh`
**Schedule**: Daily at 4:30 AM (during maintenance)
**Method**: Complete snapshot + ZIP archive

**Contents**:
- System configuration (sudoers)
- SSH keys
- Systemd services and timers
- All scripts
- ZIP archive of latest Zomboid backup

**Location**: `/home/pzuser/pzmanager/data/fullBackups/YYYY-MM-DD_HH-MM/`

### Manual Backup

```bash
# Hourly backup
pzm backup create

# Complete backup
sudo ./scripts/backup/fullBackup.sh
```

### Restore from Backup

```bash
sudo ./scripts/install/configurationInitiale.sh restore /home/pzuser/pzmanager/data/fullBackups/2026-01-10_04-30
```

### Adjust Retention

```bash
nano /home/pzuser/pzmanager/scripts/.env

# Modify
export BACKUP_RETENTION_DAYS=14    # 14 days instead of 30
export LOG_RETENTION_DAYS=14        # Logs 14 days
```

**Disk space estimate**:
- Small server (1-2 players): ~500MB per backup
- Medium server (5-10 players): ~1GB per backup
- Large server (20+ players): ~2GB+ per backup

With 14-day retention and hourly backups: ~15-30GB

## Discord Integration

Optional notifications for server events.

### Configuration

**1. Create Discord webhook**
- Server Settings → Integrations → Webhooks
- New Webhook
- Name it (e.g., "PZ Server")
- Choose channel
- Copy URL

**2. Configure .env**
```bash
nano /home/pzuser/pzmanager/scripts/.env

# Paste URL
export DISCORD_WEBHOOK="https://discord.com/api/webhooks/1234567890/abcdefghijklmnopqrstuvwxyz"
```

**3. Test**
```bash
./scripts/internal/sendDiscord.sh "Test PZ server notification"
```

### Disable Notifications

```bash
# In .env, empty the variable
export DISCORD_WEBHOOK=""
```

### Notified Events

- Server startup
- Server online (RCON ready)
- Server shutdown (with delay)
- Daily maintenance start
- System reboot

## Logs Configuration

### Zomboid Logs

**Location**: `scripts/logs/zomboid/`
**Format**: `zomboid_YYYY-MM-DD_HHhMMmSS.log`
**Source**: journald (via captureLogs.sh)
**Retention**: `LOG_RETENTION_DAYS` (default: 30 days)

### Maintenance Logs

**Location**: `scripts/logs/maintenance/`
**Format**: `maintenance_YYYY-MM-DD_HHhMMmSS.log`
**Content**: Logs from performFullMaintenance.sh
**Retention**: `LOG_RETENTION_DAYS`

### View Logs

```bash
# Status + recent logs
pzm server status

# Real-time logs
sudo journalctl -u zomboid.service -f

# Maintenance logs
ls -lt scripts/logs/maintenance/
cat scripts/logs/maintenance/maintenance_YYYY-MM-DD_HHhMMmSS.log
```

## Configuration Validation

### Check .env Syntax

```bash
bash -n /home/pzuser/pzmanager/scripts/.env
```

### Check sudoers

```bash
sudo visudo -cf /home/pzuser/pzmanager/data/setupTemplates/pzuser-sudoers
```

### Check timers

```bash
systemctl --user list-timers
```

### Test Backups

```bash
pzm backup create
ls -la /home/pzuser/pzmanager/data/dataBackups/
```

### Test Discord

```bash
./scripts/internal/sendDiscord.sh "Test configuration"
```

## Resources

- [SERVER_CONFIG.md](SERVER_CONFIG.md) - Game server configuration
- [ADVANCED.md](ADVANCED.md) - Advanced settings and optimizations
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Troubleshooting
