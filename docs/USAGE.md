# Usage Guide

All `pzm` commands. Run as `pzuser`.

```bash
su - pzuser
```

## Server

```bash
pzm server start              # Start immediately (no countdown)
pzm server stop [delay]       # Stop (default: auto)
pzm server restart [delay]    # Restart (default: auto)
pzm server status             # Status + logs
```

**Delays**: `30m`, `15m`, `5m`, `2m`, `30s`, `now`, `auto`

`auto` is the default and picks the delay from the number of connected players:
**5m** if 2 or more, **2m** if 1, **now** if none — so an empty server restarts
without a countdown. If the player count is unavailable, the fallback is **2m**.
This delay applies to shutdown; `start` starts immediately.

**Always pass `--reason`** on `start`/`stop`/`restart`: the text is shown to
players in the in-game warning and on Discord. Without it the message only says
whether the shutdown was manual or automatic; a start without a reason has no
start notification. The delay is optional. If supplied, put it immediately after
`stop` or `restart`, before the named options:

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
  running**, proved by an advancing frame counter `f:` in the current boot
  or an attributed native `players` response from the game console.

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

**The frame counter only advances while players are connected.** An empty
server may stay at `f:0`; an attributed native `players` response can then prove
that the game loop handles commands, even with zero players. Neither systemd
activity, a FIFO echo, the early Lua marker nor a player count alone proves readiness.

The wait prints progress. Without either proof after 300 s, stop/restart is
refused; a timeout never authorizes an automatic kill. Inspect the journal before
deciding whether a direct systemd stop is appropriate (it may end in SIGKILL
without a final save).

## Backups

```bash
pzm backup create             # Incremental backup
pzm backup create --consistent # Checked recovery point; server already stopped
pzm backup full               # Complete backup
pzm backup list               # List backups
pzm backup restore <path>     # Restore ALL data from a backup
pzm backup restore-character <name> <backup> [--dry-run]   # Preview/restore ONE character
pzm backup restore-zone <backup> <x1> <y1> <x2> <y2> [--apply] [--save <world>]
                              # Preview/restore exact tiles, every floor (inclusive tile coordinates)
```

Full restore takes an existing directory path, not a bare snapshot name or ZIP.
Stop the server first; the command does not stop it for you.

Normal live backups retain the hourly in-game save, but copying while the engine
runs cannot guarantee application consistency. Each new snapshot records
`best-effort` or `stopped` provenance in `.pzm-snapshot.json`. `--consistent`
requires a proven inactive service before and after the copy, an unchanged
invocation, and valid staged SQLite databases without pending journals. It never
stops the server automatically. ZIP creation retains this provenance and does not
certify historical snapshots that lack it.

An interrupted multi-file maintenance operation leaves a durable journal outside
Zomboid and blocks startup. Recovery is explicit; see
[Writing recovery and admission](WRITING_TEXT_ONLY.md). Never delete a pending
journal merely to bypass this check.

Example:
```bash
pzm server stop 2m --reason "Restauration du monde"
pzm backup restore data/dataBackups/backup_2026-01-12_14h14m00s
```

**Restore a single character** (e.g. a player lost their character after a mod
change while their whitelist access is intact — no full-world rollback needed):
```bash
pzm server stop 2m --reason "Restauration perso"   # server MUST be stopped (the stop already makes a backup)
pzm backup restore-character Snardat backup_2026-06-23_23h15m29s
pzm server start
```

Character restoration validates each complete selected blob with the installed
game, enabled mods and the destination's binary dictionary before any SQL write.
Keep the source `WorldDictionary.bin` beside `players.db`. Apply requires a
compatible JDK (`PZ_RESTORE_JAVA` / `PZ_RESTORE_JAVAC`); preview needs no compiler.
Unknown versions, changed registry meanings and unreadable or ignored items
are refused. SQLite source/destination sidecars must first be resolved on a
separate consistent copy.

- `<name>`: the player's username (case-sensitive).
- `<backup>`: **required** — the backup folder name (resolved under `data/dataBackups/`)
  or a full path. Use a specific backup from **before** the incident.
- `--dry-run` previews without modifying the character and works while the server
  runs. Without it, an active server produces a preview followed by a refusal.
