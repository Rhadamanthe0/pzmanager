# Advanced Configuration

Memory model, performance tuning, and server reset procedures.

## RAM / JVM Configuration

JVM args live in `ProjectZomboid64.json` (the `vmArgs` array), written by
`data/scripts/internal/configureJvm.sh`. That script runs at install time **and is
re-applied after every SteamCMD update** — the nightly maintenance runs
`app_update ... validate`, which restores the vanilla JSON, so any manual edit
of `ProjectZomboid64.json` is overwritten the next night. There is no
`pzm config ram` command. What it sets:

- **No `-Xms`.** The heap starts at the ergonomic default and grows on demand.
  Committed ZGC pages are backed by resident shmem; unused committed heap
  still counts toward the cgroup budget.
- `-Xmx` = **`PZ_XMX_GB` GiB (2..16) if set in `.env`, else rounded-up half of
  physical RAM capped at 16 GiB** (16 on MINIPC). The remaining 4 GiB of the
  20 GiB shared PZ budget covers game-native memory and management tasks.
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

**Shared PZ budget: 18 / 20 GiB.** The monitor requests a clean restart at
`PZ_RAM_RESTART_GB=18`; `pz.slice` enforces an aggregate `MemoryMax=20G` with
`OOMPolicy=kill` as a last resort. If reclaim cannot contain memory below 20 GiB,
the service is killed without a guaranteed save. Preventive monitoring sums process RSS across the PZ slice (game, bot and background tasks),
excluding reclaimable file and kernel caches. The hard cap uses cgroup accounting
including those caches; Linux can reclaim them before killing the service. `MemoryHigh` is not set;
`MemorySwapMax=0` forbids swap to avoid game freezes. The heap is capped at **16 GiB** within this budget; **4 GiB** remain for every
other cgroup charge (native memory, code, stacks, descendants, cache and kernel
accounting). This is planning headroom, not a guarantee against OOM. Resident
ZGC shmem is part of the heap and cannot be treated as reclaimable disk cache.
A smaller heap can increase GC work and require earlier restarts; it does not
fix pathological item serialization.

**To change `Xmx`**, set `PZ_XMX_GB` to an integer from **2 to 16** in `.env`.
An old override of 20 is rejected explicitly, before the JSON or its backup
is changed. The default is half of physical RAM rounded up to GiB, capped at
16 (16 GiB on MINIPC). Apply during an agreed stop, then restart:

```bash
pzm server stop             # after an agreed warning/stop
nano ~/pzmanager/.env        # e.g. export PZ_XMX_GB=16 on MINIPC
~/pzmanager/data/scripts/internal/configureJvm.sh
pzm server start
```

> Committed ZGC shmem is not reclaimable disk cache. RSS minus *used* heap
> is not a native-memory measurement: it can include unused committed heap.
> Keep the JSON and shared PZ limit coherent; the 4 GiB planning margin
> does not prevent OOM if other charges grow beyond it.

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

pzmanager handles this adaptively via `pz-heapcheck.timer` (every ~30 s): it
reads the post-major-GC heap occupancy from `logs/zomboid/gc.log` and,
when it reaches `HEAP_RESTART_PERCENT` (`.env`, default **95**), triggers
`pzm server restart` with `HEAP_RESTART_DELAY` (default `5m`) and a player
warning. It also triggers at **18 GiB of aggregate resident PZ process memory**, even when
`gc.log` is absent or the heap is still low. The **20 GiB hard cap** can kill the
service during the warning; preventive monitoring reduces that risk but cannot
guarantee a save after a rapid increase. The daily 04:30 maintenance restart is the
backstop if the monitor never fires.

Tuning: if a crash ever happens *during* the warning countdown, lower
`HEAP_RESTART_PERCENT` to 90 or shorten `HEAP_RESTART_DELAY`.

### Inspecting the running JVM without jcmd

The bundled JRE ships no `jcmd`/`jmap`, so to diagnose a *live* server you drive
the HotSpot attach protocol by hand. The unit sets `PrivateTmp=true`, so the
socket lives under the process's own `/tmp`:

```bash
pid=$(pgrep -f ProjectZomboid64 | head -1)
touch /proc/$pid/root/tmp/.attach_pid$pid
kill -QUIT $pid                       # makes the JVM create the attach socket
# then, over /proc/$pid/root/tmp/.java_pid$pid, send:  1\0jcmd\0<dcmd>\0\0\0
```

Useful `<dcmd>` values: `GC.heap_info`, `GC.class_histogram`,
`GC.heap_dump <path>`.

> ⚠️ A full heap dump is roughly `-Xmx` GB on disk and **freezes players for
> ~25 s**. Analyse the resulting `.hprof` with Eclipse MAT.

Installing GraalVM (see above) is the easier route: it *does* ship `jcmd`, and
`watchServerStall.sh` uses it for thread dumps.

## RCON Commands

```bash
pzm rcon "save"                          # Force save
pzm rcon "servermsg 'Message'"           # Broadcast
pzm rcon "players"                       # List players
pzm rcon "quit"                          # Stop server
pzm rcon "help"                          # All commands
```

