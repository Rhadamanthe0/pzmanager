# Advanced Configuration

Optimizations, RCON, and expert settings for pzmanager.

## Table of Contents

- [Performance Optimization](#performance-optimization)
- [RCON Commands](#rcon-commands)
- [Script Customization](#script-customization)
- [Multi-Server Configuration](#multi-server-configuration)
- [Remote Maintenance](#remote-maintenance)

## Performance Optimization

Official documentation: [PZ Wiki - Performance](https://pzwiki.net/wiki/Dedicated_Server#Performance)

### RAM Configuration

✅ **Automatically applied at installation**:
- **ZGC** (`-XX:+UseZGC`): Optimized garbage collector
- **RAM**: 8GB by default (`-Xmx8g`)

**Modify RAM allocation**:
```bash
pzm config ram 4g    # 4GB
pzm config ram 8g    # 8GB
pzm config ram 16g   # 16GB
pzm config ram 32g   # 32GB
```

**Recommendations**:
- 4GB: <10 simultaneous players
- 8GB: <25 players (default)
- 16GB: <60 players

**Apply**: Restart server after modification

## RCON Commands

### Usage via pzmanager

```bash
pzm rcon "COMMAND"
```

### Useful Commands

```bash
# Save
pzm rcon "save"

# Broadcast message
pzm rcon "servermsg 'Message to players'"

# Stop server
pzm rcon "quit"

# List players
pzm rcon "players"

# Help
pzm rcon "help"
```

Complete documentation: [PZ Wiki - Admin Commands](https://pzwiki.net/wiki/Server_commands)

## Whitelist Management

Advanced whitelist via SQLite: [SERVER_CONFIG.md - Whitelist](SERVER_CONFIG.md#gestion-whitelist)

Database: `/home/pzuser/pzmanager/Zomboid/db/servertest.db`

## Complete Server Reset

### resetServer.sh Script

**Script**: `resetServer.sh`

Complete server reset with new world. Useful for starting from scratch.

**Complete reset (clean server)**:
```bash
./scripts/admin/resetServer.sh
```

**Reset with whitelist and config preservation**:
```bash
./scripts/admin/resetServer.sh --keep-whitelist
```

### Process

**Step 1 - Confirmation**:
- Request confirmation (type `RESET` in uppercase)

**Step 2 - Stop and backup**:
- Server shutdown
- Complete backup in `/home/pzuser/OLD/Zomboid_OLD_TIMESTAMP/`

**Step 3 - Initial configuration**:
- Start interactive initial setup
- Enter admin password (twice)
- When message "If the server hangs here, set UPnP=false": **Ctrl+C**

**Step 4 - Restoration (if --keep-whitelist)**:
- Restore whitelist from old server (except admin)
- Copy `servertest.ini` and `servertest_SandboxVars.lua`

**Step 5 - Startup**:
- Start new server

### Use Cases

**New world**: Corrupted server, complete rules change, fresh start.

**With whitelist**: Keep authorized players and server parameters.

**⚠️ Warning**: Complete data deletion! Backup created automatically.

## Script Customization

### Custom Warning Messages

Edit `scripts/core/pz.sh` line 76 to modify messages sent to players.

### Maintenance Scheduling

Modify crontab:
```bash
crontab -e

# Daily maintenance (default: 4:30 AM)
30 4 * * *  /bin/bash  /home/pzuser/pzmanager/scripts/admin/performFullMaintenance.sh

# Hourly backups (default: :14)
14 * * * *  /bin/bash  /home/pzuser/pzmanager/scripts/backup/dataBackup.sh >> /home/pzuser/pzmanager/scripts/logs/data_backup.log 2>&1
```

## Multi-Server Configuration

To run multiple servers on the same machine:

1. Clone pzmanager to another directory
2. Modify ports in servertest.ini (16261 → 16271, etc.)
3. Create a new user or modify PZ_USER in .env
4. Adjust crontab schedules to avoid conflicts

## Remote Maintenance

### Forced SSH Configuration

A special SSH key allows remote maintenance triggering.

**File**: `~/.ssh/authorized_keys`

```
command="/home/pzuser/pzmanager/scripts/admin/performFullMaintenance.sh $SSH_ORIGINAL_COMMAND",no-port-forwarding,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAA...
```

**Key generation** (on local machine):
```bash
ssh-keygen -t ed25519 -f ~/.ssh/pz_maintenance
```

**Usage**:
```bash
# From local machine
ssh -i ~/.ssh/pz_maintenance pzuser@SERVER_IP 30m
ssh -i ~/.ssh/pz_maintenance pzuser@SERVER_IP 5m
ssh -i ~/.ssh/pz_maintenance pzuser@SERVER_IP 2m
```

**Security restrictions**:
- Forced command (only performFullMaintenance.sh)
- No port forwarding
- No X11 forwarding
- No agent forwarding

## Advanced Monitoring

### Detailed Status

```bash
pzm server status
```

Displays:
- Service status (running/stopped)
- Uptime
- Control pipe availability
- Last save
- Last 30 log lines

### Real-time Logs

```bash
# Server logs
sudo journalctl -u zomboid.service -f

# Maintenance logs
tail -f scripts/logs/maintenance/maintenance_*.log

# Backup logs
tail -f scripts/logs/data_backup.log
```

## Resources

- [CONFIGURATION.md](CONFIGURATION.md) - .env variables, backups
- [SERVER_CONFIG.md](SERVER_CONFIG.md) - Game server configuration
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Troubleshooting
- [PZ Wiki - Server](https://pzwiki.net/wiki/Dedicated_Server)
