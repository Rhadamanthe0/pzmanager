# What Is Installed and Configured

Comprehensive documentation of all changes made by pzmanager to the system.

## Project Philosophy

**pzmanager** is designed to be **out-of-the-box**: one-command installation with optimal and secure default configuration.

**Objectives**:
- ✅ **Zero manual configuration**: Everything works immediately after installation
- ✅ **Security by default**: Firewall, dedicated user, minimal permissions
- ✅ **Automations**: Backups, maintenance, automatic updates
- ✅ **Simplicity**: Unified CLI interface, intuitive commands
- ✅ **For beginners**: No system expertise required

This document details **everything** modified on your system to ensure transparency and trust.

## Table of Contents

- [System Packages](#system-packages)
- [User and Permissions](#user-and-permissions)
- [Network Configuration](#network-configuration)
- [Project Zomboid](#project-zomboid)
- [Systemd Services](#systemd-services)
- [Automations](#automations)
- [File Structure](#file-structure)

---

## System Packages

### Installed by setupSystem.sh

**Base packages**:
- `rsync`: Incremental backups with hard links
- `unzip`: Archive decompression
- `ufw`: Simplified firewall

**Installed by configurationInitiale.sh**:

**32-bit architecture** (required by SteamCMD):
- `dpkg --add-architecture i386`
- `lib32gcc-s1`
- `lib32stdc++6`

**SteamCMD and dependencies**:
- `steamcmd`
- `ca-certificates`
- `software-properties-common`
- `apt-transport-https`
- `dirmngr`
- `curl`
- `wget`

**Java** (version configurable via `.env`):
- `openjdk-25-jre-headless` (default)
- OR `openjdk-17-jre-headless`
- OR `openjdk-21-jre-headless`

**Location**: `/usr/lib/jvm/java-25-openjdk-amd64` (depending on version)

---

## User and Permissions

### pzuser User

**Created by**: `setupSystem.sh`

**Properties**:
- Home: `/home/pzuser/`
- Shell: `/bin/bash`
- Groups: `pzuser` (primary group)

### sudo Permissions

**File**: `/etc/sudoers.d/pzuser`

**Allowed commands** (NOPASSWD):

**APT (package management)**:
```
/usr/bin/apt-get update
/usr/bin/apt-get upgrade
/usr/bin/apt-get install openjdk-*-jre-headless
/usr/bin/apt-get autoremove
/usr/bin/apt-get autoclean
```

**Java (symlink)**:
```
/usr/bin/rm -rf /home/pzuser/pzmanager/data/pzserver/jre64
/usr/bin/ln -s /usr/lib/jvm/java-*-openjdk-amd64 /home/pzuser/pzmanager/data/pzserver/jre64
```

**Backups**:
```
/home/pzuser/pzmanager/scripts/backup/fullBackup.sh
```

**System**:
```
/sbin/reboot
```

---

## Network Configuration

### Firewall (UFW)

**Configured by**: `setupSystem.sh`

**Default rules**:
- Incoming: DENY
- Outgoing: ALLOW

**Open ports**:

| Port | Protocol | Usage |
|------|----------|-------|
| 22/TCP | SSH | Server administration |
| 16261/UDP | Game | Main Project Zomboid port |
| 16262/UDP | Game | Secondary Project Zomboid port |
| 8766/UDP | RCON | Administrative commands |
| 27015/TCP | Steam | Steam query port |

**Check**: `sudo ufw status`

---

## Project Zomboid

### Server

**Installed by**: `configurationInitiale.sh zomboid`

**Version**: Build 41.78.7 (branch `legacy_41_78_7`)

**Installation method**:
```bash
/usr/games/steamcmd +login anonymous \
    +force_install_dir /home/pzuser/pzmanager/data/pzserver \
    +app_update 380870 -beta legacy_41_78_7 validate \
    +quit
```

**Location**: `/home/pzuser/pzmanager/data/pzserver/`

**Size**: ~1-2GB

### JVM Configuration

**File**: `/home/pzuser/pzmanager/data/pzserver/ProjectZomboid64.json`

**Automatically applied parameters**:

```json
{
  "vmArgs": [
    "-Djava.awt.headless=true",
    "-Xmx8g",
    "-Dzomboid.steam=1",
    "-Dzomboid.znetlog=1",
    "-Djava.library.path=linux64/:natives/",
    "-Djava.security.egd=file:/dev/urandom",
    "-XX:+UseZGC",
    "-XX:-OmitStackTraceInFastThrow"
  ]
}
```

**Optimizations**:
- **RAM**: 8GB by default (`-Xmx8g`)
- **ZGC**: Modern Garbage Collector (`-XX:+UseZGC`)
- **Headless**: No GUI
- **Steam**: Steam integration enabled

**Modify RAM**: `pzm config ram <value>`

### Server Data

**Location**: `/home/pzuser/pzmanager/Zomboid/`

**Structure**:
```
Zomboid/
├── Server/
│   ├── servertest.ini          # Server configuration
│   ├── servertest_access.txt   # Admins
│   ├── servertest_SandboxVars.lua  # Gameplay parameters
│   └── servertest_spawnregions.lua
├── Saves/
│   └── Multiplayer/
│       └── servertest/         # World saves
├── db/
│   └── servertest.db           # SQLite database (whitelist, bans)
├── Logs/
└── mods/
```

**Typical size**: 500MB - 5GB (depending on usage)

---

## Systemd Services

**Installation**: Systemd services are automatically installed from templates in `data/setupTemplates/` during server installation.

### zomboid.service Service

**Type**: User service (systemd user)

**Template file**: `~/pzmanager/data/setupTemplates/zomboid.service`
**Installed file**: `~/.config/systemd/user/zomboid.service`

**Configuration**:
```ini
[Unit]
Description=Project Zomboid Server
After=network.target zomboid.socket
Requires=zomboid.socket
Wants=zomboid_logger.service

[Service]
Type=simple
PrivateTmp=true
WorkingDirectory=/home/pzuser/pzmanager/data/pzserver/
ExecStart=/bin/sh -c "exec /home/pzuser/pzmanager/data/pzserver/start-server.sh -cachedir=/home/pzuser/pzmanager/Zomboid <> /home/pzuser/pzmanager/data/pzserver/zomboid.control"
ExecStartPost=-/bin/sh -c "/home/pzuser/pzmanager/scripts/internal/notifyServerReady.sh &"
ExecStop=/bin/sh -c "echo 'quit' > /home/pzuser/pzmanager/data/pzserver/zomboid.control"
KillSignal=SIGCONT
TimeoutStopSec=30

[Install]
WantedBy=default.target
```

**Features**:
- Automatic startup at boot
- Uses systemd socket for control pipe
- Discord notification at startup (via notifyServerReady.sh)
- Dedicated logger (zomboid_logger.service)
- Clean shutdown via 'quit' command

**Commands**:
```bash
systemctl --user status zomboid.service
systemctl --user start zomboid.service
systemctl --user stop zomboid.service
systemctl --user restart zomboid.service
```

### zomboid.socket Socket

**Type**: Systemd socket for control pipe

**Template file**: `~/pzmanager/data/setupTemplates/zomboid.socket`
**Installed file**: `~/.config/systemd/user/zomboid.socket`

**Configuration**:
```ini
[Unit]
Description=Project Zomboid Server Control Socket
PartOf=zomboid.service
Before=zomboid.service

[Socket]
ListenFIFO=/home/pzuser/pzmanager/data/pzserver/zomboid.control
FileDescriptorName=control
SocketMode=0660
SocketUser=pzuser
ExecStartPre=/bin/rm -f /home/pzuser/pzmanager/data/pzserver/zomboid.control
RemoveOnStop=true
```

**Function**: Manages the FIFO (named pipe) used to send commands to the server via RCON.

### zomboid_logger.service Service

**Type**: Log capture service

**Template file**: `~/pzmanager/data/setupTemplates/zomboid_logger.service`
**Installed file**: `~/.config/systemd/user/zomboid_logger.service`

**Configuration**:
```ini
[Unit]
Description=Logger for Project Zomboid
PartOf=zomboid.service
After=zomboid.service

[Service]
Type=simple
ExecStart=/home/pzuser/pzmanager/scripts/internal/captureLogs.sh
Restart=always
RestartSec=5
```

**Function**: Captures server logs from journald and saves them to timestamped files.

### Systemd Lingering

**Enabled for**: `pzuser`

**Effect**: User services start at boot, even if pzuser not logged in

**Command**: `loginctl enable-linger pzuser`

**Check**: `ls /var/lib/systemd/linger/` (should contain `pzuser`)

---

## Automations

### pzuser Crontab

**Source file**: `/home/pzuser/pzmanager/data/setupTemplates/pzuser-crontab`

**Configured tasks**:

#### Mod update check (every 5 minutes)
```cron
*/5 * * * *  /bin/bash  /home/pzuser/pzmanager/scripts/admin/checkModUpdates.sh >> /home/pzuser/pzmanager/scripts/logs/maintenance/mod_check_cron.log 2>&1
```

**Function**:
- Checks Workshop mod updates via RCON `checkModsNeedUpdate`
- Triggers `performFullMaintenance.sh` (5m delay) if updates found
- Sends Discord notifications
- Logs: `/home/pzuser/pzmanager/scripts/logs/maintenance/mod_check_*.log`

#### Hourly backup (every day at :14)
```cron
14 * * * *  /bin/bash  /home/pzuser/pzmanager/scripts/backup/dataBackup.sh >> /home/pzuser/pzmanager/scripts/logs/data_backup.log 2>&1
```

**Function**:
- Incremental backup with hard links
- Retention: 14 days (configurable via `.env`)
- Destination: `/home/pzuser/pzmanager/data/dataBackups/`

#### Daily maintenance (4:30 AM)
```cron
30 4 * * *  /bin/bash  /home/pzuser/pzmanager/scripts/admin/performFullMaintenance.sh
```

**Steps**:
1. Server shutdown with warnings (30min default)
2. Backup rotation (deletion > 14 days)
3. System update (`apt upgrade`)
4. Java update
5. PZ server update (SteamCMD)
6. Java symlink restoration
7. External complete backup
8. System reboot

**Logs**: `/home/pzuser/pzmanager/scripts/logs/maintenance/`

**Check crontab**: `crontab -l`

---

## File Structure

### Complete Directory Tree

```
/home/pzuser/pzmanager/
├── Zomboid/                          # PZ server data
│   ├── Server/                       # Server config
│   │   ├── servertest.ini
│   │   ├── servertest_access.txt
│   │   ├── servertest_SandboxVars.lua
│   │   └── servertest_spawnregions.lua
│   ├── Saves/Multiplayer/servertest/ # World saves
│   ├── db/servertest.db              # SQLite database
│   ├── Logs/
│   └── mods/
│
├── scripts/
│   ├── .env.example                  # Variables template
│   ├── .env                          # Config variables (auto-created)
│   ├── pzm                           # Unified CLI interface
│   │
│   ├── core/
│   │   └── pz.sh                     # Server management (start/stop/restart/status)
│   │
│   ├── backup/
│   │   ├── dataBackup.sh             # Hourly incremental backup
│   │   ├── fullBackup.sh             # Complete backup with external sync
│   │   └── restoreZomboidData.sh     # Data-only restoration
│   │
│   ├── admin/
│   │   ├── checkModUpdates.sh        # Mod update detection (automated)
│   │   ├── manageWhitelist.sh        # SQLite whitelist management
│   │   ├── resetServer.sh            # Complete server reset
│   │   ├── setram.sh                 # Server RAM configuration
│   │   └── performFullMaintenance.sh # Automatic maintenance
│   │
│   ├── install/
│   │   ├── setupSystem.sh            # System config (user, firewall, packages)
│   │   └── configurationInitiale.sh  # PZ server install
│   │
│   ├── internal/
│   │   ├── sendCommand.sh            # RCON with output capture
│   │   ├── sendDiscord.sh            # Discord notifications
│   │   ├── captureLogs.sh            # Journald log capture
│   │   └── notifyServerReady.sh      # Server startup notification
│   │
│   └── logs/
│       ├── zomboid/                  # Captured server logs
│       ├── maintenance/              # Maintenance logs
│       └── data_backup.log           # Hourly backup logs
│
├── data/
│   ├── setupTemplates/
│   │   ├── pzuser-crontab            # Crontab to install
│   │   ├── pzuser-sudoers            # Sudo permissions
│   │   ├── zomboid.service           # Systemd service template
│   │   ├── zomboid.socket            # Systemd socket template
│   │   ├── zomboid_logger.service    # Systemd logger template
│   │   └── .env.example              # Environment variables template
│   │
│   ├── pzserver/                     # PZ server installation (~1-2GB)
│   │   ├── start-server.sh
│   │   ├── ProjectZomboid64.json
│   │   ├── java/
│   │   ├── linux64/
│   │   ├── natives/
│   │   └── jre64 -> /usr/lib/jvm/java-25-openjdk-amd64  (symlink)
│   │
│   ├── dataBackups/                  # Hourly backups (14-day retention)
│   │   ├── backup_2026-01-12_14h14m00s/
│   │   ├── backup_2026-01-12_15h14m00s/
│   │   └── latest -> backup_2026-01-12_15h14m00s  (symlink)
│   │
│   ├── fullBackups/                  # Timestamped complete backups
│   │   └── 2026-01-12_04-30/
│   │
│   └── versionning/                  # Installed versions history
│       └── pz_version_*.txt
│
├── docs/                             # Documentation
│   ├── QUICKSTART.md
│   ├── INSTALLATION.md
│   ├── CONFIGURATION.md
│   ├── SERVER_CONFIG.md
│   ├── ADVANCED.md
│   ├── TROUBLESHOOTING.md
│   ├── MIGRATION.md
│   └── WHAT_IS_INSTALLED.md          # This file
│
├── README.md
└── LICENSE
```

### Disk Space Used

**Minimal installation**:
- System: ~100MB (packages)
- PZ Server: ~1-2GB
- Java: ~300MB

**Initial total**: ~2-2.5GB

**Typical usage after 1 month**:
- Server data: 500MB - 5GB
- Hourly backups: 5-15GB (14 days)
- Complete backups: 5-10GB per backup
- Logs: 100-500MB

**Recommended total**: 50-100GB free disk

---

## Environment Variables

### .env File

**Location**: `/home/pzuser/pzmanager/scripts/.env`

**Automatically created** from `.env.example` on first run

**Main variables**:

#### User and Paths
```bash
PZ_USER="pzuser"
PZ_HOME="/home/pzuser/pzmanager"
PZ_SOURCE_DIR="${PZ_HOME}/Zomboid"
PZ_INSTALL_DIR="${PZ_HOME}/data/pzserver"
```

#### Java
```bash
JAVA_VERSION="25"
JAVA_PACKAGE="openjdk-25-jre-headless"
JAVA_PATH="/usr/lib/jvm/java-25-openjdk-amd64"
PZ_JRE_LINK="${PZ_INSTALL_DIR}/jre64"
```

#### SteamCMD
```bash
STEAMCMD_PATH="/usr/games/steamcmd"
STEAM_APP_ID="380870"
STEAM_BETA_BRANCH="legacy_41_78_7"
```

#### Backups
```bash
BACKUP_DIR="${PZ_HOME}/data/dataBackups"
BACKUP_LATEST_LINK="${BACKUP_DIR}/latest"
BACKUP_RETENTION_DAYS="30"
FULL_BACKUP_DIR="${PZ_HOME}/data/fullBackups"
```

#### Logs
```bash
LOG_ZOMBOID_DIR="${PZ_HOME}/scripts/logs/zomboid"
LOG_MAINTENANCE_DIR="${PZ_HOME}/scripts/logs/maintenance"
LOG_RETENTION_DAYS="30"
```

#### Service
```bash
PZ_SERVICE_NAME="zomboid.service"
```

#### Discord (optional)
```bash
DISCORD_WEBHOOK=""  # Empty = disabled
```

**Modify**: `nano /home/pzuser/pzmanager/scripts/.env`

---

## Default Configuration

### Project Zomboid Server

**File**: `/home/pzuser/pzmanager/Zomboid/Server/servertest.ini`

**Default parameters (first installation)**:

```ini
# General
ServerName=servertest
PublicName=My PZ Server
Password=                    # Empty = public server
AdminPassword=changeme       # ⚠️ MUST CHANGE!
MaxPlayers=32

# Gameplay
PauseEmpty=true              # Pause if no players
Open=true                    # Public server
Public=true                  # Visible in server list
PublicPort=16261
PublicDescription=

# Save
SaveWorldEveryMinutes=20
BackupsCount=5
BackupsOnStart=true
BackupsOnVersionChange=true

# Security
AllowCoop=true
SteamAuthenticationRequired=true
ResetID=0
```

**Complete documentation**: [docs/SERVER_CONFIG.md](SERVER_CONFIG.md)

---

## System Modifications

### Created/Modified Files

**Global system**:
- `/etc/sudoers.d/pzuser` (sudo permissions)
- `/var/lib/systemd/linger/pzuser` (systemd lingering)
- `/etc/apt/sources.list.d/steam.list` (SteamCMD repository)

**pzuser user**:
- `~/.config/systemd/user/zomboid.service` (service)
- Personal crontab (`crontab -l` to view)

**No modification of**:
- SSH configuration (`/etc/ssh/sshd_config`)
- Network configuration (`/etc/network/`)
- Global system services

### Security

**Principle**: Maximum isolation via dedicated user

**Restrictions**:
- pzuser cannot `su` to root
- Sudo commands strictly limited (see sudoers)
- Service runs in user mode (not root)
- No access to sensitive system files

**Firewall**: Active by default with strict whitelist

---

## Uninstallation

To completely remove pzmanager:

```bash
# As root

# 1. Stop and disable service
sudo -u pzuser systemctl --user stop zomboid.service
sudo -u pzuser systemctl --user disable zomboid.service
loginctl disable-linger pzuser

# 2. Remove crontab
sudo -u pzuser crontab -r

# 3. Remove files
rm -rf /home/pzuser/pzmanager

# 4. Remove user
userdel -r pzuser

# 5. Remove system configuration
rm /etc/sudoers.d/pzuser
rm /var/lib/systemd/linger/pzuser

# 6. (Optional) Remove packages
apt remove --purge steamcmd openjdk-25-jre-headless
apt autoremove
```

**Note**: UFW firewall rules remain active (manually remove if desired)

---

## References

- **Installation**: [INSTALLATION.md](INSTALLATION.md)
- **Configuration**: [CONFIGURATION.md](CONFIGURATION.md)
- **PZ Server**: [SERVER_CONFIG.md](SERVER_CONFIG.md)
- **Advanced**: [ADVANCED.md](ADVANCED.md)
- **Troubleshooting**: [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
