# Advanced Configuration

Memory model, performance tuning, and server reset procedures.

## RAM / JVM Configuration

JVM args live in `ProjectZomboid64.json` (the `vmArgs` array), written by
`data/scripts/internal/configureJvm.sh`. That script runs at install time **and is
re-applied after every SteamCMD update** — the nightly maintenance runs
`app_update ... validate`, which restores the vanilla JSON, so any manual edit
of `ProjectZomboid64.json` is overwritten the next night. There is no
`pzm config ram` command. What it sets:

- **No `-Xms`.** It was removed: with `AlwaysPreTouch` the real resident cost is
  the pre-touched `-Xmx`, not `-Xms`, and ZGC give-back never fires on this
  ever-growing workload. The heap now starts at the ergonomic default and grows
  on demand.
- `-Xmx` = **`PZ_XMX_GB` GB if set in `.env`, else half of physical RAM** (e.g.
  7g on a 14 GiB machine). This is a real guardrail: it triggers a clean Java
  `OutOfMemoryError` before the heap can crowd out PZ's native memory + the OS.
- `-XX:+UseZGC` (generational by default on JDK 25) `-XX:+AlwaysPreTouch`
  `-XX:ZCollectionInterval=60` — GC tuning. `ZCollectionInterval` forces a
  *major* (young+old) collection at that interval; 60s keeps the cheap young
  collections frequent while making the expensive majors rare (5s ran a
  near-continuous major pass that freed almost nothing → wasted CPU/heat).
- `-XX:+UseStringDeduplication` — the heap is full of map cells with repeated
  sprite/tile strings; dedup trims the String part of the live set.
- `-XX:+UseCompactObjectHeaders` (JEP 519, product in JDK 25) — shrinks every
  object header from ~12 to 8 bytes. The heap is millions of tiny map-cell
  objects, so this trims ~10-20% of the live set: less resident RAM **and** a
  later heap OOM (it shrinks the live data, unlike `-Xmx` which only delays).
- `-Djava.net.preferIPv4Stack=true` — RakNet/UdpEngine network stability.
- `-XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=<logs/zomboid>` plus a
  rotating `-Xlog:gc*` to `logs/zomboid/gc.log` — diagnostics.

**No cgroup memory cap.** `MemoryMax`/`MemoryHigh` are deliberately *not* set:
on a modest machine they sit at the level of physical RAM, and the kernel
throttles/OOM-kills PZ the instant it touches the cap (this caused server
crashes). Instead, `data/setupTemplates/zomboid.service` sets
`MemorySwapMax=0` — swap is **forbidden** to the process, because swapping game
pages causes micro-freezes and worsens network desync. The `-Xmx` cap leaves
the headroom to stay resident.

**To change `Xmx`**, either set `PZ_XMX_GB` in `.env` (simplest) or edit
`data/scripts/internal/configureJvm.sh`, then apply and restart:

```bash
nano ~/pzmanager/.env        # e.g. uncomment: export PZ_XMX_GB=8
~/pzmanager/data/scripts/internal/configureJvm.sh
pzm server restart 5m
```

> ⚠️ Keep `-Xmx` at roughly half of physical RAM. With `AlwaysPreTouch` the full
> `Xmx` is resident from boot, and `Xmx` + ~5 GB of PZ native memory can exceed
> total RAM, triggering a brutal Linux OOM-kill instead of a clean Java OOM. Only
> raise `PZ_XMX_GB` above half if you know the box has the headroom.

## GraalVM (optional JIT engine)

By default the server runs on the JRE bundled with PZ (`data/pzserver/jre64`, Azul
Zulu / HotSpot). You can optionally run it on **Oracle GraalVM** instead, whose
**Graal JIT compiler** optimises the allocation-heavy, single-threaded code paths
(chunk generation → the transient tick stalls that show up as desync). The Graal
JIT runs as **libgraal** (`UseJVMCINativeLibrary`), i.e. *outside* the Java heap —
it does not eat your `-Xmx`.

Setup (opt-in, fully reversible):

```bash
# 1. Install GraalVM JDK 25 outside the Steam tree (survives steamcmd validate)
curl -sL -o /tmp/graalvm.tar.gz \
  "https://download.oracle.com/graalvm/25/latest/graalvm-jdk-25_linux-x64_bin.tar.gz"
mkdir -p ~/graalvm-jdk-25 && tar xzf /tmp/graalvm.tar.gz -C ~/graalvm-jdk-25 --strip-components=1

# 2. Point the server at it
nano ~/pzmanager/.env        # export PZ_GRAALVM_HOME="/home/<user>/graalvm-jdk-25"

# 3. Apply the JVM args and restart (the switch happens at the restart)
~/pzmanager/data/scripts/internal/configureJvm.sh
pzm server restart 5m --reason "Switch Java engine to GraalVM"
```

How it works: `data/scripts/internal/linkJvm.sh` replaces `jre64` with a symlink to
`$PZ_GRAALVM_HOME` (the real dir is kept as `jre64.stock`). It is re-applied at
**every start** via `zomboid.service`'s `ExecStartPre` because `steamcmd validate`
restores the real `jre64`; nightly maintenance calls `linkJvm.sh --stock` **before**
the validate so steamcmd never writes through the symlink.

**Rollback:** empty `PZ_GRAALVM_HOME` in `.env` and restart — the next start restores
the bundled `jre64`. A bare restore (offsite backup) also degrades safely: GraalVM
lives outside `pzmanager` and is not backed up, so `linkJvm.sh` falls back to the
bundled JRE until you reinstall GraalVM.

