# Usage Guide

All `pzm` commands. Run as `pzuser`.

```bash
su - pzuser
```

## Server

```bash
pzm server start              # Start
pzm server stop [delay]       # Stop (default: 2m)
pzm server restart [delay]    # Restart (default: 2m)
pzm server status             # Status + logs
```

**Delays**: `30m`, `15m`, `5m`, `2m`, `30s`, `now`

**Send a message to connected players**:
```bash
pzm rcon servermsg "Message to players"
```

## Backups

```bash
pzm backup create             # Incremental backup
pzm backup full               # Complete backup
pzm backup list               # List backups
pzm backup restore <path>     # Restore ALL data from a backup
pzm backup restore-character <name> <backup>   # Restore ONE player's character (overwrites existing)
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

## Whitelist

Build 42 (≥ 42.13.2) gates access by **SteamID** (`Open=false`): only SteamIDs in
the allow-list can connect, and players pick their own password on first login.
`add`/`remove` drive the server console, so **the server must be running**.

```bash
pzm whitelist list                                  # Allowed SteamIDs + accounts + bans
pzm whitelist add "76561198012345678" "Name"        # Authorize a SteamID (name optional)
pzm whitelist remove "Name"                         # Remove access (by name or SteamID)
pzm whitelist remove "76561198012345678" --ban      # Remove + permanent ban
pzm whitelist resetpassword "Name"                  # Reset a player's password
pzm whitelist purge                                 # List inactive (default: WHITELIST_PURGE_DAYS)
pzm whitelist purge 3m                              # List inactive 3+ months
pzm whitelist purge 3m --delete                     # Delete inactive after confirmation
```

**Player onboarding**: see [PROCEDURE_JOUEURS](PROCEDURE_JOUEURS.md) (French) — the
player sends their SteamID64, you authorize it, they connect and set their own password.

**Notes**:
- Steam ID 64: 17 digits starting with `7656119...` ([steamid.xyz](https://steamid.xyz/))
- `--ban` adds a permanent `banid` — the player can't return even renamed.
- Access of accounts inactive ≥ `WHITELIST_PURGE_DAYS` (default 90) is **auto-removed**
  nightly during maintenance (whitelist + SteamID); the **character is kept**, and the
  built-in `admin` account is always spared.
- `purge` here is the manual, interactive variant (lists/deletes `whitelist` rows only).
- Purge: Xm (months) or Xd (days), default in .env

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

*Manual maintenance* (`pzm admin maintenance 2m --reason "RAM upgrade"`):
```
@here ATTENTION : MAINTENANCE DANS 2 MINUTES ! (Lancé manuellement - RAM upgrade)
ATTENTION : MAINTENANCE DANS 30 SECONDES !
MAINTENANCE TERMINÉE
REDÉMARRAGE SERVEUR
```

*Automatic maintenance - mods detected*:
```
@here ATTENTION : MAINTENANCE DANS 5 MINUTES ! (Lancé automatiquement - Mods mis à jour)
ATTENTION : MAINTENANCE DANS 30 SECONDES !
MAINTENANCE TERMINÉE
REDÉMARRAGE SERVEUR
```

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

RAM is set automatically (`-Xms2g` / `-Xmx` = half of physical RAM) at install
time and re-applied after every server update; it is not tunable via a command.
See [ADVANCED.md](ADVANCED.md#ram-configuration).

## RCON

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
pzm discord "message"         # Send Discord notification
```

Requires `DISCORD_WEBHOOK` in `scripts/.env`

## Automations

View scheduled tasks:
```bash
systemctl --user list-timers
```

| Timer | Schedule | Function |
|-------|----------|----------|
| pz-backup | Hourly :14 | Incremental backup |
| pz-modcheck | Every 5 min | Check mod & server updates |
| pz-maintenance | Daily 4:30 | Full maintenance (reboot or restart selon .env) |
| pz-creation-date-init | Daily 00:00 | Init whitelist creation dates |

## Quick Reference

| Task | Command |
|------|---------|
| Start server | `pzm server start` |
| Stop in 5 min | `pzm server stop 5m` |
| Check status | `pzm server status` |
| Add player | `pzm whitelist add "Name" "SteamID64"` |
| Manual backup | `pzm backup create` |
| Send message | `pzm rcon servermsg "Text"` |

## Help

```bash
pzm --help
```

## Documentation

- [QUICKSTART.md](QUICKSTART.md) - Installation
- [SERVER_CONFIG.md](SERVER_CONFIG.md) - Game configuration
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Problem solving
