# Usage Guide

All `pzm` commands. Run as `pzuser`.

```bash
su - pzuser
```

## Server

```bash
pzm server start              # Start
pzm server stop [delay]       # Stop (default: auto)
pzm server restart [delay]    # Restart (default: auto)
pzm server status             # Status + logs
```

**Delays**: `30m`, `15m`, `5m`, `2m`, `30s`, `now`, `auto`

`auto` is the default and picks the delay from the number of connected players:
**5m** if 2 or more, **2m** if 1, **now** if none — so an empty server restarts
without a pointless countdown.

**Always pass `--reason`** on `start`/`stop`/`restart`: the text is shown to
players in the in-game warning and on Discord. Without it the message only says
whether the action was manual or automatic. A delay token must come *before* it:

```bash
pzm server restart 5m --reason "Adding mods"
pzm server stop now --reason "Emergency" --silent   # --silent = no Discord post
```

**Send a message to connected players**:
```bash
pzm rcon servermsg "Message to players"
```

### Never double-issue a stop or restart

A second `stop`/`restart` launched while one is already running is **refused** —
an `flock` (`acquire_serverctl_lock_or_die` in `pz.sh`) holds for the whole
operation, warnings included. Two reasons this matters:

- A `quit` sent while B42 is still **loading the map** crashes the boot
  (`NullPointerException zombie.iso.IsoMetaGrid.save`, grid = null) and leaves the
  server in a crash-loop. That is the 2026-07-20 incident: a second restart issued
  during the first one's boot.
- Before acting, the shutdown path waits until the **game loop is actually
  running**, which it reads from the frame counter `f:` that prefixes every game
  log line: `f:0` for the whole startup, `f:1` at the first tick.

Two earlier versions of that wait were wrong, both discovered on 2026-09-02:

- It watched `LuaNet: Initialization [DONE]`, which the game emits **at `f:0`**,
  before the first tick — it was present in a session whose game loop never
  started at all, with three players connected. That is precisely the window
  where a `quit` crashes B42, so the marker alone could never have guarded it.
- It **short-circuited once the service had been active longer than 240 s**, on
  the assumption that anything older than that must be booted. Healthy boots here
  run from 79 s to 44 min, and the 2026-09-02 stop went out after 829 s to a
  server that had never ticked. Reading the frame counter with `journalctl -n`
  costs the same on a four-hour uptime as on a fresh boot (measured: 60 ms), so
  the shortcut is gone rather than retuned.

**The frame counter only advances while players are connected.** On an empty
server it can stay at `f:0` indefinitely. This makes readiness conservative: the
wait may time out on a healthy empty server, and the online announcement is not
sent until a frame advances. The instantaneous player count cannot safely
resolve that ambiguity because a stuck boot can also have zero players, or can
become empty after players disconnect. The premature Lua marker is therefore
never combined with the player count as proof that the loop started.

While it genuinely waits, it prints progress, so a stop issued during a boot does
not look frozen. If the game loop still has not started after 300 s, the stop or restart is
refused. A healthy empty server and a stuck boot cannot be distinguished by
`f:0` alone; timing out must not turn that uncertainty into an automatic kill.
Inspect the journal before deciding whether a direct systemd stop is appropriate
(it may end in SIGKILL without a final save).

## Backups

```bash
pzm backup create             # Incremental backup
pzm backup full               # Complete backup
pzm backup list               # List backups
pzm backup restore <path>     # Restore ALL data from a backup
pzm backup restore-character <name> <backup>   # Restore ONE player's character (overwrites existing)
pzm backup restore-zone <backup> <x1> <y1> <x2> <y2> [--apply] [--save <world>]
                              # Preview/restore whole 8x8 map chunks (tile coordinates)
```

Example:
```bash
pzm backup restore data/dataBackups/backup_2026-01-12_14h14m00s
```

**Restore a single character** (e.g. a player lost their character after a mod
change while their whitelist access is intact — no full-world rollback needed):
```bash
pzm server stop 2m --reason "Restauration perso"   # server MUST be stopped (the stop already makes a backup)
pzm backup restore-character Snardat backup_2026-06-23_23h15m29s
pzm server start
```
- `<name>`: the player's username (case-sensitive).
- `<backup>`: **required** — the backup folder name (resolved under `data/dataBackups/`)
  or a full path. Use a specific backup from **before** the incident.