- The player's current character is **overwritten** by the one from the backup. No extra
  snapshot is taken here — `pzm server stop` stops the server, then creates a backup.

### Restore a map zone (Build 42)

Restore one tile column or an exact rectangle of tiles to recover disappeared constructions from an older **directory snapshot** or **unencrypted full-backup ZIP** listed by
`pzm backup list`. Coordinates are world **tiles**, not cells or chunks; give the
X/Y of each of two opposite corners, in either order. Bounds are inclusive.

To read coordinates **in game**, an administrator can open **Admin → See Server
Options**, filter for `ShowCoordinates`, set it to `true`, save and apply changes.
Stand at the location and read X/Y in the lower-right corner; Z is not an argument
because restoration includes every floor. This setting shows coordinates to players.

Alternatively, open the [Project Zomboid map](https://pzmap.org/), select
Build 42 and set **Coordinate Display → Tile**. Read X/Y at each corner of
the area. Use tile coordinates rather than the Cell or Chunk display values;
check the effective bounds printed by the preview before applying.

```bash
pzm backup restore-zone backup_2026-10-12_10h00m00s 10500 9500 10540 9540
pzm server stop 2m --reason "Restauration de constructions"
pzm backup restore-zone backup_2026-10-12_10h00m00s 10500 9500 10540 9540 --apply
# For an off-site ZIP, supply its full path (or its name under fullBackups):
pzm backup restore-zone data/fullBackups/2026-10-11_05-04-51-1117758.zip 10500 9500 10540 9540 --apply
pzm server start now --reason "Restauration de constructions terminée"
```

For a full-backup ZIP, only the necessary `zomboid/Saves/Multiplayer/<world>/` map files are staged temporarily under the manager's data directory (outside Syncthing); `config/` and player databases are never extracted. The staging copy is removed after preview or restoration. ZIP members are validated and limited to 512 MiB per file and 8 GiB overall, with 512 MiB free-space reserve. Encrypted `.zip.age` files must first be decrypted to a ZIP; `restore-zone` does not decrypt archives.

For **one tile**, repeat its X/Y coordinates as both corners. For example,
this previews only tile `10500,9500`, on every floor; add `--apply` after stopping
the server to restore it:

```bash
pzm backup restore-zone backup_2026-10-12_10h00m00s 10500 9500 10500 9500
```

**The minimum restore size is one tile column**, including all basement and upper
levels. The example leaves the other 63 tiles of its 8×8 chunk untouched.
The command also removes a current floor when that floor is absent for this tile
in the snapshot. Selecting only one floor or one object is not supported.

The first command previews without modifying the map, even while the server runs.
`--dry-run` also explicitly selects preview. `--apply` requires a proven stopped
server and takes the same world lock as start, backup, wipe and full restore.
Use `--save <world>` if there are several multiplayer worlds. The source must
contain `Saves/Multiplayer/<world>/map/`; Build 41 is unsupported.
A snapshot name under `BACKUP_DIR`, its `latest` alias, a directory path or a
full-backup ZIP is accepted. Prefer a dated snapshot from before the disappearance.

The preview prints the **exact inclusive tile rectangle**, with no expansion to
chunk boundaries. All floors, terrain, constructions and container contents on
those tiles return to the snapshot. Other tile-column records in the same chunk
are preserved byte for byte. For a partially selected chunk, its current
chunk-wide metadata (including blood splats) is kept, and the isoregion cache is
invalidated so it can be rebuilt from the merged terrain. Fully selected chunks
are copied from the snapshot with their isoregion cache when available.
Cell-wide chunkdata, metagrid, zombie/animal populations, global files, player
characters and vehicles are not restored. This targets construction loss; it is
not a complete rewind of all activity in the rectangle, nor a fix for a mod or
save bug that continues to remove buildings.

Every selected terrain chunk must exist and be nonempty in the source. Missing
chunks cause refusal before any write. `WorldDictionary.bin`
must be present in both worlds. Identical dictionaries are accepted directly;
otherwise a compatible JDK is required to read both binary dictionaries with
the game's native reader. Every source item, entity, object, sprite and string
ID must retain its meaning in the current dictionary, including script names
and version hashes. Additional current entries and changes in mod provenance
or removed/obsolete flags are allowed; disabled mods are not reactivated.
If `map_ver.bin` exists, it
must match too; current Build 42 saves can omit it. Every source terrain chunk
must have a valid world-version-249 header, length and CRC32 checksum. Different
versions or reassigned/missing object IDs cannot be safely mixed. Do not overwrite the live global dictionary
to bypass the refusal. Keep the same mods. A partial chunk also requires a present,
valid current chunk, because its unselected tiles must be preserved. Missing or
corrupt current terrain can only be replaced when the entire chunk is selected.
Verify the recovered construction in game.

The native terrain reader loads installed game definitions and the active mod
list from the server configuration. It associates those definitions with the
current binary dictionary before reading copied records, including dropped
items with fluid/entity data. The global dictionary and original item bytes
are preserved; the reader never saves game objects.

Partial-chunk application uses the installed game's native record readers on
private copies to find tile boundaries, then splices the original serialized
columns. It never reserializes neighbouring objects. The result is loaded again
and all 64 columns are compared with the intended source/current bytes before
any world write. A record that cannot be read causes refusal; there is no fallback
to restoring a larger area. The offline reader does not initialize a complete
Workshop script environment, so some modded records may be refused.

Every application requires a compatible **JDK**, including whole chunks, because
all selected terrain undergoes native validation.
The default JVM is `PZ_INSTALL_DIR/jre64/bin/java`; its sibling `javac` is used
when available, otherwise `javac` on PATH. Set `PZ_RESTORE_JAVA` and/or
`PZ_RESTORE_JAVAC` in `.env` to override these tools. An explicitly configured
compiler is authoritative; incompatible or missing tools stop before changing
the world. Compilation uses `--release` for the selected JVM. Preview also requires
a JDK when the source and current dictionaries differ. A refused native validation
keeps only its diagnostic log, at the printed path.

Before writing, the command stages the selected source files and copies the
current selected files into a private, unique, temporary
`${PZ_HOME}/.zone-rollback-*` directory. It is deleted once the zone is applied
or reverted. Ordinary write failures and handled interruption trigger restoration
of files already touched. A power loss or forced kill can leave a partial
operation and the directory: keep the server stopped and use it to recover.
`manifest.json` records the selected files, files absent before the operation,
and completion status; `before/Saves/Multiplayer/<world>/` holds the previous
files (restore them, remove only the listed `absent_before` files). Individual
replacements are atomic, but the whole rectangle is not one filesystem
transaction. A failed revert keeps the directory and prints its path. The source snapshot and hardlinked
backups are never modified by the restore.

Discord exposes the same operation as `/pzm backup restore-zone`, with `backup`,
`x1`, `y1`, `x2`, `y2`, optional `monde`, and `appliquer` (false by default).

To reproduce the native one-tile preservation test, run
`tests/verify_tile_restore_native.py --help` from a disposable checkout. Supply
two snapshot world directories, chunk coordinates and a private results directory,
with `PZ_INSTALL_DIR` set to the installed game. It copies only the required files,
simulates a lost column in its private copy when necessary, restores all its
floors and proves that the other 63 column records are byte-identical. It never
writes to either input snapshot or the production world.

Offline validation of real snapshots can also use `tests/ValidateRestoredTerrain.java`
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
pzm whitelist remove-account "Name" [--dry-run]     # Delete one account; remove its SteamID only if orphaned
pzm whitelist rename-account "Old" "New" [--dry-run]  # Rename an account, keep its character
pzm whitelist resetpassword "Name"                  # Reset password, server stopped
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

`remove-account`, `rename-account`, `resetpassword` and `purge --delete` require
a stopped server for database writes. Choose a recovery point before manual
account changes; the automatic purge additionally creates its own database
safety copy as described below. `remove-account`
and `rename-account` accept `--dry-run` for a preview; `purge` without `--delete`
only lists candidates. The deletion asks for `oui` in an interactive terminal.
`resetpassword` has no preview option. Renaming attaches the character database
and updates both databases in one SQLite transaction. Crash-safe commit requires
durable rollback journals (`DELETE`, `TRUNCATE` or `PERSIST`) and synchronous
writes; `WAL`, `OFF` and `MEMORY` modes are refused before mutation.

**Player onboarding**: see [PROCEDURE_JOUEURS](PROCEDURE_JOUEURS.md) (French) — the
player sends their SteamID64, you authorize it, they connect and set their own password.

**Notes**:
- Steam ID 64: 17 digits starting with `7656119...` ([steamid.xyz](https://steamid.xyz/))
- `--ban` adds a permanent `banid` — the player can't return even renamed.
- `purge` here is the manual, interactive variant (lists/deletes `whitelist` rows only).
- Purge: Xm (months) or Xd (days), default in .env

### Automatic access purge

Inactive accounts past the `WHITELIST_PURGE_DAYS` cutoff (default 90 days) lose access
**automatically, on every server start** — the account first, then its SteamID
**only if no remaining account still uses it**. The **character is always kept**,
and the built-in `admin` account is always spared.

The cutoff is strict: equality is kept. Last connections use SQLite's UTC
date cutoff; never-connected accounts use their ledger creation date and the
local timestamp cutoff. Accounts with unknown age are spared.

It runs from `zomboid.service`'s `ExecStartPre`, before the JVM. Admission
verifies the inherited WORLD descriptor and the actual start-pre identity;
`activating` state or a caller-supplied flag alone is not authorization. Other
mutating invocations require a proven stopped server. A failed purge remains
non-blocking for startup.

Inspect it at any time — this touches nothing, even with the server up:

```bash
data/scripts/admin/purgeInactivePlayers.sh --force --dry-run --days 60
```

It prints, per account, whether the SteamID would be released or kept because
another account shares it.

The raw helper accepts `--days N` (overrides `.env`), `--dry-run` and `--force`.
`--force` permits only `--dry-run` while active; it never authorizes live deletion.
Before any DELETE, the SQLite backup API creates a private safety copy including
committed WAL pages, checks integrity and fsyncs the copy and its parent. Failure
refuses deletion. The printed recovery path remains available after success.

## Administration

```bash
pzm admin reset                                    # Full reset (new world)
pzm admin reset --keep-config                      # Reset, keep configs/mods
pzm admin reset --keep-whitelist                   # Reset, keep whitelist
pzm admin reset --keep-config --keep-whitelist     # Reset, keep everything
pzm admin maintenance [delay]                      # Manual maintenance (default: 30m)
pzm admin maintenance 2m --reason "RAM upgrade"    # Maintenance with reason
```

For reset staging, preservation options and recovery guarantees, see
[complete server reset](ADVANCED.md#complete-server-reset).

**Maintenance options**:
- `[delay]`: `30m`, `15m`, `5m`, `2m`, `30s`, `now`, `auto` (default: 30m)
- `--reason TEXT`: Add reason to messages (optional)
- `--no-reboot`: Restart the service instead of rebooting the machine, regardless of `REBOOT_ON_MAINTENANCE`.
- `--silent`: Suppress normal Discord announcements (error alerts may still be sent).
- `--automatic`: Mark the maintenance as automatic.

**Announcements** carry the action, manual/automatic origin and optional reason.
The first countdown warning carries origin/reason and the Discord `@here` ping;
subsequent warnings omit that context. In-game messages do not include Discord
mentions.

Mod updates request an automatic service restart, not maintenance. Build updates
use maintenance with `--no-reboot`; scheduled maintenance follows
`REBOOT_ON_MAINTENANCE`. See [update orchestration](ARCHITECTURE.md#automation).

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
pzm rcon <command> [args] [--no-output]   # Send via the server console FIFO
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
| Preview one tile, all floors | `pzm backup restore-zone <backup> <x> <y> <x> <y>` |
| Restore that tile (server stopped) | `pzm backup restore-zone <backup> <x> <y> <x> <y> --apply` |
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
a disposable hosted Ubuntu VM for pull requests. It verifies
preinstalled dependencies, executes the root boundary scenarios, and retains the
suite results as an artifact. It does not access the production server or include
the proprietary game JAR; real-world terrain loading remains a separate offline
validation.
