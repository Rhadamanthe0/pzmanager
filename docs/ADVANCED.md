# Advanced Configuration

Performance tuning and server reset procedures.

## RAM Configuration

**Default**: 8GB with ZGC garbage collector (automatically configured)

```bash
pzm config ram 4g    # 4GB  - <10 players
pzm config ram 8g    # 8GB  - <25 players (default)
pzm config ram 16g   # 16GB - <60 players
pzm config ram 32g   # 32GB - 60+ players
```

Apply: `pzm server restart 5m`

## RCON Commands

```bash
pzm rcon "save"                          # Force save
pzm rcon "servermsg 'Message'"           # Broadcast
pzm rcon "players"                       # List players
pzm rcon "quit"                          # Stop server
pzm rcon "help"                          # All commands
```

Full list: [PZ Wiki - Server Commands](https://pzwiki.net/wiki/Server_commands)

## Complete Server Reset

Use when: corrupted world, major config change, fresh start.

**New world (clean slate)**:
```bash
pzm admin reset
```

**New world but keep whitelist and config**:
```bash
pzm admin reset --keep-whitelist
```

Process:
1. Type `RESET` to confirm
2. Backup created in `~/OLD/`
3. Enter admin password (twice)
4. When "UPnP" message appears → **Ctrl+C**
5. Server ready

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