Full list: [PZ Wiki - Server Commands](https://pzwiki.net/wiki/Server_commands)

## Restoring Map Tiles from a Backup

To recover constructions from an older snapshot, use
`pzm backup restore-zone <backup> <x1> <y1> <x2> <y2>`. It previews by default;
`--apply` restores the exact inclusive tile rectangle, on every floor, while the
server is stopped. For one tile, repeat its X/Y as both corners. Other tiles in
the same chunk are preserved; partial chunks require a compatible JDK.
Follow [the restore procedure](USAGE.md#restore-a-map-zone-build-42) for the
options, affected data and recovery copies.

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


### Existing installation migration to the 20 GiB budget

A pull of this change does not migrate `.env`, installed units or a running
JVM. In particular, MINIPC's historical `PZ_XMX_GB=20` must be changed explicitly.
Do not lower the cgroup limit around an already running 20 GiB heap.

1. Archive the current `.env`, JVM JSON and installed unit/drop-ins privately.
   Preserve unrelated local changes and coordinate any concurrent writer.
2. If a legacy Xmx20 is still configured, explicitly stage a coherent
   Xmx16 JSON while stopped (also remove conflicting Xms/heap overrides).
   Change only the PZ_XMX_GB setting in .env. Validate the staged JSON with
   `python3 data/scripts/lib/jvm_memory_budget.py check data/pzserver/ProjectZomboid64.json --planned-limit 20G`.
   This offline command neither writes data nor proves the live budget.
3. Stop all PZ services, timers and the control socket after the normal game
   shutdown and backup. `pzm install budget` archives the current units/drop-ins
   and installs only the shared slice and placement/preflight drop-ins. It
   reloads and checks the effective guards, without starting a game or running
   Steam. Preserve CPU/priority customizations; remove an old override that
   resets ExecStartPre only after archival and review of its successor.
4. Start once. The blocking preflight requires the actual shared parent20G,
   swap0 and a coherent16G heap. Read back pz.slice kernel limits and the
   cgroup of game, logger and bot, not only the template. Verify GC initialization,
   native SERVERSTARTED, console response and player progression. Restore paused
   timers progressively after checking their I/O and restart risks.
5. Validate the backup CPU scope and manual CLI placement. A daemon-reload does
   not migrate already-running processes. Rollout must therefore restart each
   existing PZ participant once, with SSH kept outside the slice.

For rollback, keep the saved configuration and units. An old Xmx20 must be
paired with an explicitly reviewed larger total budget; restoring Xmx20 under
MemoryMax20 is not a safe rollback. Reducing the heap can increase GC work or
bring heap OOM earlier. The 20 GiB cap remains a last resort, not a guarantee of
a clean save during a sudden allocation spike. Existing problematic item data
require a separate remedy.

<a id="budget-memoire-partage-de-pz"></a>

## Budget mémoire partagé de PZ

`pz.slice` borne à **20 Gio au total**, sans swap, le jeu, le bot Discord,
le logger, les sauvegardes, la maintenance et les diagnostics. Les neuf
services utilisateur PZ et les scopes lancées par `pzm` ou les scripts
opérationnels directs en font partie. La session SSH, le gestionnaire
systemd utilisateur et les autres applications du compte restent hors de
ce parent ; aucune limite n'est appliquée à `user-<UID>.slice`.

Le heap Java reste limité à 16 Gio. Les 4 Gio restants sont une marge commune,
pas une réservation pour chaque composant. Le plafond enfant du jeu reste20 Gio
et ne s'ajoute pas aux20 Gio du parent. Un préflight refuse le démarrage si
le vrai cgroup n'appartient pas à `pz.slice`, si son plafond partagé diffère
ou si le swap/contrôleur mémoire ne sont pas conformes.

Le monitoring affiche `MemoryCurrent/MemoryMax` du parent, avec le cache et
la mémoire noyau inclus. Le préavis de redémarrage reste à 18 Gio de **RSS
agrégé des processus PZ** (hors caches récupérables), ou 95% de heap après GC
majeur. Les deux mesures répondent à deux questions différentes. Un pic
rapide peut atteindre le plafond avant la fin du préavis 5min ; un restart
du jeu ne libère pas la mémoire consommée par les autres tâches.

Une opération manuelle passe dans une scope avant secrets et verrous.
`systemd-run --scope` préserve les FD hérités ; une nouvelle service aurait
perdu les verrous du monde. Bus absent ou placement/plafond invalide : la
commande échoue, sans repli hors budget et sans flagENV de contournement.
Aide et bootstrap restent utilisables avant installation. Les installateurs
root (comptes, paquets, pare-feu) sont du bootstrap hôte, hors du budget PZ ;
les opérations courantes, y compris leurs descendants `sudo`, héritent du
parent. Le mode split avec deux UID distincts est refusé par l'installation
unifiée : une slice utilisateur ne peut pas agréger deux gestionnaires.

Pour une installation existante, `pzm install budget` pose uniquement le parent
et les drop-ins de placement/garde après archivage privé et arrêt de tous les
services PZ. Il conserve les unités locales, les autres drop-ins, le monde,
`.env`, les mods et le JSON JVM ; il ne télécharge rien et ne démarre aucun
service. Le code fusionné doit être déployé avant cette commande. Une migration
nécessite ensuite un seul redémarrage planifié du jeu, puis la restauration
progressive du bot/timers. Les processus déjà actifs ne changent pas de cgroup
sur un simple `daemon-reload` : vérifier leurs chemins après démarrage, ainsi
que le plafond kernel et la console du jeu.
