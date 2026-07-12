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
- `zip`: Archive creation (full backups)
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

### Dedicated User

**Created by**: `setupSystem.sh [username]` (default: `pzuser`)

**Properties**:
- Home: `/home/<PZ_USER>/`
- Shell: `/bin/bash`
- Groups: `<PZ_USER>` (primary group)

### sudo Permissions

**File**: `/etc/sudoers.d/<PZ_USER>` (generated from template with actual username and paths)

**Allowed commands** (NOPASSWD):

**APT (package management)** - specific commands only:
```
/usr/bin/apt-get update -qq
/usr/bin/apt-get upgrade -y -qq
/usr/bin/apt-get install -y -qq openjdk-25-jre-headless
/usr/bin/apt-get install -y -qq openjdk-21-jre-headless
/usr/bin/apt-get install -y -qq openjdk-17-jre-headless
/usr/bin/apt-get autoremove -y -qq
/usr/bin/apt-get autoclean -qq
```

**Backups** - read-only access:
```
/bin/cat /etc/sudoers.d/pzuser
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

**Version**: Build 42 (branch `unstable`)

**Installation method**:
```bash
/usr/games/steamcmd +force_install_dir /home/pzuser/pzmanager/data/pzserver \
    +login anonymous \
    +app_update 380870 -beta unstable validate \
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
    "-Djava.library.path=linux64/:natives/",
    "-Djava.security.egd=file:/dev/urandom",
    "-XX:-OmitStackTraceInFastThrow",
    "-Xmx7g",
    "-XX:+UseZGC",
    "-XX:+AlwaysPreTouch",
    "-XX:ZCollectionInterval=60",
    "-XX:+UseStringDeduplication",
    "-XX:+UseCompactObjectHeaders",
    "-Djava.net.preferIPv4Stack=true",
    "-XX:+HeapDumpOnOutOfMemoryError",
    "-XX:HeapDumpPath=.../scripts/logs/zomboid",
    "-Xlog:gc*:file=.../scripts/logs/zomboid/gc.log:...:filecount=5,filesize=20M"
  ]
}
```

**Optimizations**:
- **No `-Xms`**: removed — with `AlwaysPreTouch` the resident cost is the
  pre-touched `-Xmx`, and ZGC give-back never fires on this ever-growing
  workload. The heap starts at the ergonomic default and grows on demand.
- **Heap ceiling**: `-Xmx` = **`PZ_XMX_GB` GB if set in `.env`, else half of
  physical RAM** (computed at install; e.g. 7g on a 14 GiB machine). Real
  guardrail: clean Java OOM before the heap starves PZ's native memory + the OS.
- **Generational ZGC** (`-XX:+UseZGC`, generational by default on JDK 25) with
  `AlwaysPreTouch` and a 60s periodic major cycle — sub-millisecond GC pauses.
  (`ZCollectionInterval` forces a *major* collection at that interval; 60s keeps
  the cheap young collections frequent while making the majors rare, instead of
  the old 5s that ran a near-continuous, near-useless major pass.)
- **String deduplication** (`-XX:+UseStringDeduplication`): the heap is full of
  map cells with repeated sprite/tile strings; dedup trims the String live set.
- **Compact object headers** (`-XX:+UseCompactObjectHeaders`, JEP 519, product in
  JDK 25): shrinks every object header from ~12 to 8 bytes. The heap is millions
  of tiny map-cell objects, so this cuts ~10-20% of the live set — less resident
  RAM and a later OOM, plus slightly shorter GC pauses (fewer bytes to scan).
- **IPv4 stack** (`-Djava.net.preferIPv4Stack=true`): RakNet/UdpEngine stability.
- **Diagnostics**: heap dump on OOM + rotating GC log to `scripts/logs/zomboid/`.
- **Headless**: No GUI / **Steam**: integration enabled.

**Modify RAM**: set `PZ_XMX_GB` in `scripts/.env` (or edit `Xmx` in
`scripts/internal/configureJvm.sh`), run the script, and restart. The script
applies the tuning at install time and re-applies it after every SteamCMD update
(which restores the vanilla JSON) — a manual edit of `ProjectZomboid64.json`
would not survive the nightly maintenance. There is no `pzm config ram` command
(and no cgroup `MemoryMax`, which used to throttle/crash the server). See
[ADVANCED.md](ADVANCED.md#ram--jvm-configuration).

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

### Admin User

An `admin` user is automatically created during installation with a random 24-character password. This password is displayed once during installation - **save it immediately**.

- Username: `admin`
- Role: 7 (admin)
- Excluded from `pzm whitelist purge` (never deleted)

### Whitelist Schema

The whitelist uses `role` (integer) and requires `world='servertest'`:

| Role | Name | Description |
|------|------|-------------|
| 1 | banned | Cannot login |
| 2 | user | Standard player |
| 3 | priority | Login priority |
| 4 | observer | Spectator mode |
| 5 | gm | Game master |
| 6 | moderator | Moderator |
| 7 | admin | Full access |

**Important**: Role 1 is **banned** (not user!). New users must be added with role 2.

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
WorkingDirectory=%h/pzmanager/data/pzserver/
# Drains any stray "quit" left in the control FIFO (avoids a socket-activation flap)
ExecStartPre=/bin/sh -c "dd if=%h/pzmanager/data/pzserver/zomboid.control iflag=nonblock of=/dev/null 2>/dev/null; exit 0"
# Reads the one-shot admin password from ~/pzmanager/.admin_password and deletes it
ExecStart=/bin/sh -c "... exec .../start-server.sh -cachedir=%h/pzmanager/Zomboid $ADMIN_ARGS <> .../zomboid.control"
ExecStartPost=-/bin/sh -c "%h/pzmanager/scripts/internal/notifyServerReady.sh &"
ExecStop=/bin/sh -c "echo 'quit' > %h/pzmanager/data/pzserver/zomboid.control"
KillSignal=SIGCONT
TimeoutStopSec=120            # a large modded B42 save can take >30s to shut down cleanly
MemorySwapMax=0              # swap forbidden to the process (prevents micro-freezes/desync)

[Install]
WantedBy=default.target
```

