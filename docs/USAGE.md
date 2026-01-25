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
pzm whitelist remove "76561198012345678"        # Remove
```

**Steam ID 64**: 17 digits starting with `7656119...`
Find via [steamid.xyz](https://steamid.xyz/)

## Administration

```bash
pzm admin reset                    # Full reset (new world)
pzm admin reset --keep-whitelist   # Reset, keep whitelist + config
pzm admin maintenance [delay]      # Manual maintenance (default: 30m)
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
pzm rcon "save"                        # Force save
pzm rcon "servermsg 'Message'"         # Broadcast
pzm rcon "players"                     # List players
pzm rcon "checkModsNeedUpdate"         # Check mod updates
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
| pz-modcheck | Every 5 min | Check mod updates |
| pz-maintenance | Daily 4:30 | Full maintenance + reboot |

## Quick Reference

| Task | Command |
|------|---------|
| Start server | `pzm server start` |
| Stop in 5 min | `pzm server stop 5m` |
| Check status | `pzm server status` |
| Add player | `pzm whitelist add "Name" "SteamID64"` |
| Manual backup | `pzm backup create` |
| Send message | `pzm rcon "servermsg 'Text'"` |
| Increase RAM | `pzm config ram 16g` |

## Help

```bash
pzm --help
```

## Documentation

- [QUICKSTART.md](QUICKSTART.md) - Installation
- [SERVER_CONFIG.md](SERVER_CONFIG.md) - Game configuration
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Problem solving
