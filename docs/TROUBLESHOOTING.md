# Troubleshooting Guide

Guide to resolving common issues with pzmanager.

## Table of Contents

- [Server Won't Start](#server-wont-start)
- [Cannot Connect](#cannot-connect)
- [Server Crashes Regularly](#server-crashes-regularly)
- [Complete Server Reset](#complete-server-reset)
- [Backups Not Working](#backups-not-working)
- [Restore Zomboid Data](#restore-zomboid-data)
- [Discord Notifications Failing](#discord-notifications-failing)
- [Permission Errors](#permission-errors)
- [Insufficient Disk Space](#insufficient-disk-space)
- [Performance Issues](#performance-issues)
- [Getting Help](#getting-help)

## Server Won't Start

### Check Service Status

```bash
# En tant que l'utilisateur du serveur (pzuser par défaut)
systemctl --user status zomboid.service
journalctl --user -u zomboid.service -n 100
```

### Common Causes

**Java not found**
```bash
# B42 uses its own embedded JRE in data/pzserver/jre64/
# (may be a symlink to GraalVM if PZ_GRAALVM_HOME is set — see ADVANCED.md;
#  the real bundled JRE is then kept as data/pzserver/jre64.stock)
# If missing, re-validate the server installation:
pzm admin maintenance now
```

**Permission denied**
```bash
# Check permissions
ls -la ~/pzmanager/data/pzserver/

# Fix if necessary
sudo chown -R $USER:$USER ~/pzmanager
```

**Port already in use**
```bash
# Check ports
sudo netstat -tulpn | grep 16261

# If occupied, kill conflicting process
sudo kill <PID>
```

## Cannot Connect

### Check Firewall

```bash
sudo ufw status verbose
# Should show: 16261/udp, 16262/udp ALLOW  — and nothing else for the game
```

**Open ports manually**
```bash
sudo ufw allow 16261/udp
sudo ufw allow 16262/udp
```

> **Do not open 8766 or 27015.** Those are B41-era leftovers. Verified in
> production on B42 (`ss -lnup` on the JVM's pid): the server listens on
> **16261/udp and 16262/udp only**. RCON-over-TCP is unused here (`RCONPassword`
> is empty — control goes through the `zomboid.control` FIFO), and Steam
> discovery happens over the game port. Opening them adds attack surface for
> services that do not exist.

### Check Server Listening

```bash
ss -lnup | grep -i java     # or: sudo netstat -tulpn | grep java
# Should show java on 16261/udp and 16262/udp only
```

### External Network Test

From another computer:
```bash
nc -vuz YOUR_SERVER_IP 16261
```

### Public Server

- Check NAT/port forwarding on your router
- Check firewall rules from your hosting provider (AWS, OVH, etc.)

### Private Server

- Use direct IP in Project Zomboid
- No need to be in the server browser

## Stop ends in `Failed with result 'timeout'`

The server did not exit on its own and systemd SIGKILLed it after
`TimeoutStopSec` (120 s). **The usual cause is not a slow save — it is a `quit`
that was never read.**

Server control is a FIFO: `ExecStop` writes `quit` into
`data/pzserver/zomboid.control` and the game's console thread reads it.
`KillSignal=SIGCONT` is deliberate — systemd never sends SIGTERM, so if that
`quit` is not processed there is **nothing else** that will stop the server, and
the 120 s wait always ends in a SIGKILL. Raising `TimeoutStopSec` does not help;
it only makes the wait longer.

Note that writing to the FIFO **succeeds** even when nobody is reading: a pipe
accepts data into its 64 KB buffer regardless. So "the command was sent" tells you
nothing.

### Telling the two apart

```bash
# Did the game acknowledge ANY console command during the stop?
journalctl --user -u zomboid.service --since "<stop>" --until "<sigkill>" \
  | grep -c 'command entered via server console'
```

- **≥ 1, plus `QueuedQuit` / `Shutdown handling finished`** → the quit *was*
  received and the save genuinely ran long. That is the case where a longer
  timeout would help.
- **0, and no game output at all** → the console reader was not consuming the
  FIFO. The stop was never going to work.

Cross-check the black box (`logs/zomboid/monitoring.csv`): a real save burns CPU
and logs; a dead console shows an idle process writing nothing.

### Third case: the server never finished booting

Before concluding "the console died", check the **frame counter** `f:` that
prefixes every game log line. It stays at `f:0` for the whole startup and only
reaches `f:1` when the game loop actually begins:

```bash
# Did this session ever reach its first frame?
journalctl --user -u zomboid.service --since "<Started>" | grep -m1 'f:1 st:'
```

No `f:1` means the game loop never started — the server was still loading, and a
`quit` sent then cannot be executed no matter how long you wait. The startup
phase that immediately precedes `f:1` is a burst of
`SpriteConfig.initObjectInfo` lines; if the session has none, it never got that
far. This is what actually happened on 2026-09-02
(see [INCIDENTS.md](INCIDENTS.md#2026-09-02--a-stop-that-could-not-be-executed)).

**Do not add a boot-duration timer for this.** Healthy boots on this machine
range from **79 s to 44 min** — the long ones follow a SteamCMD update, and they
are indistinguishable from a hung one by duration alone. What *does* separate
them is the console: across a healthy 44-minute boot the game acknowledged
**every one** of `pz-modcheck`'s nine probes, while the hung boot answered once
and then went silent. Console silence, not elapsed time, is the signal — and it
is already covered by the alert described below, which is not gated on the
server being ready.

### A mute console and a frozen game loop are not the same failure

The game echoes `command entered via server console` from its **console thread**,
which keeps running while the main loop is stuck. So a probe that gets no answer
has two very different causes, and the echo tells them apart:

| Echo present? | Result returned? | Diagnosis |
|---|---|---|
| no | no | the console is not reading the FIFO — a genuinely dead console |
| **yes** | no | the console reads fine; the **game loop** is frozen and never executes the command |

Both end the same way — the `quit` is not executed and systemd SIGKILLs at 120 s —
but they point at different things to investigate. On 2026-09-03 at 19:08 it was
the second case: the `quit` *was* acknowledged, while the frame counter had been
pinned at `f:88543` since 18:59. `pzm server stop|restart` now names whichever it
actually is, and prints the frozen frame number.

### Catching it before you need the stop

`pz-modcheck` writes a command into the FIFO every 5 minutes and waits for the
answer — a free liveness probe. When the console stops answering,
`logs/mod_checks/mod_checks_<date>.log` records `console muette`, and after
`CONSOLE_SILENT_ALERT_AFTER` consecutive silent passes (default 3, ~15 min) the
Discord webhook is warned that a clean stop is no longer possible.

`pzm server stop|restart` also probes the console before acting and says so
explicitly when it is unresponsive — including that the in-game warnings will not
reach anyone either, since they travel through the same channel.

### Recovering

The SIGKILL means no final save. The hourly snapshot is your restore point
(`pzm backup list`), and with `SaveWorldEveryMinutes=0` that is up to one hour of
world state. Player characters are written more often and usually survive.

## Server Crashes Regularly

### Check Resources

```bash
# Available RAM
free -h

# Disk space
df -h

# CPU load
top
```

### Common Causes

**Insufficient RAM** (< 4GB)
- Reduce MaxPlayers in servertest.ini
- Increase server RAM
- Disable mods

**Full Disk** (< 10GB free)
- Reduce backup retention
- Manually clean old backups

**Too Many Mods**
- Disable mods one by one to identify the issue
- Check mod compatibility

### Analyze Crashes

```bash
# Complete logs of last crash
pzm server status

# System logs
sudo journalctl -xe
```

## Complete Server Reset

Last resort for irreparable world corruption, a complete rules/mods change, or
persistent degraded performance that nothing else fixes.

```bash
pzm admin reset
```

> ⚠️ **Deletes all current data, with no confirmation prompt.** A backup is
> written to `~/OLD/Zomboid_OLD_TIMESTAMP/` first, and `--keep-config` /
> `--keep-whitelist` preserve configs and player access.

Procedure and options: [ADVANCED.md — Complete Server Reset](ADVANCED.md#complete-server-reset).

## Player Character Won't Load

Symptom: a player connects and is told *"the server cannot load player data"* / asked
to **recreate** a character. This is usually a **load** failure (the character is still
in `players.db`), most often after a mod that adds character data was removed — see the
mod gotcha in [CLAUDE.md](../CLAUDE.md). First, restore the missing mod and restart.

If the character row was actually lost/overwritten, restore just that one character
from a backup (no full-world rollback):

```bash
pzm server stop 2m --reason "Restauration perso"   # server MUST be stopped
pzm backup restore-character <name> backup_YYYY-MM-DD_HHhMMmSSs
pzm server start
```

`<backup>` is required (the folder name under `data/dataBackups/`, or a full path). The
player's current character is **overwritten** by the backup's; the stop already makes a
backup, so you can roll back if needed. See [USAGE.md](USAGE.md#backups).

## Backups Not Working

### Check Timers

```bash
systemctl --user list-timers
# Should show pz-backup, pz-maintenance, pz-modcheck, pz-heapcheck, pz-creation-date-init
```

**Re-enable timers**:
```bash
systemctl --user enable --now pz-backup.timer pz-maintenance.timer pz-modcheck.timer pz-heapcheck.timer pz-creation-date-init.timer
```

### Check Timer Logs

```bash
journalctl --user -u pz-backup.service -n 20
```

### Manual Test

```bash
# Test hourly backup
pzm backup create

# Check result
ls -la ~/pzmanager/data/dataBackups/
```

### Disk Space

```bash
du -sh ~/pzmanager/data/dataBackups/*
```

If too large, shorten the GFS daily tier (`BACKUP_GFS_DAILY_DAYS`, default 30) or the off-site ZIP count (`OFFSITE_BACKUP_COUNT`, default 7) in `.env`.

## Restore Zomboid Data

### Targeted Restoration (game data only)

**When to use**: Corrupted world, rollback to old save, test old version.

```bash
# List available backups
./data/scripts/backup/restoreZomboidData.sh

# Restore specific backup
./data/scripts/backup/restoreZomboidData.sh data/dataBackups/backup_2026-01-11_14h15m00s

# Restore latest backup
./data/scripts/backup/restoreZomboidData.sh data/dataBackups/latest
```

**How it works**:
- Creates safety backup of current Zomboid (`ZomboidBROKEN_TIMESTAMP`)
- Restores only Zomboid data (Saves, db, Server)
- Preserves system configuration and scripts

**Apply**:
```bash
pzm server restart 2m
```

### Complete Restoration (system + data)

**When to use**: System crash, server migration, complete reconfiguration.

```bash
# List complete backups (one ZIP per backup)
ls -lt ~/pzmanager/data/fullBackups/

# Restore everything (pass the .zip; older dir-format backups still work too)
sudo ./data/scripts/install/configurationInitiale.sh restore ~/pzmanager/data/fullBackups/2026-01-11_04-30.zip
```

**Restores**: Sudoers, SSH, systemd services/timers, scripts, .env, Zomboid data.

### Comparison

| Type | Scope | Safety Backup | Usage |
|------|-------|---------------|-------|
| `restoreZomboidData.sh` | Game data | ✅ Yes | World/save issue |
| `configurationInitiale.sh restore` | Complete system | ❌ No | System crash, migration |

## Discord Notifications Failing

### Manual Test

```bash
./data/scripts/internal/sendDiscord.sh "Test message"
```

**If no message received**:
1. Check webhook URL in .env
2. Check that webhook still exists in Discord
3. Check that channel hasn't been deleted

### Check Configuration

```bash
cat .env | grep DISCORD_WEBHOOK
# Should not be empty if Discord enabled
```

### Invalid Webhook

- Recreate webhook in Discord (Server Settings → Integrations → Webhooks)
- Copy new URL to .env

## Permission Errors

### Reset Permissions

```bash
# Entire project
sudo chown -R $USER:$USER ~/pzmanager

# Executable scripts
chmod +x ~/pzmanager/data/scripts/*.sh

# SSH (if configured)
chmod 700 ~/.ssh
chmod 600 ~/.ssh/* 2>/dev/null
```

### Invalid Sudoers

```bash
# Check file
# Le sudoers est maintenant installé automatiquement par setupSystem.sh
# Pour réinstaller manuellement :
sudo ~/pzmanager/data/scripts/install/setupSystem.sh $USER
```

## Insufficient Disk Space

### Identify Usage

```bash
du -sh ~/pzmanager/*
du -sh ~/pzmanager/data/*
```

### Clean Backups

```bash
# Manually delete old backups
rm -rf ~/pzmanager/data/dataBackups/backup_YYYY-MM-DD*
rm -rf ~/pzmanager/data/fullBackups/YYYY-MM-DD*

# Or reduce retention (GFS tiers + off-site count)
nano .env
# Modify: BACKUP_GFS_DAILY_DAYS=14   (shorter daily tier)
#         OFFSITE_BACKUP_COUNT=3     (fewer off-site ZIPs)
```

### Clean Logs

```bash
# Delete old logs
find ~/pzmanager/logs -type f -mtime +7 -delete
```

### Purge APT

```bash
sudo apt-get autoclean
sudo apt-get autoremove
```

## Performance Issues

### Significant Lag

**Reduce save frequency**
```ini
# In Zomboid/Server/servertest.ini
SaveWorldEveryMinutes=60  # Instead of 30
```

**Limit players**
```ini
MaxPlayers=16  # Instead of 32
```

**Enable pause if empty**
```ini
PauseEmpty=true
```

### Java Heap Too Small (OutOfMemoryError)

JVM args live in `ProjectZomboid64.json` (the `vmArgs` array), not in the
systemd service. They are written by `data/scripts/internal/configureJvm.sh`, which
re-applies them after every SteamCMD update — edit the script, not the JSON
(a manual JSON edit is overwritten by the nightly maintenance):

```bash
# Simplest: set the heap size in .env, then apply and restart
nano ~/pzmanager/.env        # uncomment / set: export PZ_XMX_GB=8
~/pzmanager/data/scripts/internal/configureJvm.sh
pzm server restart 5m
```

There is no `-Xms` (removed); `-Xmx` defaults to half of physical RAM unless
`PZ_XMX_GB` is set. Full model: [ADVANCED.md](ADVANCED.md#ram--jvm-configuration).

> ⚠️ Keep `-Xmx` at roughly half of physical RAM. PZ B42 modded uses 6-9 GB of
> native memory *on top of* the Java heap, and with `AlwaysPreTouch` the whole
> `Xmx` is resident from boot; an `Xmx` close to total RAM will exhaust the
> machine and trigger a brutal Linux OOM-kill instead of a clean Java OOM.
> Do **not** add a cgroup `MemoryMax`/`MemoryHigh` — it throttles/crashes PZ at
> the cap.

> **Note:** a `java.lang.OutOfMemoryError: Java heap space` after ~15 h of uptime
> is expected on a large explored map — the heap fills with live map cells that
> nothing can free at runtime. pzmanager restarts the server automatically before
> this (see [ADVANCED.md](ADVANCED.md#memory-driven-restart-why-the-server-restarts-on-its-own)).
> Raising `Xmx` only delays it.

## Getting Help

If the issue persists:

1. **Check logs**: `pzm server status`
2. **Consult docs**: [QUICKSTART.md](QUICKSTART.md), [CONFIGURATION.md](CONFIGURATION.md)
3. **Open an issue** on GitHub with:
   - OS version (Debian/Ubuntu)
   - Relevant logs
   - Configuration (.env without secrets)
   - Steps to reproduce the issue
