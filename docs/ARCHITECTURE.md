# Architecture

How the **code** is organised and why. For what ends up installed *on the
machine* (packages, units, firewall), see
[WHAT_IS_INSTALLED.md](WHAT_IS_INSTALLED.md).

## Contents

- [Repo layout](#repo-layout)
- [Dispatcher and script layers](#dispatcher-and-script-layers)
- [Configuration](#configuration)
- [Server control is a FIFO, not RCON-over-TCP](#server-control-is-a-fifo-not-rcon-over-tcp)
- [Automation](#automation)

## Repo layout

At the root: `pzm` (dispatcher), `.env` (live config + secrets, gitignored), `logs/` (gitignored), `versionning/` (mod-list ledger + `sheetVersionning.sh`; the `V*.txt` and `Mods bugués*.csv` inside are gitignored), `docs/`, `Zomboid/`. Everything else lives under `data/`: `scripts/` (all the code, plus the bootstrap `install.sh`), `setupTemplates/`, `pzserver/`, `dataBackups/`, `fullBackups/`.

## Dispatcher and script layers

`pzm` (root) parses the command and `exec`s into `data/scripts/<layer>/`:
- `data/scripts/core/pz.sh` — server lifecycle (start/stop/restart/status), player warnings, reason/automatic/silent handling.
- `data/scripts/admin/` — maintenance, reset, whitelist, mod-update trigger, creation-date init.
- `data/scripts/backup/` — incremental (`dataBackup.sh`) and full/sync (`fullBackup.sh`) backups, restore.
- `data/scripts/install/` — `setupSystem.sh` (apt, user, systemd units, sudoers) and `configurationInitiale.sh` (SteamCMD install, config).
- `data/scripts/internal/` — helpers not called directly by users: `sendCommand.sh`, `sendDiscord.sh`, `captureLogs.sh`, `configureJvm.sh`, `notifyServerReady.sh`.
- `data/scripts/discord/` — **inbound** Discord command bot (Python/discord.py): `bot.py` exposes a `/pzm …` slash-command group mirroring the dispatcher (`server`/`backup`/`whitelist`/`admin`/`install` subgroups + `rcon`/`discord`/`help`); every subcommand builds a fixed argv and runs `pzm` via `subprocess` (never a shell → "pzm only", no injection). Output comes back as one message (inline code block, or a `pzm-output.txt` attachment when it exceeds one block). **Batch**: an `on_message` handler runs a pasted message whose every content line is `pzm …` line-by-line (sequential, same `run_lock` as the slash commands), deletes the source message, and posts one recap; an invalid line rejects the batch without executing commands, but the source message is still deleted (see [batch rules](DISCORD_BOT.md#batch-run-several-commands-at-once)). Concurrent invocations (slash or batch) **queue** on `run_lock` (asyncio FIFO) rather than being rejected — a batch shows "en file d'attente…" until its turn. `run-bot.sh` sources `.env` and execs the venv Python; `requirements.txt` declares its dependencies. Installed by `data/scripts/install/setupDiscordBot.sh` (`pzm install discord`), which builds the gitignored `.venv` and enables `pz-discord-bot.service`. Distinct from the outbound `sendDiscord.sh` webhook.
- `data/scripts/lib/common.sh` — sourced by every script: `source_env`, `die`/`log`, directory helpers, and the **maintenance lock** (`try_acquire_maintenance_lock`) shared across `pz.sh`, modcheck, and maintenance to serialize conflicting operations.

## Configuration

All paths, ports, retention, the Discord webhook and the Google service-account key live in `.env` **at the repo root** (gitignored, chmod 600). `source_env` auto-creates it from `data/setupTemplates/.env.example` on first run. The root defaults to `PZ_MANAGER_ROOT`, derived from the code location; callers may supply an explicit root to `source_env`. Never hardcode paths — read them from the exported `PZ_*`, `BACKUP_*`, `LOG_*` variables.

### The Google Sheets key has no file

`versionning/sheetVersionning.sh` reads `GOOGLE_SERVICE_ACCOUNT_JSON_B64` (base64 of the whole service-account JSON) and `SHEET_VERSIONNING_ID` from `.env`, decodes the key into a chmod-600 temp file it deletes on exit. There is deliberately no `.json` key on disk, and the spreadsheet ID is not in the (now versioned) script.

## Server control is a FIFO, not RCON-over-TCP

This is the central, non-obvious design:
- `zomboid.socket` (systemd) creates a named-pipe FIFO at `data/pzserver/zomboid.control`.
- `zomboid.service` launches `start-server.sh` with **stdin bound to that FIFO** (`<> .../zomboid.control`).
- Sending a server command = writing a line to the FIFO. `sendCommand.sh` does this, then scrapes the **command output back out of journald** (matching `command entered via server console`). `pzm rcon` is a thin wrapper over `sendCommand.sh`.
- `ExecStop` writes `quit` to the pipe for a clean shutdown.
- `zomboid_logger.service` (`captureLogs.sh`) runs alongside and persists logs.
- The admin password is passed once via a `.admin_password` file that `ExecStart` reads and immediately deletes.

## Automation

All timers are systemd `--user` units.
- `pz-backup.timer` — hourly incremental hardlinked snapshots (`dataBackup.sh`).
  **Its in-game `save` is the only periodic game save: preserve it.**
  `SaveWorldEveryMinutes=0` avoids repeated synchronous main-loop stalls; the
  director accepted a **one-hour RPO** after an unclean death. A clean stop still
  saves. Each snapshot is complete and independent; pruning hardlinks does not
  alter another snapshot. A `flock` on the private `backup.lock`, opened with a
  dynamic descriptor, serializes runs. See [backup configuration](CONFIGURATION.md#backups)
  for consistency, rsync, retention and off-site archives;
  [installed timer policy](WHAT_IS_INSTALLED.md#pz-backuptimer---hourly-backup)
  for resource limits, [host policy](HOST_ENVIRONMENT.md) for CPU placement, and
  [incidents](INCIDENTS.md) for historical measurements. The off-site ZIP carries
  non-reconstructible configuration and game data; restore uses the
  [trusted root helper](TROUBLESHOOTING.md#complete-restoration-system--data).

- `pz-modcheck.timer` — every 5 min; calls `triggerMaintenanceOnModUpdate.sh`, which splits the two cases: a **mod** update triggers only a **short-delay restart** (the PZ server re-downloads the Workshop item itself at boot, so nothing more is needed), while a **server/build** update triggers the full maintenance (apt, `app_update … validate`, JVM re-tune, reboot). It used to run the full maintenance — and therefore reboot the box — for every mod update, several times a day, for no benefit: maintenance's `download_workshop_mods()` pre-pull early-returns while `STEAM_LOGIN` is anonymous, and `app_update` concerns the build, not mods. The reason string names the updated mods (see `listOutdatedMods.sh` below).
  The check acquires the world lock before the maintenance lock and keeps it through the restart or maintenance; child scripts inherit it. If a backup or another world operation holds it, the pass logs `World operation in progress - skipping` and exits successfully. The next timer pass retries, so ordinary contention does not produce a systemd failure alert.
- `data/scripts/internal/listOutdatedMods.sh` — names the mods whose Steam copy is newer than the local one. The console command `checkModsNeedUpdate` only answers with a global status and **never names the mod**, so this compares `timeupdated` in `steamapps/workshop/appworkshop_108600.acf` (section `WorkshopItemsInstalled` only — `WorkshopItemDetails` repeats the same IDs) against `time_updated` from Steam's `ISteamRemoteStorage/GetPublishedFileDetails` (no API key needed), which also returns the human-readable title. Empty output = unknown → the caller falls back to the generic reason rather than announcing a wrong list.
- `pz-maintenance.timer` — daily 04:30; `performFullMaintenance.sh` stops the server, runs `apt upgrade`, `steamcmd +app_update … validate`, **re-applies JVM tuning**, syncs, **`git fetch -p` + `git pull --ff-only` of pzmanager itself** (only on `main`, non-blocking — a diverged or locally modified checkout is logged, never merged), and optionally reboots (`REBOOT_ON_MAINTENANCE`). It no longer triggers the inactive-access purge — that moved to `zomboid.service`'s `ExecStartPre` (see gotchas).
- `pz-creation-date-init.timer` — midnight; feeds the **account-age ledger** used by the inactivity purge. `creationDateInit.sh` appends one line per newly-seen account to `WHITELIST_LEDGER` (`data/whitelistLedger.csv`, `username;steamid;created_at`, chmod 600, gitignored). It lives **outside the world DB on purpose**: the DB is recreated by every wipe, and the `created_at` column this script used to fill **never existed** (no `ALTER TABLE` anywhere) — so from install until 2026-08-19 the timer was a guaranteed no-op and the purge fell back to a branch that treated *any* never-connected account as inactive regardless of age. Rules: `created_at` is written **only on first sighting** and never modified; no line is ever deleted (a returning player keeps his real age); a never-connected account **absent from the ledger is never purged** (unknown age -> abstain); on first population `created_at` = `lastConnection` when set, else now (both under-estimate age, so they delay a purge — the safe direction). `lastConnection` is deliberately **not** duplicated: `resetServer.sh` re-injects it into the new DB at wipe time (verified — oldest date in DB 2026-06-19 predates the 2026-08-05 world recreation). The script is **read-only on the DB**, so it runs fine with the server up; `purgeInactivePlayers.sh` calls it before deciding, so an account restored by a wipe is registered before being judged. The ledger sits in `data/` (untouched by `pzm admin reset`) and is in `fullBackup.sh`'s `DIRS_TO_SYNC` — the incremental snapshots only cover `Zomboid/`.
- `pz-heapcheck.timer` — **adaptive** memory-driven restart (replaced the old fixed 11/17/23h `pz-restart.timer`). Fires ~every 30 s (`OnUnitInactiveSec=30s`, `OnActiveSec=30s`, `AccuracySec=1s`, so it never overlaps its own run) → `pz-heapcheck.service` (oneshot, `TimeoutStartSec=1500`) → `data/scripts/internal/checkHeapAndRestart.sh`: reads the **post-major-GC heap %** from `logs/zomboid/gc.log` (the `Major Collection … ->NNNNM(PP%)` line = live set after a full GC) and when it reaches `HEAP_RESTART_PERCENT` (`.env`, default **95**) triggers `pzm server restart HEAP_RESTART_DELAY` (default `5m`, `--automatic`). A `heapcheck.trigger` cooldown marker (1800 s, répertoire privé `${XDG_RUNTIME_DIR}/pzmanager/`, repli `/tmp/pzmanager-<user>/` 0700) prevents re-triggering during the warning. **Mitigates the recurring Java-heap OOM** (see gotchas) by restarting *when the heap is actually near full* instead of on a blind schedule — restarts only when needed (quiet server = no needless restart) and requests a preventive restart; a rapid increase can still reach the hard cap first. Independently, it sums process RSS in the service cgroup and descendants and triggers the same restart at **18 GiB** (`PZ_RAM_RESTART_GB`, excluding reclaimable file and kernel caches), even without `gc.log`. `zomboid.service` enforces **`MemoryMax=20G`**, heap ceiling 16 GiB (4 GiB for all other charges), `OOMPolicy=kill` and no swap as a last resort: a rapid increase can kill the service during the warning or save. Discord shows accounted cgroup memory versus its actual cap separately from RSS and used heap. Only reclaimable caches can be freed; resident ZGC shmem remains charged. A blocking startup preflight validates the launched JSON and effective cgroup limit. Failed restart requests clear the cooldown marker so the next tick can retry. The **04:30 maintenance restart is the daily backstop** if the monitor ever fails to fire. gc.log stays fresh enough to read: ZGC `ZCollectionInterval=60` forces a **major** collection every 60 s, so the ~30-second monitor always finds a recent `Major Collection` line (the heap takes ~15 h to fill — one major/min is ample). Tuning trade-off: at post-GC 95% the heap can't free below 95%, so a long warning risks OOM mid-countdown — lower `HEAP_RESTART_PERCENT` to 90 or shorten `HEAP_RESTART_DELAY` if a crash ever happens during the warning.