**Features**:
- Automatic startup at boot
- Uses systemd socket for control pipe
- Admin password passed once via `.admin_password` (read then deleted by ExecStart)
- Discord notification at startup (via notifyServerReady.sh)
- Dedicated logger (zomboid_logger.service)
- Clean shutdown via 'quit' command (up to 120s)
- `MemorySwapMax=0`; **no** `MemoryMax`/`MemoryHigh` (a cgroup cap throttles/OOM-kills PZ)

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
ListenFIFO=%h/pzmanager/data/pzserver/zomboid.control
FileDescriptorName=control
SocketMode=0660
SocketUser=%u
ExecStartPre=/bin/rm -f %h/pzmanager/data/pzserver/zomboid.control
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
ExecStart=%h/pzmanager/scripts/internal/captureLogs.sh
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

### Systemd Timers

**Location**: `~/.config/systemd/user/`
**Templates**: `/home/pzuser/pzmanager/data/setupTemplates/pz-*.service` and `pz-*.timer`

**Configured timers**:

#### pz-modcheck.timer - Mod & server update check (every 5 minutes)

**Schedule**: Every 5 minutes after boot

**Function**:
- Checks Workshop mod updates via RCON `checkModsNeedUpdate`
- Checks for server updates by comparing installed build ID with latest available on SteamCMD (branch `unstable`)
- Triggers `performFullMaintenance.sh` (5m delay) if mod or server updates found
- Sends Discord notifications

**Lock**: Partage `/tmp/pzmanager-maintenance-<user>.lock` avec `pz.sh` et `performFullMaintenance.sh`. Skip silencieux si lock détenu.

**Logs**: `scripts/logs/mod_checks/mod_checks_YYYY-MM-DD.log` (7-day retention)

#### pz-backup.timer - Hourly backup

**Schedule**: Every hour at :14

**Function**:
- Incremental backup with hard links
- Retention: 14 days (configurable via `.env`)
- Destination: `/home/pzuser/pzmanager/data/dataBackups/`

#### pz-heapcheck.timer - Adaptive memory restart (every ~3 min)

**Schedule**: 5 min after boot, then 3 min after each run (`OnUnitInactiveSec`, so
it never overlaps its own execution or a restart warning).

**Function**:
- Reads the post-major-GC heap occupancy from `scripts/logs/zomboid/gc.log`.
- When it reaches `HEAP_RESTART_PERCENT` (`.env`, default 95), triggers
  `pzm server restart HEAP_RESTART_DELAY` (default `5m`, with a player warning).
