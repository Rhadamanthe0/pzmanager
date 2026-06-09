# Advanced Configuration

Performance tuning and server reset procedures.

## RAM Configuration

RAM is configured **once at install time** and is intentionally not tunable
afterwards (no `pzm config ram` command). The installer sets, in
`ProjectZomboid64.json`:

- `-Xms2g` — fixed heap floor (ZGC gives unused heap above this back to the OS).
- `-Xmx<half of physical RAM>` — heap ceiling, e.g. 7g on a 14 GiB machine.
  This is a real, survivable guardrail: it triggers a clean Java
  `OutOfMemoryError` before the heap can crowd out PZ's native memory + the OS.
- `-XX:+UseZGC -XX:+AlwaysPreTouch -XX:ZCollectionInterval=5` — GC tuning.

**No cgroup memory cap.** `MemoryMax`/`MemoryHigh` are deliberately *not* set:
on a modest machine they sit at the level of physical RAM, and the kernel
throttles/OOM-kills PZ the instant it touches the cap (this caused server
crashes). The only cgroup limit is `MemorySwapMax=1G` in
`data/setupTemplates/zomboid.service`, a small overflow buffer.

To change `Xmx`, edit `ProjectZomboid64.json` directly (or re-run the
installer's JVM step) and restart: `pzm server restart 5m`.

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

Process:
1. Type `RESET` to confirm
2. Backup created in `~/OLD/Zomboid_OLD_TIMESTAMP/`
3. World generation (automatic, ~2 min)
4. Admin password displayed (note it!)
5. Server started

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
