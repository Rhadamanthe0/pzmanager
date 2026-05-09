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
pzm backup restore <path>     # Restore from backup
```

Example:
```bash
pzm backup restore data/dataBackups/backup_2026-01-12_14h14m00s
```

## Whitelist

```bash
pzm whitelist list                              # List users
pzm whitelist add "Name" "76561198012345678"    # Add (Steam ID 64)
pzm whitelist remove "Name"                     # Remove by username
pzm whitelist purge                             # List inactive (default: WHITELIST_PURGE_DAYS)
pzm whitelist purge 3m                          # List inactive 3+ months
pzm whitelist purge 3m --delete                 # Delete inactive after confirmation
```

**Notes**:
- Steam ID 64: 17 digits starting with `7656119...` ([steamid.xyz](https://steamid.xyz/))
- Each username must be unique
- Max 2 accounts per Steam ID
- Purge: Xm (months) or Xd (days), default in .env
- Purge exclut toujours l'utilisateur `admin`

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

```bash
pzm config ram <value>        # Set RAM: 4g, 8g, 16g, 32g
```

Apply: `pzm server restart 5m`

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
| Increase RAM | `pzm config ram 16g` |

## Help

```bash
pzm --help
```

## Documentation

- [QUICKSTART.md](QUICKSTART.md) - Installation
- [SERVER_CONFIG.md](SERVER_CONFIG.md) - Game configuration
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Problem solving
