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

Three rules make the difference between an agent that helps and one that takes the
server down:

- **Follow every step, every time, in order.** Steps 3 and 5 (pre-download and
  in-game check) are the ones that get skipped and the ones that cost an outage.
- **Never conclude from a failed page fetch.** See [Pitfalls](#pitfalls) — the
  common failure mode is an agent confidently reporting a mod as deleted when it
  is fine. When a fetch is unclear, stop and ask the operator to paste the page.
- **Deploy in batches of five mods maximum, dependencies included.** A long list
  of URLs is not one version: split it into successive versions of at most five
  `Mods=` entries each — a required library counts against the five. One batch =
  one `V[N].txt` = one restart = one boot you can read. When a batch breaks, the
  five candidates are the whole search space; a twenty-mod deploy that
  crash-loops is a bisection on a live server. Group each batch by family so a
  mod ships with its dependencies and the load order stays reviewable.

## The version ledger

Every mod-list change is one numbered version. The tooling lives in `versionning/`;
the ledger files themselves stay outside git (server-specific data, not shipped
code) via `.gitignore`:

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
grep -iE "not found|error|missing" "$(ls -t logs/zomboid/*.log | head -1)"
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
site uses (this server syncs a spreadsheet via `versionning/sheetVersionning.sh`).
A `V[N].txt` without
its tracker entry means the procedure was not finished.

Announce to players what landed, on every add **and** every removal, one bullet
per mod — the mod's name in bold, then what it changes *for the player*, in
plain language. No Mod IDs, no Workshop IDs, no version numbers: a bullet is
useful when someone who has never opened the Workshop knows what to do with it.
Group the bullets under their version heading when several versions ship at
once, fold the libraries into a single bullet that says they add nothing on
their own, and put any catch (a vehicle that barely spawns, an option left off,
a window that replaces a vanilla one) at the end of that mod's own bullet:

> **V66**
> - **that DAMN Library + Military Tool Kit** — bibliothèques techniques, aucun
>   contenu en jeu, requises par les deux véhicules ci-dessous.
> - **U.S. M998 Humvee** — Humvee à portes animées avec tourelle .50
>   fonctionnelle (place de tireur + boîte de munitions 12.7x99mm à charger).
> - **'97 ADI Bushmaster** — blindé australien, 2 châssis (utilitaire 10 places /
>   ambulance). ATTENTION : il ne spawne PAS dans les zones normales, uniquement
>   et rarement sur certaines barricades du comté et quelques emplacements
>   secrets.

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

### `Map=` precedence is FIRST-wins

`Map=` is a separate, independently ordered list, and its rule is the **opposite**
of what most people assume: for a cell claimed by two maps, the one listed
**earlier** wins. Vanilla **`Muldraugh, KY` must therefore come LAST**, after every
custom map.

This cost a full diagnosis cycle: the config had Muldraugh 2nd with the custom
maps *after* it, so **none of them rendered** — Muldraugh (and WPExpansion) won
every shared cell and left vanilla forest. Only `ChateauEkron` showed up, purely
because it happened to sit before Muldraugh. The maps work fine in the creator's
single-player because nothing precedes them there.

The fix (V35) was to reorder all customs first, then WPExpansion, then vanilla:

```ini
Map=ChateauEkron;fort régulateur;Fort Sokolov;Ekron castle;West Point Expansion_B42;Muldraugh, KY
```