- The player's current character is **overwritten** by the one from the backup. No extra
  snapshot is taken — `pzm server stop` already backs up before stopping.

### Restore a map zone (Build 42)

Restore one map chunk or a rectangle of chunks to recover disappeared constructions from an older **directory snapshot** listed by
`pzm backup list`. Coordinates are world **tiles**, not cells or chunks; give the
X/Y of each of two opposite corners, in either order. Bounds are inclusive.

To find a location, open the [Project Zomboid map](https://pzmap.org/), select
Build 42 and set **Coordinate Display → Tile**. Read X/Y at each corner of
the area. Use tile coordinates rather than the Cell or Chunk display values;
check the effective bounds printed by the preview before applying.

```bash
pzm backup restore-zone backup_2026-10-12_10h00m00s 10500 9500 10540 9540
pzm server stop 2m --reason "Restauration de constructions"
pzm backup restore-zone backup_2026-10-12_10h00m00s 10500 9500 10540 9540 --apply
pzm server start now --reason "Restauration de constructions terminée"
```

For **one chunk**, repeat the coordinates of any tile inside it. For example,
this previews the chunk containing tile `10500,9500`; add `--apply` after stopping
the server to restore it:

```bash
pzm backup restore-zone backup_2026-10-12_10h00m00s 10500 9500 10500 9500
```

This selects the whole chunk (tiles `10496..10503`, `9496..9503`), on every floor.
Supply tile coordinates, even for a single chunk; do not pass chunk indices.

The first command previews without modifying the map, even while the server runs.
`--dry-run` also explicitly selects preview. `--apply` requires a proven stopped
server and takes the same world lock as start, backup, wipe and full restore.
Use `--save <world>` if there are several multiplayer worlds. The source must
contain `Saves/Multiplayer/<world>/map/`; ZIP archives and Build 41 are unsupported.
A snapshot name under `BACKUP_DIR`, its `latest` alias, or a full directory path
is accepted. Prefer a dated snapshot from before the disappearance.

The preview prints the **actual rectangle expanded to 8×8 chunk boundaries**.
All floors, terrain, constructions and container contents in those chunks return
to the snapshot, including changes made since that snapshot. Terrain outside
these chunks is untouched. Stale isoregion caches in the selected chunks are
replaced or removed if absent from the source. Cell-wide chunkdata, metagrid,
zombie/animal populations, global files, characters and vehicles are not restored.
This targets construction loss; it is not a complete rewind of all activity in
the rectangle, nor a fix for a mod or save bug that continues to remove buildings.

Every selected terrain chunk must exist and be nonempty in the source. Missing
chunks cause refusal before any write. `WorldDictionary.bin`
must be present and byte-identical in both worlds. If `map_ver.bin` exists, it
must match too; current Build 42 saves can omit it. Every source terrain chunk
must have a valid world-version-249 header, length and CRC32 checksum. Different
versions or object ID dictionaries cannot be safely mixed. This conservative check may reject older
snapshots after a dictionary update. Do not overwrite the live global dictionary
to bypass the refusal. Keep the same mods; binary map contents are copied, not
validated by loading the game. Verify the recovered construction in game.

Before writing, the command stages the selected source files and copies the
current selected files into a private, unique `${PZ_HOME}/OLD/zone-rollback-*`
directory. The path is printed. It is retained independently of hourly snapshot
retention and consumes space until manually removed. `manifest.json` records the
selected files, files absent before the operation, and completion status;
`before/Saves/Multiplayer/<world>/` holds the recovery copies. Ordinary write
failures and handled interruption trigger restoration of files already touched.
A power loss or forced kill can leave a partial operation: keep the server stopped
and use those copies and the manifest to recover (restore listed previous files,
remove only the listed `absent_before` files). Individual replacements are atomic,
but the whole rectangle is not one filesystem transaction. A failed recovery
retains all copies for operator intervention. The source snapshot and hardlinked
backups are never modified by the restore.

Discord exposes the same operation as `/pzm backup restore-zone`, with `backup`,
`x1`, `y1`, `x2`, `y2`, optional `monde`, and `appliquer` (false by default).

Offline validation of real snapshots can use `tests/ValidateRestoredTerrain.java`
with the installed game JAR and a compatible JDK (`javac --release` matching the
chosen JVM). Run it from a private directory containing read-only access to the
matching `media/` and `stdlib.lua`, with `CHUNK_PATH CHUNK_X CHUNK_Y` as arguments.
It reads the copied world's dictionary and calls the genuine terrain record
loader, then reports object, thumpable, floor and door counts. It never starts a
server, regenerates terrain or saves a world. Compare baseline/restored counts
and exact chunk bytes, and verify that changes outside the rectangle are absent.
This minimal probe does not initialize Workshop scripts or render tiles; some
chunks need a fully initialized game environment. A successful probe validates
only its selected records, not every possible mod or world combination.

## Whitelist

Build 42 (≥ 42.13.2) gates access by **SteamID** (`Open=false`): only SteamIDs in
the allow-list can connect, and players pick their own password on first login.
`add`/`remove` drive the server console, so **the server must be running**.

```bash
pzm whitelist list                                  # Allowed SteamIDs + accounts + bans
pzm whitelist add "76561198012345678" "Name"        # Authorize a SteamID (name optional)
pzm whitelist remove "76561198012345678"            # Remove a SteamID's access (SteamID64 only)
pzm whitelist remove "76561198012345678" --ban      # Remove + permanent ban
pzm whitelist remove-account "Name" [--dry-run]     # Delete ONE account, keep the SteamID
pzm whitelist rename-account "Old" "New" [--dry-run]  # Rename an account, keep its character
pzm whitelist resetpassword "Name"                  # Reset a player's password
pzm whitelist purge                                 # List inactive (default: WHITELIST_PURGE_DAYS)
pzm whitelist purge 3m                              # List inactive 3+ months
pzm whitelist purge 3m --delete                     # Delete inactive after confirmation
```

### SteamID vs account

A SteamID can carry **two accounts** (B42's limit), and an account is not a
character — so removal happens at two levels, kept apart by the `-account`
suffix:

| Command | Acts on | Removes | Keeps | Server |
|---|---|---|---|---|
| `remove <id64>` | the **SteamID** | its access — so **every account** on it | the characters | running |
| `remove-account <name>` | **one account** | that login | the characters, and the SteamID if another account still uses it | **stopped** |
| `rename-account <old> <new>` | **one account** | nothing | everything — renames the login, re-attaches the character | **stopped** |

`remove` takes a **SteamID64 only, never a name**: `remove <name>` would read as
"remove this player" but would cut the SteamID's access, dropping the *other*
account sharing it too. To act on one account of a shared SteamID (say
`Cerensz PNJ` while keeping `Snardat`), use `remove-account`. Passing a name to
`remove` is refused, with the two exact commands printed.

**None of them deletes a character.** Characters live in `players.db` and are
only touched by `rename-account` (re-attach) and `backup restore-character`. A
player whose access is removed and later re-authorized gets their character back.

`remove-account`, `rename-account` and `purge --delete` write straight to the
world database, which the server holds open while running: they refuse to run
unless it is stopped, and snapshot the databases first. Use `--dry-run` to see
the plan without stopping anything.

**Player onboarding**: see [PROCEDURE_JOUEURS](PROCEDURE_JOUEURS.md) (French) — the
player sends their SteamID64, you authorize it, they connect and set their own password.

**Notes**:
- Steam ID 64: 17 digits starting with `7656119...` ([steamid.xyz](https://steamid.xyz/))
- `--ban` adds a permanent `banid` — the player can't return even renamed.
- `purge` here is the manual, interactive variant (lists/deletes `whitelist` rows only).
- Purge: Xm (months) or Xd (days), default in .env

### Automatic access purge

Accounts inactive ≥ `WHITELIST_PURGE_DAYS` (default 90) have their access removed
**automatically, on every server start** — the account first, then its SteamID
**only if no remaining account still uses it**. The **character is always kept**,
and the built-in `admin` account is always spared.

It runs from `zomboid.service`'s `ExecStartPre`, just before the game launches:
that is the only moment guaranteed world-closed on *every* start path (boot,
`pzm server start/restart`, socket-activation), and the purge writes straight to
the world database. A failed purge never blocks the server from starting.

Inspect it at any time — this touches nothing, even with the server up:

```bash
data/scripts/admin/purgeInactivePlayers.sh --force --dry-run --days 60
```

It prints, per account, whether the SteamID would be released or kept because
another account shares it.

Safety net: when the pre-start snapshot is skipped (ExecStartPre running under
the starter's world lock), the purge copies the world DB to
`<db>.pre-purge-<timestamp>` (verified `integrity_check=ok`) instead — and that
filet is **kept** after a successful purge (only the 3 most recent are retained,
older ones are pruned), so a bad purge can still be rolled back by hand.

## Administration

```bash
pzm admin reset                                    # Full reset (new world)
pzm admin reset --keep-config                      # Reset, keep configs/mods
pzm admin reset --keep-whitelist                   # Reset, keep whitelist
pzm admin reset --keep-config --keep-whitelist     # Reset, keep everything
pzm admin maintenance [delay]                      # Manual maintenance (default: 30m)
pzm admin maintenance 2m --reason "RAM upgrade"    # Maintenance with reason
```

**Maintenance options**:
- `[delay]`: `30m`, `15m`, `5m`, `2m`, `30s`, `now` (default: 30m)
- `--reason TEXT`: Add reason to messages (optional)

**Message formats by action type**:

Only the **first** warning carries the `@here` ping and the reason; the
following ones are bare. The `@here` goes to Discord only, never to the in-game
chat.

*Manual maintenance* (`pzm admin maintenance 2m --reason "RAM upgrade"`):
```
@here ATTENTION : MAINTENANCE DANS 2 MINUTES ! (Lancé manuellement - RAM upgrade)
ATTENTION : MAINTENANCE DANS 30 SECONDES !
DÉBUT MAINTENANCE
```

*Automatic maintenance - mods detected*:
```
@here ATTENTION : MAINTENANCE DANS 5 MINUTES ! (Lancé automatiquement - Mods mis à jour)
ATTENTION : MAINTENANCE DANS 30 SECONDES !
DÉBUT MAINTENANCE
```

If the machine reboots afterwards (`REBOOT_ON_MAINTENANCE`), a final
`Maintenance terminée - Redémarrage machine` is posted to Discord.

*Simple stop* (`pzm server stop 2m`):
```
@here ATTENTION : ARRÊT DANS 2 MINUTES !
ATTENTION : ARRÊT DANS 30 SECONDES !
ARRÊT
```

*Simple restart* (`pzm server restart 2m`):
```
@here ATTENTION : REDÉMARRAGE DANS 2 MINUTES !
ATTENTION : REDÉMARRAGE DANS 30 SECONDES !
REDÉMARRAGE
```

## Configuration

RAM is set automatically (`-Xmx` = `PZ_XMX_GB` GB if set in `.env`, else half of
physical RAM rounded up to GiB and capped at 16 GiB; no `-Xms`) at install time and re-applied after every server
update; it is not tunable via a command. The server also restarts itself when the
heap fills up or aggregate resident PZ process memory reaches18 GiB. The shared systemd `pz.slice`
`MemoryMax=20G` hard cap covers game, bot, backups and management tasks; an
OOM can kill a PZ process without saving. See
[ADVANCED.md](ADVANCED.md#ram--jvm-configuration).

## RCON

`pzm mods check [candidate.ini or V[N].txt]` checks whether the saved world's
client scripts require a mod missing from the proposed list. With no argument,
it checks the live configuration without changing it. See [Mod Updates](MOD_UPDATES.md).

ProjectWriting startup cleanup caches only unchanged files containing no Writing
data, in `data/dataBackups/projectwriting-cleanups/scan-cache.json`. The first
successful scan populates the cache. Later scans compare file device, inode,
size, modification time and change time; changed/replaced files are read again.
Files modified less than two seconds before the initial observation are neither
skipped nor added to the cache: ext4/tmpfs writes within one kernel tick can keep
the same timestamps. This age is fixed before stat/read, so a slow read cannot
turn a fresh absence into a cache entry. Old schema-1 caches are discarded and
rebuilt by a full scan; a delayed lookup cannot reuse their unproven absences.
This metadata optimization assumes ordinary local ext4/tmpfs timestamps and
clock progression under the offline WORLD contract. Future-dated metadata,
including a wall clock moved behind the file dates, forces a reread. It does
not establish content identity on every filesystem or against a writer that
does not respect WORLD; delete the optional cache to require full reads.
Files containing Writing and player databases are always inspected. A missing or
invalid cache causes full reads. Dry-run ignores the cache and never updates it.
Deleting the cache merely makes the next startup perform a full scan. Pending
cleanup recovery and genuine Java record validation still run before mutation.

An empty/clean world does not require `javac`. Dirty records require a compatible
JDK for the real PZ validator, selected with `PZ_WRITING_CLEANUP_JAVA` and
`PZ_WRITING_CLEANUP_JAVAC`; missing tools stop cleanup before any world mutation.

`checkModsNeedUpdate` waits up to 30 seconds for a final Workshop status; other
console commands retain their configured output timeout.

```bash
pzm rcon "command"            # Send RCON command
```

Common commands:
```bash
pzm rcon save                           # Force save
pzm rcon servermsg "Message"            # Broadcast message to players
pzm rcon players                        # List connected players
pzm rcon checkModsNeedUpdate            # Check mod updates
pzm rcon setaccesslevel "Name" admin    # Set player access level
```

## Discord

```bash
pzm discord "message"         # Send Discord notification (outbound webhook)
```

Requires `DISCORD_WEBHOOK` in `.env`

### Command bot (run pzm from Discord)

```bash
pzm install discord           # install/enable the /pzm slash-command bot
```

Lets authorized users run `pzm` from Discord via `/pzm server …`, `/pzm backup …`,
`/pzm rcon …`, etc. Requires the `DISCORD_BOT_*` variables in `.env`.
See [DISCORD_BOT.md](DISCORD_BOT.md).

## Automations

View scheduled tasks:
```bash
systemctl --user list-timers
```

| Timer | Schedule | Function |
|-------|----------|----------|
| pz-backup | Hourly :14 | Incremental backup |
| pz-modcheck | Every 5 min | Check mod & server updates |
| pz-heapcheck | Every ~30 s | Restart at 18 GiB aggregate PZ RSS or heap ≥ `HEAP_RESTART_PERCENT` |
| pz-maintenance | Daily 4:30 | Full maintenance (reboot or restart selon .env) |
| pz-creation-date-init | Daily 00:00 | Init whitelist creation dates |

## Quick Reference

| Task | Command |
|------|---------|
| Start server | `pzm server start` |
| Stop in 5 min | `pzm server stop 5m` |
| Check status | `pzm server status` |
| Add player | `pzm whitelist add "SteamID64" "Name"` |
| Manual backup | `pzm backup create` |
| Preview one map chunk | `pzm backup restore-zone <backup> <x> <y> <x> <y>` |
| Restore that chunk (server stopped) | `pzm backup restore-zone <backup> <x> <y> <x> <y> --apply` |
| Send message | `pzm rcon servermsg "Text"` |

## Help

```bash
pzm --help
```

## Documentation

Full index and topic ownership: [README.md](README.md).

- [QUICKSTART.md](QUICKSTART.md) - Installation
- [ARCHITECTURE.md](ARCHITECTURE.md) - How the code is organised
- [SERVER_CONFIG.md](SERVER_CONFIG.md) - Game configuration
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Problem solving

The GitHub workflow **Isolated Linux tests** runs `tests/run-isolated.py` on
a disposable hosted Ubuntu VM for pull requests and pushes to main. It verifies
preinstalled dependencies, executes the root boundary scenarios, and retains the
suite results as an artifact. It does not access the production server or include
the proprietary game JAR; real-world terrain loading remains a separate offline
validation.