> ⚠️ **GraalVM validates `-Djdk.graal.*` options and aborts fatally on an unknown
> name** (unlike HotSpot, which ignores any `-D`). All of GraalVM's enterprise perf
> optimisations (Vectorization, loop opts, escape analysis, inlining) are **already
> on by default** — do not add flags for them. `configureJvm.sh` sets only
> `-Djdk.graal.TuneInlinerExploration=1` (the one value that differs from the
> default). It also sets `--enable-native-access=ALL-UNNAMED` and
> `--sun-misc-unsafe-memory-access=allow` (standard JDK flags, on Zulu too) so a
> future JDK does not block PZ's native library loading.

## Memory-driven restart (why the server restarts on its own)

On a large modded B42 server the Java heap fills with **live map-cell data**
(`IsoGridSquare`/`IsoObject`/chunks held by `ServerMap`/`IsoMetaGrid`) as players
explore. These are referenced, not garbage: a forced GC frees nothing and `save`
keeps them resident. There is no console command or config knob to evict cold
chunks at runtime, so **a restart is the only way to reclaim that memory** —
otherwise the heap OOMs after ~15 h of uptime.

pzmanager handles this adaptively via `pz-heapcheck.timer` (every ~3 min): it
reads the post-major-GC heap occupancy from `logs/zomboid/gc.log` and,
when it reaches `HEAP_RESTART_PERCENT` (`.env`, default **95**), triggers
`pzm server restart` with `HEAP_RESTART_DELAY` (default `5m`) and a player
warning. A quiet server never gets a needless restart; a fast-filling evening
session is caught before it OOMs. The daily 04:30 maintenance restart is the
backstop if the monitor never fires.

Tuning: if a crash ever happens *during* the warning countdown, lower
`HEAP_RESTART_PERCENT` to 90 or shorten `HEAP_RESTART_DELAY`.

## RCON Commands

```bash
pzm rcon "save"                          # Force save
pzm rcon "servermsg 'Message'"           # Broadcast
pzm rcon "players"                       # List players
pzm rcon "quit"                          # Stop server
pzm rcon "help"                          # All commands
```

Full list: [PZ Wiki - Server Commands](https://pzwiki.net/wiki/Server_commands)

## Regenerating a Map Area

When a map mod is updated but players have already explored the area, PZ keeps
serving the cached chunks and the old version stays on screen. Deleting that
area's save files makes the game regenerate it from the mod on next visit.

```bash
pzm map wipe <x> <y>                 # One tile (regenerates its 8×8 chunk)
pzm map wipe <x1> <y1> <x2> <y2>     # A rectangle of tiles
```

Coordinates are in-game tile coordinates. `pzm map wipe --help` documents the
Build 42 save layout it relies on.

> ⚠️ **Build 42 grid: a chunk is 8 tiles and a cell is 256 tiles** — *not* the
> 10 / 300 of Build 41. `wipeMapTile.sh` was hard-coded to the B41 values until
> 2026-07-23, and with the wrong constants a wipe deleted the cell-level files
> while clearing **zero** terrain chunks: the cached terrain survived and the map
> kept rendering the old version even though the mod itself was fine. A wipe that
> reports only a handful of deleted files (no `map/**.bin`) is the tell.

The wipe **always** clears both levels: the terrain chunks (8×8) *and* the
cell-level data — `chunkdata`, `metagrid` (room definitions), `zpop` (zombies)
and `apop` (animals), stored per **256×256 cell**. So it affects the whole cell,
not just the tiles you asked for. This is unconditional: the old `--cell` /
`--no-cell` flags were removed, because the cell level has to be cleared
whenever a mod changes buildings or rooms — which is the normal case.

> ⚠️ **Deletion is immediate — there is no dry-run.** The server must be stopped
> (the command refuses to run otherwise). A **normal snapshot** of the world
> (`backup_<ts>`, via `dataBackup.sh --snapshot-only`) is taken first — it shows up
> in `pzm backup list`, so your way back is `pzm backup restore <backup>`.

Anything built by players in the wiped area is lost — it is part of the save
data being regenerated.

## Complete Server Reset

Use when: corrupted world, major config change, fresh start.

**New world (clean slate)**:
```bash
pzm admin reset
```

**New world, keep configs and mods** (servertest.ini, SandboxVars, spawns):
```bash
pzm admin reset --keep-config
```

**New world, keep whitelist**:
```bash
pzm admin reset --keep-whitelist
```

**New world, keep everything** (configs + whitelist):
```bash
pzm admin reset --keep-config --keep-whitelist
```

Options are combinable. With `--keep-config`, configs are restored **before** world generation so Workshop mods are downloaded on first launch.

> ⚠️ **There is no confirmation prompt.** `pzm admin reset` wipes the world
> immediately, and it is runnable from the Discord bot too. The only barrier is
> access to `pzm` / to the bot's admin role — keep that role tight.

Process:
1. Backup created in `~/OLD/Zomboid_OLD_TIMESTAMP/`
2. World generation (automatic, ~2 min)
3. Admin password displayed (note it!)
4. Server started

## Maintenance Scheduling

Automations use systemd timers (not crontab).

**View timers**:
```bash
systemctl --user list-timers
```

**Modify maintenance time** (default 4:30 AM):
```bash
nano ~/.config/systemd/user/pz-maintenance.timer
systemctl --user daemon-reload
```

## Resources

- [SERVER_CONFIG.md](SERVER_CONFIG.md) - Game configuration
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Problem solving
- [PZ Wiki](https://pzwiki.net/wiki/Dedicated_Server) - Official docs
