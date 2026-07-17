# Mod Updates

Adding or removing Workshop mods is the riskiest routine operation on a Build 42
server: a single bad entry in `servertest.ini` puts the server in a boot
crash-loop and takes every player offline. This document is the procedure that
makes it safe and repeatable.

## Running this with an agentic AI

This procedure is written to be **executed by an agentic AI** such as
[Claude Code](https://claude.com/claude-code), not only read by a human. The
operator pastes the Workshop URLs; the agent reads the pages, resolves Mod IDs
and dependencies, orders the list, pre-downloads, edits the config, drives the
restart, and records the change.

Point the agent at this file and give it the URLs:

> Read `docs/MOD_UPDATES.md` and follow it to add these mods:
> https://steamcommunity.com/sharedfiles/filedetails/?id=…

Two rules make the difference between an agent that helps and one that takes the
server down:

- **Follow every step, every time, in order.** Steps 3 and 5 (pre-download and
  in-game check) are the ones that get skipped and the ones that cost an outage.
- **Never conclude from a failed page fetch.** See [Pitfalls](#pitfalls) — the
  common failure mode is an agent confidently reporting a mod as deleted when it
  is fine. When a fetch is unclear, stop and ask the operator to paste the page.

## The version ledger

Every mod-list change is one numbered version. The current list plus the history
lives outside git (it is server-specific data, not shipped code) in
`temp/versionning/`:

| File | Content |
|------|---------|
| `V[N].txt` | One file per version: the exact `Mods=` / `WorkshopItems=` / `Map=` lines, a table of what changed, and a full numbered table of every mod in the version |
| `Mods bugués à intégrer plus tard.csv` | Mods parked after failing the in-game check, with the observed symptom |

`V[N].txt` is what makes a rollback a copy-paste instead of an investigation, so
it is written **before** the deploy, not after. Keep the format identical across
versions — including the closing full mod table, which is easy to drop and
painful to reconstruct.

## Procedure

### 1. Read the current version

Read the highest-numbered `V[N].txt`. It is the baseline for the diff and the
rollback target.

### 2. Resolve each mod

For every Workshop URL:

- **Workshop ID** — the `id=` number in the URL.
- **Mod ID** — on the Steam page, the `Mod ID: xxx` line. This is what goes in
  `Mods=`; it is *not* the Workshop ID and *not* the mod's display name.
- **Dependencies** — resolve them the same way, recursively. A missing
  dependency is the most common `required mod X not found` at boot.
- **Compatibility** — check `versionMin` / `versionMax` in the mod's `mod.info`
  against the running build.

Judge scope from the **mod's code**, not its description: descriptions routinely
overclaim. If a mod ships sandbox options, decide explicitly which ones you want
and write the rest to `servertest_SandboxVars.lua` rather than inheriting the
mod's defaults.

Write `V[N+1].txt` with the new entries, ordered per [Load order](#load-order).

### 3. Pre-download every new item

**Do not edit `servertest.ini` until each new Workshop ID is on disk.** A mod
never downloaded before is the one that crash-loops the server:

```bash
ls data/pzserver/steamapps/workshop/content/108600/<WorkshopID>
```

If it is absent, download it with SteamCMD and confirm the payload size matches
the size announced on the Workshop page. Only once every new item is cached does
the config edit become safe — a cached item cannot fail with `result=3` at boot.

### 4. Deploy

```bash
# Stop — always with --reason: the text is shown to players in the in-game
# warning and on Discord.
pzm server stop 2m --reason "Mods V[N+1]"

# Record the last backup at the top of V[N+1].txt — this is the restore point.
pzm backup list | head -3

# Copy Mods= and WorkshopItems= from V[N+1].txt
nano Zomboid/Server/servertest.ini

pzm server start now --reason "Mods V[N+1]"
```

Then, ~2 min after start:

```bash
grep -iE "not found|error|missing" "$(ls -t scripts/logs/zomboid/*.log | head -1)"
```

`required mod X not found` means a missing dependency or a wrong load order.

### 5. Verify in game

Log in as admin — the log being clean is not enough:

- **Esc → Mods**: no mod flagged `[ERRORS]`. If one is, remove it, and record it
  in the parked-mods CSV with the symptom.
- **Esc → Admin → Item List**: the menu must open without crashing. A crash with
  `attempted index: toString of non-table: null` in `ISItemsListTable.lua` is a
  broken mod; bisect the new entries to find it.

### 6. Record

Mark `V[N+1].txt` as deployed, and mirror the version into whatever tracker the
site uses (this server syncs a spreadsheet from `temp/`). A `V[N].txt` without
its tracker entry means the procedure was not finished.

Announce to players what landed:

> Beta V[N+1] is live, with these mods:
> - [Mod]: [what it does]

## Load order

`Mods=` is load order, and dependencies must come before their dependents:

1. Tech / libraries (ModOptions, tsarslib, frameworks)
2. Fixes (CommonSense, Torch_Fix)
3. Gameplay (QoL, mechanics)
4. Crafting (TheWorkshop first)
5. Animations
6. Content (weapons, clothing, patches)
7. Items (Torch after Torch_Fix)
8. Vehicles
9. UI
10. **Maps — always last**

## Pitfalls

### "Removed from the community" is a lie

A fetched Workshop page reporting *removed from the community* / *violates Steam
Community & Content Guidelines* / *incompatible with Project Zomboid* is the
standard banner Steam shows to an **anonymous, logged-out visitor**. Small models
reliably mistake it for a real takedown.

**Never conclude a mod is deleted or incompatible from a page fetch.** If the
fetch shows that banner, or fails to give you the Mod ID or the dependencies,
**stop and ask the operator to paste the page contents.**

### `No Connection` / `result=3` on a new mod

Anonymous Workshop downloads for Project Zomboid (app 108600) have been
restricted at times, and the failure is deceptive:

- Mods **already cached** on disk load fine — so an existing server keeps
  running, and probing SteamCMD with an already-present mod succeeds. That is a
  **false positive**: it proves nothing about a new item.
- A **new** mod fails both via `steamcmd +login anonymous +workshop_download_item`
  **and inside the dedicated server itself** at boot:
  `GetItemState()=NeedsUpdate → DownloadPending → download 0/0 →
  onItemNotDownloaded result=3 → item state -> Fail`, then a
  `NullPointerException` in `GameServerWorkshopItems.Install` → **crash-loop,
  players offline**.

This is why step 3 is not optional. The fix when anonymous download is broken is
to authenticate SteamCMD with a **dedicated Steam account that owns PZ** (never a
personal account — the login token persists on disk) and pre-download with it.

Distinguish from `failed (No match)`, which means the ID genuinely does not exist
on app 108600.

## Rollback

If a deploy crash-loops the server, roll back immediately rather than debugging
live:

```bash
# Restore Mods= / WorkshopItems= from V[N] (the previous version)
nano Zomboid/Server/servertest.ini

systemctl --user kill zomboid.service
systemctl --user stop zomboid.service zomboid.socket
systemctl --user reset-failed zomboid.service zomboid.socket

pzm server start now --reason "Rollback V[N+1] → V[N]"
```

## See also

- [SERVER_CONFIG.md](SERVER_CONFIG.md) — `servertest.ini` settings in general
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — boot failures, mod download issues
- [PZ Wiki — Modding](https://pzwiki.net/wiki/Modding)