Reordering alone is not enough — **re-wipe the affected cells** afterwards
(see [Map mods](#map-mods)) so they regenerate from the mod instead of serving
the cached vanilla terrain.

## Map mods

Adding *or updating* a map mod requires regenerating its cells, otherwise PZ keeps
serving the cached chunks and you see the old (or vanilla) version. The mechanics
of the wipe — the Build 42 8/256 grid, the safety snapshot, what gets deleted —
are in [ADVANCED.md § Regenerating a Map Area](ADVANCED.md#regenerating-a-map-area).
What follows is what bites you *around* the wipe.

### Find the real location: compiled `.lotheader` cells, not the Steam page

**A map mod's real location is its compiled `.lotheader` cell numbers, not the
"tile" announced on its Steam page.** Read them from:

```
data/pzserver/steamapps/workshop/content/108600/<id>/mods/<folder>/**/media/maps/<folder>/*.lotheader
```

and multiply by **256** to get the tile range to wipe. The `worldOrigin` in the
`.pzw` is only an editor setting — ignore it.

Gojira.exe's community maps **systematically mislabel the announced tile**:

| Map | Steam says | Really compiles to | Tiles to wipe |
|---|---|---|---|
| Fort Régulateur (#3767253287) | tile 43,22 | cells 50-51 × 25-26 | 12800-13311 × 6400-6911 |
| Fort Sokolov (#3769251473) | tile 24,26 | cells 28-29 × 30-31 | — |
| Ekron castle (#3769266734) | tile 01,30 | cells 1-2 × 35-36 | — |
| ChateauEkron (#3757414909) | — | cells 1-2 × 41-42 | — |

Wiping the announced tile does nothing at all.

### Mod IDs and map folders get renamed between uploads

Gojira renames them inconsistently, so **always read the real names from
`mod.info` and from the physical directories on disk — never from the Steam page
or description, which lag**:

- Fort Régulateur's `id` became `fortrégulateur` (no space) while its physical map
  folder stayed `fort régulateur` (with a space).
- Ekron castle ships `id=EkronCastle` (camelCase) with the folder `Ekroncastle`.
- Fort Sokolov's `id` became `FortSokolov` while the folder stayed `Fort Sokolov`.

`Mods=` takes the **`id`**. `Map=` takes the **physical folder that actually holds
the `.lotpack`** — and the `mapFolder=` field inside `mod.info` can itself be wrong
(Fort Régulateur's says `fortrégulateur`; the real folder has a space). A rename
therefore means editing **both** lines, and a mismatch throws
`required mod "X" not found` at boot, with the mod silently not loaded.

When an update ships **two** map folders (the Ekron castle update shipped
`Ekron castle` *and* a stale `Ekroncastle`), point `Map=` at the one that actually
contains the biomemap, verified on disk.

### Verifying the render: three false negatives

1. **Check at the map's real build tile, not the cell centre or announced tile.**
   A map covers a 2×2-cell (512×512-tile) footprint, but the *built* village is a
   small patch inside it. Teleporting even ~120 tiles off lands you in the mod's
   own forest fringe, and a working map looks broken. The exact build tile is the
   `SpawnPoint x=… y=…` in the map folder's **`objects.lua`** (absolute tile) — for
   Fort Sokolov, `x=7346 y=8000`. Teleporting to 7400,7900 is what made Sokolov
   look dead; 7346,8000 shows the village.
2. **A black/void screenshot is almost always mid-load.** The in-game "please wait
   two seconds to show the map" means the first capture is partial. Ekron castle
   looked like pure void at 500,9200 and rendered the full castle a moment later.
3. **`ERROR … invalid building metaID #… in cell X,Y while reading map_meta.bin`
   at boot is NOISE, not the render blocker.** These accumulate in the world's
   single global `map_meta.bin` on every map add or change (227 of them across
   cells 1-56 on 2026-07-24) **while every map rendered fine**. Do **not**
   regenerate or delete `map_meta.bin` on that evidence alone: it is a disruptive
   global-metagrid rebuild on a live world, for a cosmetic log error.
   `wipeMapTile.sh` deliberately leaves it untouched.

A biomemap sitting in a nested `.../media/maps/<folder>/maps/biomemap_*.png`
subfolder is **normal** — the working ChateauEkron has it too. Don't misdiagnose it.

## Pitfalls

### Some mods break only on a Linux dedicated server

A mod can load cleanly server-side and still be broken. **Before adding a weapon
or framework mod, check its Steam Discussions for a "Linux dedicated server"
thread.**

Example (removed 2026-07-23, V35): **Gunworks Framework** (`SWMG`, #3722064198)
and its dependent **Black Powder Gunsmithing** (`BlackPowderGunsmithing`,
#3766140920). Both *loaded* at boot — no crash, no `required-mod-not-found` — but
the framework showed **`[ERRORS]` in the in-game Mods menu**, matching its known
"unable to load on Linux dedicated Server" discussion.

**A clean server-side boot log is not proof a mod works.** The in-game
`Esc → Mods` check for `[ERRORS]` (step 5 of the procedure above) is the real gate.

### "Removed from the community" is a lie

A fetched Workshop page reporting *removed from the community* / *violates Steam
Community & Content Guidelines* / *incompatible with Project Zomboid* is the
standard banner Steam shows to an **anonymous, logged-out visitor**. Small models
reliably mistake it for a real takedown.

**Never conclude a mod is deleted or incompatible from a page fetch.** If the
fetch shows that banner, or fails to give you the Mod ID or the dependencies,
**stop and ask the operator to paste the page contents.**

### "This mod does not exist" is a rate limit

Fetching several Workshop pages in a row gets the fetcher rate-limited, and Steam
answers *"You've made too many requests recently"* — which a summarising model
relays as **the mod not existing**. Never delete an ID from the list on that
evidence.

The way through is not to wait: the public **`ISteamRemoteStorage/GetPublishedFileDetails`**
endpoint needs no API key, takes N ids in a single POST, and returns the title,
the full description (so the `Mod ID:` / `Workshop ID:` lines authors put at the
bottom), the file size and `time_updated`:

```bash
curl -s -X POST "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/" \
  -d "itemcount=2" -d "publishedfileids[0]=<id1>" -d "publishedfileids[1]=<id2>"
```

`result=1` means the item exists (`result=9` = genuinely unknown). The returned
`file_size` doubles as the check for step 3 — compare it against SteamCMD's
`Success. Downloaded ... (N bytes)`.

This gives you the author's *prose*. The authority on `id=`, `require=` and
`versionMin` remains the `mod.info` on disk once the item is downloaded — pages
routinely announce a Mod ID the versioned subfolder contradicts.

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