- The heap fills with live map cells that nothing frees at runtime, so a restart
  is the only reclaim. Quiet server = no needless restart. See
  [ADVANCED.md](ADVANCED.md#memory-driven-restart-why-the-server-restarts-on-its-own).

**Service**: `pz-heapcheck.service` (oneshot, `TimeoutStartSec=1500` to cover the
warning countdown).

#### pz-maintenance.timer - Daily maintenance (4:30 AM)

**Schedule**: Daily at 04:30

**Steps**:
1. Server shutdown with warnings (30min default)
2. Backup rotation (deletion > 14 days)
3. System update (`apt upgrade`)
4. Java update
5. PZ server update (SteamCMD)
6. External complete backup
7. Machine reboot (if `REBOOT_ON_MAINTENANCE=true`) or service restart

**Logs**: `/home/pzuser/pzmanager/scripts/logs/maintenance/`

#### pz-creation-date-init.timer - Whitelist date init (midnight)

**Schedule**: Daily at 00:00

**Function**: Assigns creation date (yesterday) to whitelist accounts without one. Enables `pzm whitelist purge` to identify truly inactive accounts vs newly added ones.

**View timers**: `systemctl --user list-timers`

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
│   │   ├── triggerMaintenanceOnModUpdate.sh  # Auto-maintenance if mods or server need update
│   │   ├── manageWhitelist.sh        # SQLite whitelist management
│   │   ├── resetServer.sh            # Complete server reset
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
│   │   ├── configureJvm.sh           # JVM tuning (install + after each update)
│   │   ├── checkHeapAndRestart.sh    # Adaptive memory restart (pz-heapcheck)
│   │   └── notifyServerReady.sh      # Server startup notification
│   │
│   ├── discord/                      # Inbound /pzm command bot (Python/discord.py)
│   │   ├── bot.py
│   │   ├── run-bot.sh
│   │   └── requirements.txt
│   │
│   ├── lib/
│   │   └── common.sh                 # Sourced by every script (env, logging, locks)
│   │
│   └── logs/
│       ├── zomboid/                  # Captured server logs
│       ├── maintenance/              # Maintenance logs
│       └── data_backup.log           # Hourly backup logs
│
├── data/
│   ├── setupTemplates/
│   │   ├── pzuser-sudoers            # Sudo permissions
│   │   ├── zomboid.service           # Systemd service (server)
│   │   ├── zomboid.socket            # Systemd socket (RCON)
│   │   ├── zomboid_logger.service    # Systemd logger
│   │   ├── pz-backup.service/timer   # Hourly backup automation
│   │   ├── pz-modcheck.service/timer # Mod update check automation
│   │   ├── pz-heapcheck.service/timer  # Adaptive memory-driven restart
│   │   ├── pz-maintenance.service/timer  # Daily maintenance automation
│   │   ├── pz-creation-date-init.service/timer  # Whitelist date init
│   │   ├── pz-discord-bot.service    # Inbound /pzm command bot
│   │   └── .env.example              # Environment variables template
│   │
│   ├── pzserver/                     # PZ server installation (~1-2GB)
│   │   ├── start-server.sh
│   │   ├── ProjectZomboid64.json
│   │   ├── java/
│   │   ├── linux64/
│   │   ├── natives/
│   │   └── jre64/                     # Embedded JRE (managed by SteamCMD)
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
│   ├── USAGE.md
│   ├── CONFIGURATION.md
│   ├── SERVER_CONFIG.md
│   ├── ADVANCED.md
│   ├── DISCORD_BOT.md
│   ├── TROUBLESHOOTING.md
│   ├── PROCEDURE_JOUEURS.md
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
PZ_HOME="/home/pzuser"
PZ_MANAGER_DIR="${PZ_HOME}/pzmanager"
PZ_DATA_DIR="${PZ_MANAGER_DIR}/data"
PZ_SOURCE_DIR="${PZ_MANAGER_DIR}/Zomboid"
PZ_INSTALL_DIR="${PZ_DATA_DIR}/pzserver"
```

#### Java
```bash
JAVA_VERSION="25"
JAVA_PACKAGE="openjdk-25-jre-headless"
JAVA_PATH="/usr/lib/jvm/java-25-openjdk-amd64"
```

#### SteamCMD
```bash
STEAMCMD_PATH="/usr/games/steamcmd"
STEAM_APP_ID="380870"
STEAM_BETA_BRANCH="unstable"
```

#### Backups
```bash
BACKUP_DIR="${PZ_DATA_DIR}/dataBackups"
BACKUP_LATEST_LINK="${BACKUP_DIR}/latest"
BACKUP_RETENTION_DAYS="14"
SYNC_BACKUPS_DIR="${PZ_DATA_DIR}/fullBackups"
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

#### Whitelist
```bash
WHITELIST_PURGE_DAYS=90   # auto-remove access after this many inactive days (keeps character)
```

#### Maintenance
```bash
REBOOT_ON_MAINTENANCE=true   # true = reboot machine, false = restart service only
```

#### Memory / heap restart
```bash
HEAP_RESTART_PERCENT=95      # restart when post-GC heap reaches this % of -Xmx
HEAP_RESTART_DELAY="5m"      # player warning before the restart
#PZ_XMX_GB=8                 # override -Xmx (GB); empty = half of physical RAM
```

#### Discord (optional)
```bash
DISCORD_WEBHOOK=""              # outbound webhook; empty = disabled
DISCORD_BOT_TOKEN=""            # inbound /pzm command bot; empty = disabled
DISCORD_BOT_DEATH_CHANNEL_ID="" # channel for death / PvP embeds; empty = off
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
- `~/.config/systemd/user/zomboid.service` (server)
- `~/.config/systemd/user/pz-*.service` and `pz-*.timer` (automations)

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

# 1. Stop and disable services
sudo -u pzuser systemctl --user stop zomboid.service pz-backup.timer pz-modcheck.timer pz-heapcheck.timer pz-maintenance.timer pz-creation-date-init.timer pz-discord-bot.service
sudo -u pzuser systemctl --user disable zomboid.service pz-backup.timer pz-modcheck.timer pz-heapcheck.timer pz-maintenance.timer pz-creation-date-init.timer pz-discord-bot.service
loginctl disable-linger pzuser

# 2. Remove files
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

- **Quick Start**: [QUICKSTART.md](QUICKSTART.md)
- **Usage**: [USAGE.md](USAGE.md)
- **Configuration**: [CONFIGURATION.md](CONFIGURATION.md)
- **PZ Server**: [SERVER_CONFIG.md](SERVER_CONFIG.md)
- **Troubleshooting**: [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
